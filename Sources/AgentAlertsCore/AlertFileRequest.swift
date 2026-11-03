import Darwin
import CoreFoundation
import Foundation

/// A content-state file uses the same routing, notification, and identity defaults as a headline send.
public struct AlertFileRequest: Sendable {
    let body: Data
    let idempotencyKey: String

    public init(contentsOf url: URL, activityID: String, event: AlertEvent = .update) throws {
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK)
        guard descriptor >= 0 else { throw AppError("Cannot read the JSON file.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AppError("--file requires a regular JSON file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 65_537) ?? Data()
        try self.init(data: data, activityID: activityID, event: event)
    }

    init(data: Data, activityID: String, event: AlertEvent = .update, now: Date = Date()) throws {
        guard data.count <= 65_536 else { throw AppError("The JSON file must be at most 64 KiB.") }
        guard let content = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AppError("The JSON file must contain a Live Activity content object.")
        }
        // Content only: routing, credentials, timestamps, and interactions remain CLI-managed.
        let fields: Set<String> = [
            "title", "summary", "status", "sourceName", "sourceIcon", "template", "builderSpec", "data",
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
        let base = try AlertRequest(
            title: title, summary: content["summary"] as? String, activityID: activityID,
            status: status, event: event, sourceName: content["sourceName"] as? String, now: now
        )
        let encoded = try JSONEncoder().encode(base)
        var envelope = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        var payload = envelope["payload"] as! [String: Any]
        payload.merge(content) { _, value in value }
        payload["title"] = base.payload.title
        payload["summary"] = base.payload.summary
        payload["sourceName"] = base.payload.sourceName
        envelope["payload"] = payload
        // An upsert may start an activity. Budget that larger APNs envelope before any network request.
        var aps: [String: Any] = [
            "timestamp": base.payload.generatedAt, "event": event == .end ? "end" : "start", "content-state": payload,
        ]
        if event != .end {
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
        body = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys, .withoutEscapingSlashes])
        guard body.count <= 65_536 else { throw AppError("The JSON request exceeds the service's 64 KiB limit.") }
        idempotencyKey = base.idempotencyKey
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
