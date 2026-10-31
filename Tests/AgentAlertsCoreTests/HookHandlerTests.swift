import Foundation
import Testing
@testable import AgentAlertsCore

private actor HookRecorder {
    private(set) var requests: [AlertRequest] = []
    func record(_ request: AlertRequest) { requests.append(request) }
}

private final class HookWarnings: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func record(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

struct HookHandlerTests {
    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agent-alerts-handler-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func input(
        _ name: String = "Stop", session: String = "session-1", turn: String? = nil,
        extras: [String: Any] = [:]
    ) throws -> Data {
        var object: [String: Any] = [
            "hook_event_name": name,
            "session_id": session,
            "cwd": "/Users/test/Important Project",
            "transcript_path": "/do-not-read/private.jsonl",
            "last_assistant_message": "PRIVATE REPLY",
            "tool_input": ["command": "PRIVATE COMMAND"],
        ]
        if let turn { object["turn_id"] = turn }
        object.merge(extras, uniquingKeysWith: { _, new in new })
        return try JSONSerialization.data(withJSONObject: object)
    }

    private func handler(
        _ root: URL,
        idle: @escaping @Sendable () throws -> TimeInterval = { 600 },
        time: TimeInterval = 1000,
        warning: @escaping @Sendable (String) -> Void = { _ in }
    ) -> HookHandler {
        HookHandler(
            environment: ["XDG_CACHE_HOME": root.path], home: root,
            idle: idle, now: { Date(timeIntervalSince1970: time) }, warning: warning
        )
    }

    @Test func completionUsesGenericCopyAndNoPrivateContent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root).handle(agent: .codex, input: input(), idleSeconds: 300) { request in
            await recorder.record(request)
        }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        let request = try #require(sent.first)
        #expect(request.payload.title == "Codex finished")
        #expect(request.payload.summary == "Project: Important Project.")
        #expect(request.payload.status == .good)
        #expect(request.payload.sourceName == "Codex")
        #expect(request.updateMode == "upsert_single")
        let encoded = try #require(String(data: JSONEncoder().encode(request), encoding: .utf8))
        #expect(!encoded.contains("PRIVATE"))
        #expect(!encoded.contains("Users"))
        #expect(!encoded.contains("session-1"))
    }

    @Test func codexPermissionRequestsNeverSendPassiveApprovalAlerts() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        // Even an idle Mac and distinct request IDs cannot establish user attention.
        for request in ["auto-review-one", "auto-review-two", "user-or-auto-unknown"] {
            try await handler(root, idle: { 3600 }).handle(
                agent: .codex,
                input: input("PermissionRequest", extras: ["request_id": request]),
                idleSeconds: 0
            ) { await recorder.record($0) }
        }
        #expect(await recorder.requests.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-alerts").path))
    }

    @Test func claudeEarlyPermissionRequestsStaySilentUntilPromptNotification() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for mode in ["default", "auto", "bypassPermissions", "acceptEdits", "plan"] {
            try await handler(root).handle(
                agent: .claude,
                input: input("PermissionRequest", extras: ["permission_mode": mode]),
                idleSeconds: 0
            ) { await recorder.record($0) }
        }
        #expect(await recorder.requests.isEmpty)
        // A real prompt without source request IDs still produces exactly one alert.
        try await handler(root).handle(
            agent: .claude,
            input: input("Notification", extras: ["notification_type": "permission_prompt"]),
            idleSeconds: 0
        ) { await recorder.record($0) }
        #expect(await recorder.requests.count == 1)
    }

    @Test func activeUseSkipsAlertAndCreatesNoCache() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root, idle: { 299.99 }).handle(agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt"]), idleSeconds: 300) { request in
            await recorder.record(request)
        }
        let sent = await recorder.requests
        #expect(sent.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-alerts").path))
    }

    @Test func idleBoundarySendsAndZeroNeverQueriesIdle() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root, idle: { 300 }).handle(agent: .codex, input: input(), idleSeconds: 300) { await recorder.record($0) }
        try await handler(root, idle: { throw AppError("Idle must not be queried") }).handle(
            agent: .codex, input: input(), idleSeconds: 0
        ) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 2)
    }

    @Test func invalidIdleSkipsWithError() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for value in [Double.nan, Double.infinity, -1] {
            do {
                try await handler(root, idle: { value }).handle(agent: .codex, input: input(), idleSeconds: 300) { await recorder.record($0) }
                Issue.record("Invalid idle measurement was accepted")
            } catch {
                #expect(error.localizedDescription.contains("idle"))
            }
        }
        let sent = await recorder.requests
        #expect(sent.isEmpty)
    }

    @Test func recursiveAndUnrelatedHooksDoNotSend() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [
            try input(extras: ["stop_hook_active": true]),
            try input("SubagentStop"),
            try input("PostToolUse"),
            try input("PreToolUse", extras: ["tool_name": "Bash"]),
            try input("Notification", extras: ["notification_type": "idle_prompt"]),
        ] {
            try await handler(root).handle(agent: .claude, input: data, idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.isEmpty)
    }

    @Test func claudeAttentionAndFailureMappings() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for (index, data) in [
            try input("Notification", session: "approval", extras: ["notification_type": "permission_prompt"]),
            try input("PreToolUse", session: "question", extras: ["tool_name": "AskUserQuestion"]),
            try input("Notification", session: "elicitation", extras: ["notification_type": "elicitation_dialog"]),
            try input("Notification", session: "url", extras: ["notification_type": "elicitation_url_dialog"]),
            try input("StopFailure", session: "failure"),
        ].enumerated() {
            try await handler(root, time: Double(1000 + index)).handle(agent: .claude, input: data, idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.map(\.payload.title) == [
            "Claude needs approval", "Claude needs your input", "Claude needs your input", "Claude needs your input", "Claude stopped with an error",
        ])
        #expect(sent.map(\.payload.status) == [.warning, .warning, .warning, .warning, .critical])
    }

    @Test func uncorrelatedAttentionEventsEachSend() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [
            try input("Notification", extras: ["notification_type": "permission_prompt"]),
            try input("Notification", extras: ["notification_type": "permission_prompt"]),
            try input("Notification", extras: ["notification_type": "permission_prompt"]),
        ] {
            try await handler(root).handle(agent: .claude, input: data, idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 3)
        #expect(Set(sent.map(\.idempotencyKey)).count == 3)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-alerts").path))
    }

    @Test func distinctRequestIDsInSameTurnEachSend() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for request in ["request-one", "request-two"] {
            try await handler(root).handle(
                agent: .claude,
                input: input("Notification", turn: "same-turn", extras: ["notification_type": "permission_prompt", "request_id": request]),
                idleSeconds: 0
            ) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 2)
        #expect(sent[0].idempotencyKey != sent[1].idempotencyKey)
    }

    @Test func repeatedExplicitRequestIsDeduplicated() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for _ in 0..<2 {
            try await handler(root).handle(
                agent: .claude,
                input: input("Notification", extras: ["tool_use_id": "same-request", "notification_type": "permission_prompt"]),
                idleSeconds: 0
            ) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 1)
    }

    @Test func malformedCacheRecoversAndSends() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("agent-alerts")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let file = cache.appendingPathComponent("events.json")
        try Data("{bad-json".utf8).write(to: file)
        let recorder = HookRecorder()
        let warnings = HookWarnings()
        try await handler(root, warning: { warnings.record($0) }).handle(
            agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt", "request_id": "request-one"]), idleSeconds: 0
        ) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        #expect(warnings.recorded == ["Invalid hook cache was reset."])
        #expect(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) is [String: Any])
    }

    @Test func unsafeCacheIsUntouchedAndDoesNotBlockAlert() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent("agent-alerts")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("outside.json")
        let original = Data("{do-not-touch".utf8)
        try original.write(to: outside)
        let link = cache.appendingPathComponent("events.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let recorder = HookRecorder()
        let warnings = HookWarnings()
        try await handler(root, warning: { warnings.record($0) }).handle(
            agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt", "request_id": "request-one"]), idleSeconds: 0
        ) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        #expect(try Data(contentsOf: outside) == original)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == outside.path)
        #expect(warnings.recorded.count == 1)
        #expect(warnings.recorded.first?.contains("without deduplication") == true)
    }

    @Test func separateSessionsAndTurnsStayIndependent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [try input("Notification", turn: "one", extras: ["notification_type": "permission_prompt"]), try input("Notification", turn: "two", extras: ["notification_type": "permission_prompt"]), try input("Notification", session: "two", extras: ["notification_type": "permission_prompt"])] {
            try await handler(root).handle(agent: .claude, input: data, idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 3)
        #expect(sent[0].activityID == sent[1].activityID)
        #expect(sent[0].activityID != sent[2].activityID)
        #expect(sent[0].idempotencyKey != sent[1].idempotencyKey)
    }

    @Test func consecutiveCompletionsAreNotMistakenForDuplicates() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for _ in 0..<2 {
            try await handler(root).handle(agent: .claude, input: input(), idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 2)
        #expect(sent[0].activityID == sent[1].activityID)
        #expect(sent[0].idempotencyKey != sent[1].idempotencyKey)
    }

    @Test func failedSendReleasesAttentionClaim() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        do {
            try await handler(root).handle(agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt", "request_id": "failed-request"]), idleSeconds: 0) { _ in throw AppError("Network unavailable") }
            Issue.record("The send failure should be returned")
        } catch { #expect(error.localizedDescription == "Network unavailable") }
        try await handler(root).handle(agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt", "request_id": "failed-request"]), idleSeconds: 0) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 1)
    }

    @Test func malformedAndOversizedInputNeverSend() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [Data("{".utf8), Data("[]".utf8), Data(repeating: 32, count: 1_048_577), Data("{\"hook_event_name\":\"Stop\"}".utf8)] {
            do {
                try await handler(root).handle(agent: .codex, input: data, idleSeconds: 0) { await recorder.record($0) }
                Issue.record("Invalid hook input should be rejected")
            } catch { }
        }
        let sent = await recorder.requests
        #expect(sent.isEmpty)
    }

    @Test func cacheDoesNotPersistPrivateMetadata() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await handler(root).handle(agent: .claude, input: input("Notification", extras: ["notification_type": "permission_prompt", "request_id": "private-request-id"]), idleSeconds: 0) { _ in }
        let text = try String(contentsOf: root.appendingPathComponent("agent-alerts/events.json"), encoding: .utf8)
        #expect(!text.contains("session-1"))
        #expect(!text.contains("Important Project"))
        #expect(!text.contains("PRIVATE"))
        #expect(!text.contains("private-request-id"))
    }

    @Test func promptModeShowsPlanningOrWorkingWithoutNotification() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for agent in HookAgent.allCases {
            let recorder = HookRecorder()
            for mode in ["plan", "default", "acceptEdits", "unknown"] {
                try await handler(root).handle(
                    agent: agent, input: input("UserPromptSubmit", extras: ["permission_mode": mode]), idleSeconds: 0
                ) { await recorder.record($0) }
            }
            let sent = await recorder.requests
            #expect(sent.map(\.payload.title) == [
                "\(agent.displayName) planning", "\(agent.displayName) working", "\(agent.displayName) working", "\(agent.displayName) working",
            ])
            #expect(sent.allSatisfy { $0.surfaces == ["live_activity"] && $0.notification == nil && $0.payload.status == .good })
            #expect(Set(sent.map(\.activityID)).count == 1)
            let encoded = try String(decoding: JSONEncoder().encode(sent), as: UTF8.self)
            #expect(!encoded.contains("progressPercent"))
            #expect(!encoded.contains("PRIVATE"))
        }
    }

    @Test func missingPromptModeFallsBackToWorking() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root).handle(agent: .codex, input: input("UserPromptSubmit"), idleSeconds: 0) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.first?.payload.title == "Codex working")
        #expect(sent.first?.notification == nil)
    }

    @Test func planModeStopReportsAnUpdateWithoutClaimingPlanReadiness() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for agent in HookAgent.allCases {
            try await handler(root).handle(
                agent: agent, input: input("Stop", extras: ["permission_mode": "plan"]), idleSeconds: 0
            ) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.map(\.payload.title) == ["Codex plan updated", "Claude plan updated"])
        #expect(sent.allSatisfy { $0.payload.status == .good && $0.notification != nil && $0.surfaces.contains("notification") })
    }

    @Test func claudeExitPlanUsesOneAuthoritativePassiveEvent() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root).handle(agent: .claude, input: input("PreToolUse", extras: ["tool_name": "ExitPlanMode"]), idleSeconds: 0) { await recorder.record($0) }
        try await handler(root, time: 1001).handle(agent: .claude, input: input("PermissionRequest", extras: ["tool_name": "ExitPlanMode"]), idleSeconds: 0) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        #expect(sent.first?.payload.title == "Claude plan ready")
    }

    @Test func modeProgressUsesTheSameActivityAsCompletion() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [
            try input("UserPromptSubmit", extras: ["permission_mode": "plan"]),
            try input("Stop", extras: ["permission_mode": "plan"]),
            try input("UserPromptSubmit", extras: ["permission_mode": "default"]),
            try input("Stop", extras: ["permission_mode": "default"]),
        ] {
            try await handler(root).handle(agent: .codex, input: data, idleSeconds: 0) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.map(\.payload.title) == ["Codex planning", "Codex plan updated", "Codex working", "Codex finished"])
        #expect(Set(sent.map(\.activityID)).count == 1)
    }

    @Test func quietProgressBypassesActiveSnoozing() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        for data in [
            try input("UserPromptSubmit", extras: ["permission_mode": "plan"]),
            try input("Stop", extras: ["permission_mode": "plan"]),
            try input("PreToolUse", extras: ["tool_name": "ExitPlanMode"]),
        ] {
            try await handler(root, idle: { 1 }).handle(agent: .claude, input: data, idleSeconds: 300) { await recorder.record($0) }
        }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        #expect(sent.first?.payload.title == "Claude planning")
        #expect(sent.first?.notification == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("agent-alerts").path))
    }

    @Test func quietWorkingDoesNotNeedIdleMeasurement() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HookRecorder()
        try await handler(root, idle: { throw AppError("Idle must not be queried") }).handle(
            agent: .codex, input: input("UserPromptSubmit"), idleSeconds: 300
        ) { await recorder.record($0) }
        let sent = await recorder.requests
        #expect(sent.count == 1)
        #expect(sent.first?.payload.title == "Codex working")
        #expect(sent.first?.notification == nil)
    }
}
