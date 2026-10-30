import Foundation
import Testing
@testable import AgentAlertsCore

@Suite struct AlertTests {
    @Test func interactiveSetupExplicitlyRequestsReplyAccess() throws {
        let instructions = try SetupInstructions(access: .interactive)
        let components = try #require(URLComponents(url: instructions.setupURL, resolvingAgainstBaseURL: false))
        #expect(components.queryItems?.contains(URLQueryItem(name: "access", value: "interactive")) == true)
    }

    @Test func approvalPayloadIncludesAnExpiringInteractionAndActionDetails() throws {
        let request = try AlertRequest(
            title: "Codex approve action?", summary: "Approve Bash in Example?", activityID: "request",
            interaction: AlertInteraction(expiresAt: Date(timeIntervalSince1970: 1000)),
            notificationBody: "Bash in Example: git status"
        )
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let interaction = try #require(body["interaction"] as? [String: Any])
        #expect(interaction["kind"] as? String == "yes_no")
        #expect(interaction["expires_at"] as? String == "1970-01-01T00:16:40Z")
        #expect(request.notification?.body == "Bash in Example: git status")
        #expect(throws: AppError.self) {
            try AlertRequest(title: "Approval", activityID: "x", notify: false, interaction: AlertInteraction(expiresAt: Date()))
        }
    }

    @Test func updateUsesExistingHostedContract() throws {
        let request = try AlertRequest(title: "Build finished", activityID: "build")
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(body["event"] as? String == "update")
        #expect(body["activity_id"] as? String == "build")
        #expect(body["update_mode"] as? String == "upsert_single")
        #expect(body["apns_env"] as? String == "production")
        #expect(body["surfaces"] as? [String] == ["live_activity", "notification"])
        #expect(body["idempotency_key"] as? String == request.idempotencyKey)
        let payload = try #require(body["payload"] as? [String: Any])
        #expect(payload["title"] as? String == "Build finished")
        #expect(payload["summary"] as? String == "Build finished")
        #expect(payload["status"] as? String == "good")
        #expect(payload["template"] as? String == "agent")
        #expect(payload["sourceIcon"] as? String == "terminal.fill")
        let notification = try #require(body["notification"] as? [String: Any])
        #expect(notification["body"] as? String == "Build finished")
        #expect(body["activityId"] == nil)
    }

    @Test func startAndEndDoNotUpsert() throws {
        for event in [AlertEvent.start, .end] {
            let request = try AlertRequest(title: "Build", activityID: "build", event: event)
            #expect(request.updateMode == nil)
        }
        let ended = try AlertRequest(title: "Done", activityID: "build", event: .end)
        #expect(ended.notification == nil)
        #expect(ended.surfaces == ["live_activity"])
    }

    @Test func explicitStartContainsRequiredActivityKitAttributes() throws {
        let request = try AlertRequest(title: "Build started", activityID: "build", event: .start)
        let body = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        #expect(body["attributes_type"] as? String == "ReportKitSimpleAttributes")
        let attributes = try #require(body["attributes"] as? [String: Any])
        #expect(attributes["reportID"] as? String == "build")
        let alert = try #require(body["alert"] as? [String: Any])
        #expect(alert["title"] as? String == "Build started")
        #expect(alert["body"] as? String == "Build started")
        #expect(alert["sound"] as? String == "default")
        let update = try AlertRequest(title: "Build", activityID: "build")
        #expect(update.attributes == nil && update.attributesType == nil && update.alert == nil)
    }

    @Test func progressCanUpdateOnlyLiveActivity() throws {
        let request = try AlertRequest(title: "Codex planning", activityID: "session", notify: false)
        #expect(request.surfaces == ["live_activity"])
        #expect(request.notification == nil)
        #expect(request.updateMode == "upsert_single")
    }

    @Test func rejectsInvalidVisibleCopy() throws {
        #expect(throws: AppError.self) { try AlertRequest(title: " ", activityID: "test") }
        #expect(throws: AppError.self) { try AlertRequest(title: String(repeating: "a", count: 33), activityID: "test") }
        #expect(throws: AppError.self) {
            try AlertRequest(title: "Build", summary: String(repeating: "a", count: 97), activityID: "test")
        }
        #expect(throws: AppError.self) { try AlertRequest(title: "Build\u{1B}", activityID: "test") }
        #expect(throws: AppError.self) { try AlertRequest(title: "Build", activityID: " ") }
        #expect(throws: AppError.self) { try AlertRequest(title: "Build", activityID: String(repeating: "a", count: 256)) }
    }

    @Test func countsUnicodeScalarsLikeServiceBudgets() throws {
        let valid = String(repeating: "é", count: 32)
        #expect(try AlertRequest(title: valid, activityID: "test").payload.title == valid)
        // Each grapheme has two scalars, matching Array.from() in the existing payload linter.
        #expect(throws: AppError.self) { try AlertRequest(title: String(repeating: "e\u{301}", count: 17), activityID: "test") }
    }

    @Test func manualIdentityIsStableAndDoesNotExposePaths() {
        let first = StableIdentity.manualActivityID(directory: "/private/tmp/workspace")
        #expect(first == StableIdentity.manualActivityID(directory: "/private/tmp/workspace/."))
        #expect(first != StableIdentity.manualActivityID(directory: "/private/tmp/other"))
        #expect(!first.contains("workspace"))
    }

    @Test func setupEncodesConnectionNameWithoutSecrets() throws {
        let instructions = try SetupInstructions(name: "My Mac & iPhone")
        let components = try #require(URLComponents(url: instructions.setupURL, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "https")
        #expect(components.host == "www.andreas.ink")
        #expect(components.path == "/agent")
        #expect(components.queryItems == [URLQueryItem(name: "name", value: "My Mac & iPhone")])
        #expect(throws: AppError.self) { try SetupInstructions(name: " ") }
    }

    @Test(arguments: ["failed", "partial", "no_targets", "no_active_activity", "quota_limited", "unexpected"])
    func nonDeliveryIsNotSuccess(status: String) throws {
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "status": status])
        let response = try JSONDecoder().decode(SendResponse.self, from: data)
        #expect(!response.accepted)
    }

    @Test func acknowledgementRetainsCountsAndQuota() throws {
        let response = try JSONDecoder().decode(SendResponse.self, from: Data("""
        {"ok":true,"status":"quota_limited","target_count":2,"success_count":0,"failure_count":0,
         "original_alert_delivered":false,"retryable":false,"quota_used":5,"quota_limit":5}
        """.utf8))
        #expect(!response.accepted)
        #expect(response.description.contains("do not retry"))
        #expect(response.description.contains("not device-confirmed"))
        let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        #expect(encoded["target_count"] as? Int == 2)
        #expect(encoded["failure_count"] as? Int == 0)
        #expect(encoded["quota_limit"] as? Int == 5)
        #expect(encoded["original_alert_delivered"] as? Bool == false)
    }

    @Test func sentWithFailuresOrUndeliveredOriginalIsNotSuccess() throws {
        for extra in ["\"failure_count\":1", "\"original_alert_delivered\":false"] {
            let response = try JSONDecoder().decode(SendResponse.self, from: Data("{\"ok\":true,\"status\":\"sent\",\(extra)}".utf8))
            #expect(!response.accepted)
        }
    }
}
