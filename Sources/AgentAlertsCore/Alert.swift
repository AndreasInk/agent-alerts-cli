import CryptoKit
import Foundation

public struct AppError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum AlertEvent: String, Codable, CaseIterable, Sendable {
    case start, update, end
}

public enum AlertStatus: String, Codable, CaseIterable, Sendable {
    case good, warning, critical
}

public struct AlertInteraction: Codable, Sendable {
    public let kind = "yes_no"
    public let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case kind
        case expiresAt = "expires_at"
    }

    public init(expiresAt: Date) {
        self.expiresAt = ISO8601DateFormatter().string(from: expiresAt)
    }
}

public enum StableIdentity {
    public static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func manualActivityID(directory: String) -> String {
        let path = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath().path
        return "cli-\(digest(path).prefix(24))"
    }
}

public struct AlertRequest: Codable, Sendable {
    public struct Payload: Codable, Sendable {
        public let title: String
        public let summary: String
        public let status: AlertStatus
        public let generatedAt: Int
        public let sourceName: String
        public let sourceIcon: String
        public let template: String
    }

    public struct Notification: Codable, Sendable {
        public let title: String
        public let body: String
    }

    public struct Attributes: Codable, Sendable {
        public let reportID: String
    }

    public struct StartAlert: Codable, Sendable {
        public let title: String
        public let body: String
        public let sound: String
    }

    public let event: AlertEvent
    public let activityID: String
    public let updateMode: String?
    public let surfaces: [String]
    public let payload: Payload
    public let notification: Notification?
    public let apnsEnvironment: String
    public let idempotencyKey: String
    public let attributesType: String?
    public let attributes: Attributes?
    public let alert: StartAlert?
    public let interaction: AlertInteraction?

    enum CodingKeys: String, CodingKey {
        case event, surfaces, payload, notification, attributes, alert, interaction
        case activityID = "activity_id"
        case updateMode = "update_mode"
        case apnsEnvironment = "apns_env"
        case idempotencyKey = "idempotency_key"
        case attributesType = "attributes_type"
    }

    public init(
        title: String,
        summary: String? = nil,
        activityID: String,
        status: AlertStatus = .good,
        event: AlertEvent = .update,
        sourceName: String? = nil,
        notify: Bool = true,
        interaction: AlertInteraction? = nil,
        notificationBody: String? = nil,
        idempotencyKey: String = UUID().uuidString,
        now: Date = Date()
    ) throws {
        let title = try Self.text(title, label: "Title", limit: 32)
        let summary = try Self.text(summary ?? title, label: "Summary", limit: 96)
        self.activityID = try Self.text(activityID, label: "Activity ID", limit: 255)
        self.idempotencyKey = try Self.text(idempotencyKey, label: "Idempotency key", limit: 200)
        let sourceName = try Self.text(sourceName ?? "Agent Alerts", label: "Source name", limit: 40)
        self.event = event
        updateMode = event == .update ? "upsert_single" : nil
        surfaces = event == .end || !notify ? ["live_activity"] : ["live_activity", "notification"]
        payload = Payload(
            title: title, summary: summary, status: status,
            generatedAt: Int(now.timeIntervalSince1970),
            sourceName: sourceName, sourceIcon: "terminal.fill", template: "agent"
        )
        let body = try Self.text(notificationBody ?? summary, label: "Notification", limit: 240)
        guard body.utf16.count <= 240 else { throw AppError("Notification must fit within 240 characters.") }
        guard interaction == nil || (notify && event != .end) else {
            throw AppError("An approval request requires a notification.")
        }
        notification = event == .end || !notify ? nil : Notification(title: title, body: body)
        self.interaction = interaction
        apnsEnvironment = "production"
        attributesType = event == .start ? "ReportKitSimpleAttributes" : nil
        attributes = event == .start ? Attributes(reportID: self.activityID) : nil
        alert = event == .start ? StartAlert(title: title, body: summary, sound: "default") : nil
    }

    private static func text(_ raw: String, label: String, limit: Int) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.unicodeScalars.count <= limit,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError("\(label) must be 1–\(limit) characters without control characters.")
        }
        return value
    }
}

public struct SendResponse: Codable, Sendable {
    public let ok: Bool
    public let status: String
    public let targetCount: Int?
    public let successCount: Int?
    public let failureCount: Int?
    public let originalAlertDelivered: Bool?
    public let retryable: Bool?
    public let upgradeStateStatus: String?
    public let eventID: String?
    public let activityID: String?
    public let idempotencyKey: String?
    public let activityRoutingStatus: String?
    public let quotaUsed: Int?
    public let quotaLimit: Int?
    public let quotaResetAt: String?
    public let interactionID: String?
    public let interactionStatus: String?
    public let interactionExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case ok, status, retryable
        case targetCount = "target_count"
        case successCount = "success_count"
        case failureCount = "failure_count"
        case originalAlertDelivered = "original_alert_delivered"
        case upgradeStateStatus = "upgrade_state_status"
        case eventID = "event_id"
        case activityID = "activity_id"
        case idempotencyKey = "idempotency_key"
        case activityRoutingStatus = "activity_routing_status"
        case quotaUsed = "quota_used"
        case quotaLimit = "quota_limit"
        case quotaResetAt = "quota_reset_at"
        case interactionID = "interaction_id"
        case interactionStatus = "interaction_status"
        case interactionExpiresAt = "interaction_expires_at"
    }

    public var accepted: Bool {
        ok && ["sent", "queued", "would_be_quota_limited"].contains(status)
            && originalAlertDelivered != false && (failureCount ?? 0) == 0
    }

    public var description: String {
        let knownStatuses = ["sent", "queued", "partial", "failed", "no_targets", "no_active_activity",
                             "quota_limited", "would_be_quota_limited", "duplicate"]
        let label = knownStatuses.contains(status) ? status : "unrecognized response"
        var result = "Agent Alerts: \(label)"
        if let targetCount {
            result += " · APNs \(successCount ?? 0)/\(targetCount) accepted · \(failureCount ?? 0) failed"
        }
        if status == "quota_limited" {
            result += "; original alert not delivered"
        }
        if retryable == false { result += "; do not retry" }
        return result + " · not device-confirmed"
    }
}
