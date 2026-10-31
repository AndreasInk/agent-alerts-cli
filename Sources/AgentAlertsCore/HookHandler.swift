import Darwin
import Foundation

public struct HookHandler: Sendable {
    private let environment: [String: String]
    private let home: URL
    private let idle: @Sendable () throws -> TimeInterval
    private let now: @Sendable () -> Date
    private let warning: @Sendable (String) -> Void

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        idle: @escaping @Sendable () throws -> TimeInterval = { try Idle.seconds() },
        now: @escaping @Sendable () -> Date = { Date() },
        warning: @escaping @Sendable (String) -> Void = {
            try? FileHandle.standardError.write(contentsOf: Data(("Agent Alerts hook: " + $0 + "\n").utf8))
        }
    ) {
        self.environment = environment
        self.home = home
        self.idle = idle
        self.now = now
        self.warning = warning
    }

    public func handle(
        agent: HookAgent,
        input: Data,
        idleSeconds: Int,
        send: @Sendable (AlertRequest) async throws -> Void
    ) async throws {
        guard idleSeconds >= 0 else { throw HookError("Idle seconds must be a non-negative integer.") }
        guard input.count <= 1_048_576,
              let event = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] else {
            throw HookError("Invalid hook JSON; automatic alert skipped.")
        }
        guard let kind = kind(for: agent, event: event) else { return }
        if event["stop_hook_active"] as? Bool == true { return }
        guard let session = event["session_id"] as? String, !session.isEmpty, session.utf8.count <= 512,
              let cwd = event["cwd"] as? String, cwd.hasPrefix("/"), cwd.utf8.count <= 16_384 else {
            throw HookError("Hook input requires a session ID and working directory; automatic alert skipped.")
        }
        if kind.notify && idleSeconds > 0 {
            let measured = try idle()
            guard measured.isFinite, measured >= 0 else {
                throw HookError("Cannot measure keyboard/mouse idle time; automatic alert skipped.")
            }
            guard measured >= Double(idleSeconds) else { return }
        }
        let time = now()
        let sessionDigest = StableIdentity.digest(agent.rawValue + "\n" + session)
        let isAttention = kind == .approval || kind == .input || kind == .planReady
        // Only source-provided request identities can prove two events are duplicates.
        // Uncorrelated attention events must each be delivered, even close together.
        let requestID = [event["request_id"], event["tool_use_id"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty && $0.utf8.count <= 1024 }
        let identity = isAttention ? requestID.map { sessionDigest + "\n" + kind.rawValue + "\n" + $0 } : nil
        let idempotency = identity.map { "hook-" + StableIdentity.digest($0) } ?? UUID().uuidString
        let cache = HookEventCache(directory: cacheDirectory, warning: warning)
        let claim = UUID().uuidString
        var claimed = false
        if let identity {
            do {
                guard try cache.claim(key: identity, id: claim, at: time) else { return }
                claimed = true
            } catch {
                cacheWarning(error)
            }
        }
        do {
            let rawProject = URL(fileURLWithPath: cwd).lastPathComponent
            let projectScalars = rawProject.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            let project = String(String.UnicodeScalarView(projectScalars.prefix(80)))
            let summary = project.isEmpty ? "Your agent has an update." : "Project: \(project)."
            let request = try AlertRequest(
                title: kind.title(agent: agent), summary: summary,
                activityID: "\(agent.rawValue)-\(sessionDigest.prefix(24))", status: kind.status,
                sourceName: agent.displayName, notify: kind.notify, idempotencyKey: idempotency, now: time
            )
            try await send(request)
        } catch {
            if claimed, let identity {
                do { try cache.release(key: identity, id: claim) }
                catch { cacheWarning(error) }
            }
            throw error
        }
    }

    private func cacheWarning(_ error: Error) {
        let reason = (error as? AppError)?.message ?? "Could not update the hook cache."
        warning(reason + " Sending alerts without deduplication.")
    }

    private var cacheDirectory: URL {
        if let path = environment["XDG_CACHE_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path).appendingPathComponent("agent-alerts")
        }
        return home.appendingPathComponent("Library/Caches/agent-alerts")
    }

    private enum Kind: String {
        case planning
        case working
        case planReady
        case planUpdate
        case completion
        case approval
        case input
        case failure

        var status: AlertStatus {
            switch self {
            case .planning, .working, .planUpdate, .completion: .good
            case .planReady, .approval, .input: .warning
            case .failure: .critical
            }
        }

        var notify: Bool { self != .planning && self != .working }

        func title(agent: HookAgent) -> String {
            switch self {
            case .planning: "\(agent.displayName) planning"
            case .working: "\(agent.displayName) working"
            case .planReady: "\(agent.displayName) plan ready"
            case .planUpdate: "\(agent.displayName) plan updated"
            case .completion: "\(agent.displayName) finished"
            case .approval: "\(agent.displayName) needs approval"
            case .input: "\(agent.displayName) needs your input"
            case .failure: "\(agent.displayName) stopped with an error"
            }
        }
    }

    private func kind(for agent: HookAgent, event: [String: Any]) -> Kind? {
        let isPlanning = event["permission_mode"] as? String == "plan"
        switch event["hook_event_name"] as? String {
        case "UserPromptSubmit": return isPlanning ? .planning : .working
        case "Stop": return isPlanning ? .planUpdate : .completion
        case "PermissionRequest":
            // This precedes the final approval outcome. Another hook may allow
            // the action without user input. Claude's delayed permission_prompt
            // notification is the passive attention signal; Codex has no equivalent.
            // Explicit phone approvals use ApprovalCoordinator instead.
            return nil
        case "StopFailure" where agent == .claude: return .failure
        case "PreToolUse" where agent == .claude:
            switch event["tool_name"] as? String {
            case "AskUserQuestion": return .input
            case "ExitPlanMode": return .planReady
            default: return nil
            }
        case "Notification" where agent == .claude:
            switch event["notification_type"] as? String {
            case "permission_prompt": return .approval
            case "elicitation_dialog", "elicitation_url_dialog": return .input
            default: return nil
            }
        default: return nil
        }
    }
}

private struct HookEventCache {
    let directory: URL
    let warning: @Sendable (String) -> Void

    private struct Entry: Codable {
        let id: String
        let time: TimeInterval
    }

    func claim(key: String, id: String, at date: Date) throws -> Bool {
        try edit { entries in
            let time = date.timeIntervalSince1970
            entries = entries.filter { time - $0.value.time < 15 && time >= $0.value.time }
            let digest = StableIdentity.digest(key)
            if entries[digest] != nil { return false }
            if entries.count >= 256, let oldest = entries.min(by: { $0.value.time < $1.value.time })?.key {
                entries.removeValue(forKey: oldest)
            }
            entries[digest] = Entry(id: id, time: time)
            return true
        }
    }

    func release(key: String, id: String) throws {
        _ = try edit { entries in
            let digest = StableIdentity.digest(key)
            if entries[digest]?.id == id { entries.removeValue(forKey: digest) }
            return true
        }
    }

    private func edit(_ change: (inout [String: Entry]) -> Bool) throws -> Bool {
        let files = FileManager.default
        // Inspect the supplied path without Foundation filesystem alias rewriting.
        var cursor = directory.path
        while !cursor.isEmpty && cursor != "/" {
            var info = stat()
            if lstat(cursor, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw HookError("Unsafe hook cache; deduplication unavailable.")
            }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw HookError("Unsafe hook cache; deduplication unavailable.")
        }
        let lock = directory.appendingPathComponent("events.lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw HookError("Cannot lock hook cache; deduplication unavailable.") }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw HookError("Hook cache is busy or unsafe; deduplication unavailable.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let dataURL = directory.appendingPathComponent("events.json")
        var entries: [String: Entry] = [:]
        let input = open(dataURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if input >= 0 {
            defer { close(input) }
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
                  info.st_size <= 131_072 else { throw HookError("Unsafe hook cache; deduplication unavailable.") }
            let data = try FileHandle(fileDescriptor: input, closeOnDealloc: false).read(upToCount: 131_073) ?? Data()
            guard data.count <= 131_072 else { throw HookError("Hook cache is too large; deduplication unavailable.") }
            if let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
                entries = saved
            } else {
                warning("Invalid hook cache was reset.")
            }
        } else if errno != ENOENT {
            throw HookError("Cannot read hook cache; deduplication unavailable.")
        }
        guard change(&entries) else { return false }
        try JSONEncoder().encode(entries).write(to: dataURL, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dataURL.path)
        return true
    }
}
