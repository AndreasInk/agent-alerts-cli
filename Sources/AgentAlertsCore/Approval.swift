import Foundation

public enum ApprovalDecision: Sendable, Equatable {
    case allow
    case deny
}

public struct ApprovalCoordinator: Sendable {
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let timeoutSeconds: TimeInterval
    private let pollInterval: TimeInterval

    public init(
        timeoutSeconds: TimeInterval = 86_400,
        pollInterval: TimeInterval = 5,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.timeoutSeconds = timeoutSeconds
        self.pollInterval = pollInterval
        self.now = now
        self.sleep = sleep
    }

    public func request(
        agent: HookAgent,
        input: Data,
        send: @Sendable (AlertRequest) async throws -> SendResponse,
        status: @Sendable (String) async throws -> InteractionStatusResponse
    ) async throws -> ApprovalDecision? {
        try Task.checkCancellation()
        guard timeoutSeconds.isFinite, timeoutSeconds > 0, pollInterval.isFinite, pollInterval > 0 else {
            throw AppError("Invalid approval wait settings. Use the agent's local approval prompt.")
        }
        guard input.count <= 1_048_576,
              let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            throw AppError("Invalid approval event. Use the agent's local approval prompt.")
        }
        guard event["hook_event_name"] as? String == "PermissionRequest",
              let tool = event["tool_name"] as? String,
              tool != "AskUserQuestion", tool != "ExitPlanMode",
              let toolInput = event["tool_input"] as? [String: Any],
              let session = event["session_id"] as? String, !session.isEmpty, session.utf8.count <= 512,
              let cwd = event["cwd"] as? String, cwd.hasPrefix("/"),
              let action = [toolInput["command"], toolInput["file_path"], toolInput["path"]]
                .compactMap({ $0 as? String }).first(where: { !$0.isEmpty }) else {
            return nil
        }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        guard Self.presentable(tool), Self.presentable(project), Self.presentable(action) else { return nil }
        let summary = "Approve \(tool) in \(project)?"
        let notificationBody = "\(tool) in \(project): \(Self.redacted(action))"
        // Approval details are complete or the agent keeps its native approval prompt.
        guard summary.unicodeScalars.count <= 96, notificationBody.utf16.count <= 240 else { return nil }

        let started = now()
        let deadline = started.addingTimeInterval(timeoutSeconds)
        let requestID = UUID().uuidString.lowercased()
        let request = try AlertRequest(
            title: "\(agent.displayName) approve action?", summary: summary,
            activityID: "\(agent.rawValue)-\(StableIdentity.digest(agent.rawValue + "\n" + session).prefix(24))", status: .warning,
            sourceName: agent.displayName, notify: true,
            interaction: AlertInteraction(expiresAt: deadline), notificationBody: notificationBody,
            idempotencyKey: "approval-\(requestID)", now: started
        )
        let sent = try await send(request)
        try Task.checkCancellation()
        guard sent.ok, ["sent", "partial", "queued", "would_be_quota_limited"].contains(sent.status),
              (sent.successCount ?? 0) > 0, sent.originalAlertDelivered != false,
              sent.interactionStatus == "pending", let id = sent.interactionID, let uuid = UUID(uuidString: id),
              let initialExpiry = sent.interactionExpiresAt.flatMap(Self.date), initialExpiry > now() else {
            throw AppError("The approval request was not delivered. Use the agent's local approval prompt.")
        }

        let expiresAt = min(deadline, initialExpiry)
        while now() < expiresAt {
            try Task.checkCancellation()
            let response = try await status(id)
            try Task.checkCancellation()
            guard response.ok, UUID(uuidString: response.interaction.interactionID) == uuid,
                  response.interaction.kind == "yes_no", let responseExpiry = Self.date(response.interaction.expiresAt) else {
                throw AppError("The approval response did not match this request. Use the agent's local approval prompt.")
            }
            guard now() < expiresAt, now() < responseExpiry else { return nil }
            switch response.interaction.status {
            case "responded":
                switch response.interaction.responseValue {
                case "yes": return .allow
                case "no": return .deny
                default:
                    throw AppError("Unrecognized approval response. Use the agent's local approval prompt.")
                }
            case "expired": return nil
            case "pending":
                let remaining = min(expiresAt, responseExpiry).timeIntervalSince(now())
                if remaining <= 0 { return nil }
                try await sleep(min(pollInterval, remaining))
            default:
                throw AppError("Invalid approval state. Use the agent's local approval prompt.")
            }
        }
        return nil
    }

    private static func presentable(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func redacted(_ action: String) -> String {
        var output = action
        let patterns = [
            (#"rk_agent_[A-Za-z0-9_-]+"#, "[redacted]"),
            (#"(?i)(x-api-key:\s*)[^\s\"']+"#, "$1[redacted]"),
            (#"(?i)(\b[A-Z0-9_]*(?:TOKEN|PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|AUTHORIZATION|CREDENTIAL)[A-Z0-9_]*\s*=\s*)(?:\"[^\"]*\"|'[^']*'|[^\s;&|]+)"#, "$1[redacted]"),
            (#"(?i)(--(?:token|password|passwd|secret|api-key|access-key|authorization)(?:\s*=\s*|\s+))(?:\"[^\"]*\"|'[^']*'|[^\s;&|]+)"#, "$1[redacted]"),
            (#"(?i)(\bAuthorization\s*:\s*(?:Bearer|Basic)\s+)[^\s\"']+"#, "$1[redacted]"),
            (#"(https?://)[^/\s:@]+:[^/@\s]+@"#, "$1[redacted]@"),
        ]
        for (pattern, replacement) in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            output = expression.stringByReplacingMatches(
                in: output, range: NSRange(output.startIndex..., in: output), withTemplate: replacement
            )
        }
        return output
    }
}
