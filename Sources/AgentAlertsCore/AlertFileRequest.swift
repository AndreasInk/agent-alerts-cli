import Darwin
import CoreFoundation
import Foundation

public enum AlertSurface: String, CaseIterable, Sendable {
    case liveActivity = "live_activity"
    case inApp = "in_app"
    case notification
}

/// A JSON content file with optional report layouts and CLI-owned delivery routing.
public struct AlertFileRequest: Sendable {
    let body: Data
    let idempotencyKey: String

    public init(
        contentsOf url: URL,
        activityID: String,
        event: AlertEvent = .update,
        surfaces: [AlertSurface] = []
    ) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw AppError("Cannot read the JSON file.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AppError("--file requires a regular JSON file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65_537) ?? Data()
        try self.init(data: data, activityID: activityID, event: event, surfaces: surfaces)
    }

    init(
        data: Data,
        activityID: String,
        event: AlertEvent = .update,
        surfaces: [AlertSurface] = [],
        now: Date = Date()
    ) throws {
        guard data.count <= 65_536 else { throw AppError("The JSON file must be at most 64 KiB.") }
        guard let content = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppError("The JSON file must contain an alert content object.")
        }
        // Content only: routing, credentials, timestamps, and interactions remain CLI-managed.
        let fields: Set<String> = [
            "title", "summary", "status", "sourceName", "sourceIcon", "template", "builderSpec", "data", "jsonRender",
            "action", "deepLink", "inlineLabel", "primaryLabel", "primaryValue", "primaryDelta",
            "secondaryLabel", "secondaryValue", "footer", "chartValues", "chartTitle", "chartStyle",
            "progressPercent", "completedSteps", "totalSteps", "progressStyle", "visualStyle", "accentHex", "glassOpacity",
        ]
        guard Set(content.keys).isSubset(of: fields) else {
            throw AppError("Use content fields in the JSON file, without a payload wrapper, routing, credentials, or timestamps. See docs/usage.md.")
        }
        guard let title = content["title"] as? String,
              content["summary"] == nil || content["summary"] is String,
              content["sourceName"] == nil || content["sourceName"] is String else {
            throw AppError("The JSON file requires a title string; summary and sourceName must be strings when supplied.")
        }
        let status: AlertStatus
        if let value = content["status"] {
            guard let raw = value as? String, let parsed = AlertStatus(rawValue: raw) else {
                throw AppError("JSON status must be good, warning, or critical.")
            }
            status = parsed
        } else {
            status = .good
        }
        if let template = content["template"] {
            guard let value = template as? String, ["ops", "growth", "agent", "builder"].contains(value) else {
                throw AppError("JSON template must be ops, growth, agent, or builder.")
            }
        }
        if content["builderSpec"] != nil || content["template"] as? String == "builder" {
            guard content["template"] as? String == "builder",
                  let spec = content["builderSpec"] as? [String: Any], spec["version"] as? Int == 1,
                  let surfaces = spec["surfaces"] as? [String: Any], surfaces["lockScreen"] is [String: Any] else {
                throw AppError("A custom layout requires template: builder, builderSpec.version: 1, and builderSpec.surfaces.lockScreen.")
            }
        }
        let render = try Self.jsonRender(from: content["jsonRender"])
        let lockScreen = render?["lockScreen"]
        let app = render?["app"]
        let delivery: [AlertSurface]
        if !surfaces.isEmpty {
            delivery = surfaces.reduce(into: []) { selected, surface in
                if !selected.contains(surface) { selected.append(surface) }
            }
        } else if render != nil {
            delivery = [.liveActivity, .inApp].filter { surface in
                surface == .liveActivity ? lockScreen != nil : app != nil
            }
        } else {
            delivery = event == .end ? [.liveActivity] : [.liveActivity, .notification]
        }
        guard delivery.contains(.inApp) == (app != nil) else {
            throw AppError("Choose --surface in_app together with jsonRender.app.")
        }
        guard lockScreen == nil || delivery.contains(.liveActivity) else {
            throw AppError("jsonRender.lockScreen requires --surface live_activity.")
        }
        if app != nil, !delivery.contains(.liveActivity), event != .update {
            throw AppError("An in-app report without a Live Activity uses the update event.")
        }
        guard event != .end || delivery == [.liveActivity] else {
            throw AppError("End events require only the live_activity surface.")
        }

        let base = try AlertRequest(
            title: title, summary: content["summary"] as? String, activityID: activityID,
            status: status, event: event, sourceName: content["sourceName"] as? String,
            notify: delivery.contains(.notification), now: now
        )
        let encoded = try JSONEncoder().encode(base)
        var envelope = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var payload = envelope["payload"] as! [String: Any]
        payload.merge(content.filter { $0.key != "jsonRender" }) { _, value in value }
        payload["title"] = base.payload.title
        payload["summary"] = base.payload.summary
        payload["sourceName"] = base.payload.sourceName
        envelope["payload"] = payload
        envelope["surfaces"] = delivery.map(\.rawValue)
        if let render { envelope["json_render"] = render }

        if delivery.contains(.liveActivity) {
            // An upsert may build a start envelope. Only the compact spec and a reserved report ID travel in it.
            if let lockScreen { payload["jsonRenderLockScreen"] = lockScreen }
            if app != nil { payload["inAppReportID"] = "00000000-0000-0000-0000-000000000000" }
            try Self.checkLiveActivityBudget(payload, base: base)
        } else {
            for key in ["activity_id", "update_mode", "attributes_type", "attributes", "alert"] {
                envelope.removeValue(forKey: key)
            }
        }
        body = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= 65_536 else { throw AppError("The JSON request exceeds the service's 64 KiB limit.") }
        idempotencyKey = base.idempotencyKey
    }

    private static func jsonRender(from value: Any?) throws -> [String: Any]? {
        guard let value else { return nil }
        guard let render = value as? [String: Any],
              Set(render.keys).isSubset(of: ["version", "lockScreen", "app"]),
              let version = render["version"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              render["lockScreen"] != nil || render["app"] != nil else {
            throw AppError("jsonRender requires version 1 and a lockScreen or app spec.")
        }
        for (key, limit) in [("lockScreen", 2_048), ("app", 49_152)] {
            guard let rawSpec = render[key] else { continue }
            guard let spec = rawSpec as? [String: Any],
                  let root = spec["root"] as? String, !root.isEmpty,
                  let elements = spec["elements"] as? [String: Any], elements[root] is [String: Any] else {
                throw AppError("jsonRender.\(key) requires a root that names an element.")
            }
            let data = try JSONSerialization.data(withJSONObject: spec, options: [.withoutEscapingSlashes])
            guard data.count <= limit else {
                throw AppError("jsonRender.\(key) exceeds its \(limit)-byte limit.")
            }
        }
        return render
    }

    private static func checkLiveActivityBudget(_ content: [String: Any], base: AlertRequest) throws {
        var aps: [String: Any] = [
            "timestamp": base.payload.generatedAt, "event": base.event == .end ? "end" : "start", "content-state": content
        ]
        if base.event != .end {
            aps["attributes-type"] = "ReportKitSimpleAttributes"
            aps["attributes"] = ["reportID": base.activityID]
            aps["input-push-token"] = 1
            aps["alert"] = ["title": base.payload.title, "body": base.payload.summary, "sound": "default"]
        }
        let push = ["aps": aps]
        let pushBytes = try JSONSerialization.data(withJSONObject: push, options: [.withoutEscapingSlashes]).count
        guard pushBytes + Self.numericHeadroom(push) <= 4_096 else {
            throw AppError("The Live Activity may exceed the 4096-byte APNs limit, including its envelope. Shorten the layout or its data.")
        }
    }

    private static func numericHeadroom(_ value: Any) -> Int {
        if let object = value as? [String: Any] { return object.values.reduce(0) { $0 + numericHeadroom($1) } }
        if let array = value as? [Any] { return array.reduce(0) { $0 + numericHeadroom($1) } }
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        // JavaScript can expand Foundation's scientific notation (1e+20 -> 100000000000000000000).
        // Reserve up to 32 bytes per finite number, more than any JavaScript double representation.
        let encoded = try? JSONSerialization.data(withJSONObject: number, options: [.fragmentsAllowed])
        return max(0, 32 - (encoded?.count ?? 0))
    }
}
