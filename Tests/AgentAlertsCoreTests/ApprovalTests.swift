import Foundation
import Testing
@testable import AgentAlertsCore

private actor ApprovalRequests {
    private(set) var values: [AlertRequest] = []
    func record(_ value: AlertRequest) { values.append(value) }
}

private actor ApprovalReplyGate {
    private(set) var value: String?
    private(set) var completed = false
    private var paused = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        paused = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { waiter = $0 }
    }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func answer(_ value: String) {
        self.value = value
        waiter?.resume()
        waiter = nil
    }

    func complete() { completed = true }
}

private final class ApprovalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1000)

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        value.addTimeInterval(seconds)
    }
}

struct ApprovalTests {
    private static let current = Date(timeIntervalSince1970: 1000)
    private static let expiry = Date(timeIntervalSince1970: 2000)

    private static func input(
        event: String = "PermissionRequest", tool: String = "Bash", action: String = "swift test", field: String = "command"
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hook_event_name": event, "tool_name": tool, "tool_input": [field: action],
            "session_id": "session-one", "cwd": "/Users/test/Example",
            "transcript_path": "/never-open/private.jsonl", "last_assistant_message": "PRIVATE REPLY",
        ])
    }

    private static func sent(
        id: String, status: String = "sent", successes: Int = 1, failures: Int = 0,
        interactionStatus: String = "pending", originalDelivered: Bool = true
    ) throws -> SendResponse {
        let data = try JSONSerialization.data(withJSONObject: [
            "ok": true, "status": status, "success_count": successes, "failure_count": failures,
            "original_alert_delivered": originalDelivered,
            "interaction_id": id, "interaction_status": interactionStatus,
            "interaction_expires_at": ISO8601DateFormatter().string(from: expiry),
        ])
        return try JSONDecoder().decode(SendResponse.self, from: data)
    }

    private static func response(
        id: String, status: String = "responded", kind: String = "yes_no", value: String? = "yes", expiresAt: Date = expiry
    ) throws -> InteractionStatusResponse {
        var interaction: [String: Any] = [
            "interaction_id": id, "status": status, "kind": kind,
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
        ]
        if let value { interaction["response_value"] = value }
        let data = try JSONSerialization.data(withJSONObject: ["ok": true, "interaction": interaction])
        return try JSONDecoder().decode(InteractionStatusResponse.self, from: data)
    }

    private static func coordinator() -> ApprovalCoordinator {
        ApprovalCoordinator(now: { current }, sleep: { _ in })
    }

    @Test func waitsForAnActualMatchingReply() async throws {
        let id = UUID().uuidString
        let gate = ApprovalReplyGate()
        let coordinator = ApprovalCoordinator(now: { Self.current }, sleep: { _ in await gate.pause() })
        let pending = Task {
            let decision = try await coordinator.request(agent: .codex, input: Self.input(), send: { _ in
                try Self.sent(id: id)
            }, status: { requestedID in
                let value = await gate.value
                return try Self.response(id: requestedID, status: value == nil ? "pending" : "responded", value: value)
            })
            await gate.complete()
            return decision
        }
        await gate.waitUntilPaused()
        let completedWhilePending = await gate.completed
        #expect(!completedWhilePending)
        await gate.answer("yes")
        #expect(try await pending.value == .allow)
    }

    @Test(arguments: ["yes", "no"])
    func exactYesNoControlsDecision(value: String) async throws {
        let id = UUID().uuidString
        for agent in HookAgent.allCases {
            let decision = try await Self.coordinator().request(agent: agent, input: Self.input(), send: { request in
                #expect(request.notification != nil)
                #expect(request.payload.title == "\(agent.displayName) approve action?")
                return try Self.sent(id: id)
            }, status: { requestedID in
                #expect(UUID(uuidString: requestedID) == UUID(uuidString: id))
                return try Self.response(id: requestedID, value: value)
            })
            #expect(decision == (value == "yes" ? .allow : .deny))
        }
    }

    @Test func pendingTimesOutWithoutGrantingPermission() async throws {
        let id = UUID().uuidString
        let clock = ApprovalClock()
        let coordinator = ApprovalCoordinator(timeoutSeconds: 5, pollInterval: 2, now: { clock.read() }, sleep: { clock.advance($0) })
        let decision = try await coordinator.request(agent: .codex, input: Self.input(), send: { _ in
            try Self.sent(id: id)
        }, status: { try Self.response(id: $0, status: "pending", value: nil) })
        #expect(decision == nil)
        #expect(clock.read() == Self.current.addingTimeInterval(5))
    }

    @Test(arguments: ["unknown", "expired"])
    func terminalNonResponseCannotApprove(state: String) async throws {
        let id = UUID().uuidString
        do {
            let decision = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
                try Self.sent(id: id)
            }, status: { try Self.response(id: $0, status: state) })
            #expect(state == "expired" && decision == nil)
        } catch {
            #expect(state == "unknown")
        }
    }

    @Test(arguments: ["YES", "allow", "", " yes "])
    func unrecognizedAnswersCannotApprove(value: String) async throws {
        let id = UUID().uuidString
        do {
            _ = try await Self.coordinator().request(agent: .claude, input: Self.input(), send: { _ in try Self.sent(id: id) }, status: {
                try Self.response(id: $0, value: value)
            })
            Issue.record("An unrecognized response was accepted")
        } catch { #expect(error is AppError) }
    }

    @Test func wrongRequestOrInteractionKindCannotApprove() async throws {
        let id = UUID().uuidString
        for wrongID in [true, false] {
            do {
                _ = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in try Self.sent(id: id) }, status: {
                    try Self.response(id: wrongID ? UUID().uuidString : $0, kind: wrongID ? "yes_no" : "text")
                })
                Issue.record("An unrelated response was accepted")
            } catch { #expect(error is AppError) }
        }
    }

    @Test func expiredResponseCannotApprove() async throws {
        let id = UUID().uuidString
        let decision = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
            try Self.sent(id: id)
        }, status: { try Self.response(id: $0, expiresAt: Self.current) })
        #expect(decision == nil)
    }

    @Test(arguments: ["failed", "no_targets", "quota_limited"])
    func undeliveredRequestsNeverWaitOrApprove(state: String) async throws {
        do {
            _ = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
                try Self.sent(id: UUID().uuidString, status: state, successes: 0, originalDelivered: false)
            }, status: { _ in
                Issue.record("An undelivered request must not be polled")
                return try Self.response(id: UUID().uuidString)
            })
            Issue.record("An undelivered approval was accepted")
        } catch { #expect(error is AppError) }
    }

    @Test func partialDeliveryCanWaitForItsPendingInteraction() async throws {
        let id = UUID().uuidString
        let decision = try await Self.coordinator().request(agent: .claude, input: Self.input(), send: { _ in
            try Self.sent(id: id, status: "partial", successes: 1, failures: 1)
        }, status: { try Self.response(id: $0) })
        #expect(decision == .allow)
    }

    @Test func transportFailureAndCancellationDoNotProduceDecision() async throws {
        let id = UUID().uuidString
        for cancel in [false, true] {
            do {
                _ = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
                    if !cancel { throw AppError("Transport unavailable") }
                    return try Self.sent(id: id)
                }, status: { _ in throw CancellationError() })
                Issue.record("Failure produced a decision")
            } catch {
                #expect(cancel ? error is CancellationError : error is AppError)
            }
        }
    }

    @Test func cancellationAfterSendCannotAcceptAReply() async throws {
        let id = UUID().uuidString
        let gate = ApprovalReplyGate()
        let request = Task {
            try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
                await gate.pause()
                return try Self.sent(id: id)
            }, status: { _ in
                Issue.record("A cancelled approval must not poll or accept a reply")
                return try Self.response(id: id)
            })
        }
        await gate.waitUntilPaused()
        request.cancel()
        await gate.answer("unused")
        do {
            _ = try await request.value
            Issue.record("Cancelled approval produced a decision")
        } catch { #expect(error is CancellationError) }
    }

    @Test func malformedOrAlreadyRespondedSendAcknowledgementIsRejected() async throws {
        for invalidID in [true, false] {
            do {
                _ = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { _ in
                    try Self.sent(id: invalidID ? "not-an-id" : UUID().uuidString, interactionStatus: invalidID ? "pending" : "responded")
                }, status: { _ in
                    Issue.record("An invalid initial acknowledgement must not be polled")
                    return try Self.response(id: UUID().uuidString)
                })
                Issue.record("Invalid initial acknowledgement was accepted")
            } catch { #expect(error is AppError) }
        }
    }

    @Test func newInvocationsDoNotReuseAnEarlierDecision() async throws {
        let recorder = ApprovalRequests()
        for _ in 0..<2 {
            let id = UUID().uuidString
            _ = try await Self.coordinator().request(agent: .codex, input: Self.input(), send: { request in
                await recorder.record(request)
                return try Self.sent(id: id)
            }, status: { try Self.response(id: $0) })
        }
        let requests = await recorder.values
        #expect(requests.count == 2)
        #expect(requests[0].idempotencyKey != requests[1].idempotencyKey)
        #expect(requests[0].activityID == requests[1].activityID)
        #expect(requests[0].activityID == "codex-\(StableIdentity.digest("codex\nsession-one").prefix(24))")
    }

    @Test func requestDetailsAreCompleteAndSecretsAreRedacted() async throws {
        let id = UUID().uuidString
        let recorder = ApprovalRequests()
        let command = "TOKEN=top-secret swift test --password 'other-secret' rk_agent_abcdefghijklmnopqrstuvwxyz"
        _ = try await Self.coordinator().request(agent: .codex, input: Self.input(action: command), send: { request in
            await recorder.record(request)
            return try Self.sent(id: id)
        }, status: { try Self.response(id: $0) })
        let request = try #require(await recorder.values.first)
        let body = try #require(request.notification?.body)
        #expect(body.contains("Bash in Example:"))
        #expect(body.contains("swift test"))
        #expect(body.contains("[redacted]"))
        #expect(!body.contains("top-secret") && !body.contains("other-secret") && !body.contains("rk_agent_"))
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        #expect(!encoded.contains("PRIVATE REPLY") && !encoded.contains("private.jsonl"))
    }

    @Test func unsupportedOrUnpresentableActionsKeepNativeApproval() async throws {
        let values = [
            try Self.input(event: "Notification"),
            try Self.input(tool: "AskUserQuestion"),
            try Self.input(tool: "ExitPlanMode"),
            try Self.input(action: String(repeating: "x", count: 241)),
            try Self.input(action: String(repeating: "😀", count: 120)),
            try Self.input(action: "swift test\nrm -rf something"),
            try Self.input(action: "private", field: "unrecognized"),
        ]
        for input in values {
            let decision = try await Self.coordinator().request(agent: .claude, input: input, send: { _ in
                Issue.record("Unsupported action must remain in the native approval flow")
                return try Self.sent(id: UUID().uuidString)
            }, status: { try Self.response(id: $0) })
            #expect(decision == nil)
        }
    }

    @Test func fileTargetIsShownWithoutReadingItsContents() async throws {
        let id = UUID().uuidString
        _ = try await Self.coordinator().request(agent: .claude, input: Self.input(tool: "Write", action: "/does/not/exist.swift", field: "file_path"), send: { request in
            #expect(request.notification?.body == "Write in Example: /does/not/exist.swift")
            return try Self.sent(id: id)
        }, status: { try Self.response(id: $0, value: "no") })
    }

    @Test func commonSecretFormsAreRedactedWithoutHidingOrdinaryCommandWords() async throws {
        let id = UUID().uuidString
        let command = "API_KEY=abc curl --token=def -H 'Authorization: Bearer ghi' https://user:password@example.com"
        _ = try await Self.coordinator().request(agent: .codex, input: Self.input(action: command), send: { request in
            let body = try #require(request.notification?.body)
            #expect(!body.contains("abc") && !body.contains("def") && !body.contains("ghi"))
            #expect(!body.contains("user:password"))
            #expect(body.contains("curl"))
            #expect(body.contains("https://[redacted]@example.com"))
            return try Self.sent(id: id)
        }, status: { try Self.response(id: $0, value: "no") })
        _ = try await Self.coordinator().request(agent: .codex, input: Self.input(action: "echo API_TOKEN rm -rf /example"), send: { request in
            #expect(request.notification?.body == "Bash in Example: echo API_TOKEN rm -rf /example")
            return try Self.sent(id: UUID().uuidString)
        }, status: { try Self.response(id: $0, value: "no") })
    }
}
