import Darwin
import Foundation

public struct HookHandler: Sendable {
    private let environment: [String: String]
    private let home: URL
    private let now: @Sendable () -> Date
    private let warning: @Sendable (String) -> Void

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        warning: @escaping @Sendable (String) -> Void = {
            try? FileHandle.standardError.write(contentsOf: Data(("Agent Alerts hook: " + $0 + "\n").utf8))
        }
    ) {
        self.environment = environment
        self.home = home
        self.now = now
        self.warning = warning
    }

    public func handle(
        agent: HookAgent,
        input: Data,
        send: @Sendable (AlertRequest) async throws -> Void
    ) async throws {
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
        let time = now()
        let sessionDigest = StableIdentity.digest(agent.rawValue + "\n" + session)
        let progress = HookEventCache(directory: cacheDirectory, warning: warning, name: "progress")
        let claim = UUID().uuidString
        let startsWork = kind == .planning || kind == .working
        if !startsWork && kind != .sessionEnd {
            do { if try progress.hasEnded(key: sessionDigest) { return } }
            catch { warning("Session state unavailable; existing attention delivery policy is unchanged.") }
        }
        if kind.isProgress {
            do {
                guard try progress.claimProgress(key: sessionDigest, phase: kind.rawValue, id: claim, at: time) else { return }
            } catch {
                // Optional tool updates must not become a flood if rate limiting is unavailable.
                warning("Progress rate limit unavailable; quiet tool update skipped.")
                return
            }
        }
        if kind == .sessionEnd {
            // Block later tool events even when cleanup cannot reach the service.
            do { try progress.endProgress(key: sessionDigest, at: time) }
            catch { warning("Could not record session end; cleanup will still be attempted.") }
        }
        let isAttention = kind == .approval || kind == .input || kind == .planReady
        // Only source-provided request identities can prove two events are duplicates.
        // Uncorrelated attention events must each be delivered, even close together.
        let requestID = [event["request_id"], event["tool_use_id"]]
            .compactMap { $0 as? String }
            .first { !$0.isEmpty && $0.utf8.count <= 1024 }
        let identity = isAttention ? requestID.map { sessionDigest + "\n" + kind.rawValue + "\n" + $0 } : nil
        let idempotency = identity.map { "hook-" + StableIdentity.digest($0) } ?? UUID().uuidString
        let cache = HookEventCache(directory: cacheDirectory, warning: warning)
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
                event: kind == .sessionEnd ? .end : .update,
                updateExistingOnly: kind.isProgress,
                dismissImmediately: kind == .sessionEnd,
                sourceName: agent.displayName, notify: kind.notify, idempotencyKey: idempotency, now: time
            )
            try await send(request)
            if kind.isProgress {
                do { try progress.recordProgressSent(key: sessionDigest, phase: kind.rawValue, id: claim) }
                catch { warning("Could not record progress receipt; subsequent updates remain rate limited.") }
            }
            if startsWork {
                // A new prompt may deliberately resume a previously closed session.
                do { try progress.resumeProgress(key: sessionDigest, at: time) }
                catch { warning("Could not reset progress state; optional tool updates may be skipped.") }
            }
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
        case sessionEnd
        case reading
        case editing
        case commands
        case delegated

        var isProgress: Bool { self == .reading || self == .editing || self == .commands || self == .delegated }

        var status: AlertStatus {
            switch self {
            case .planning, .working, .planUpdate, .completion, .sessionEnd, .reading, .editing, .commands, .delegated: .good
            case .planReady, .approval, .input: .warning
            case .failure: .critical
            }
        }

        var notify: Bool { self != .planning && self != .working && self != .sessionEnd && !isProgress }

        func title(agent: HookAgent) -> String {
            switch self {
            case .planning: "\(agent.displayName) planning"
            case .working: "\(agent.displayName) working"
            case .planReady: "\(agent.displayName) plan ready"
            case .planUpdate: "\(agent.displayName) plan updated"
            case .completion: "\(agent.displayName) turn finished"
            case .approval: "\(agent.displayName) needs approval"
            case .input: "\(agent.displayName) needs your input"
            case .failure: "\(agent.displayName) stopped with an error"
            case .sessionEnd: "\(agent.displayName) session closed"
            case .reading: "\(agent.displayName) inspecting files"
            case .editing: "\(agent.displayName) editing files"
            case .commands: "\(agent.displayName) command step"
            case .delegated: "\(agent.displayName) delegated work"
            }
        }
    }

    private func kind(for agent: HookAgent, event: [String: Any]) -> Kind? {
        let isPlanning = event["permission_mode"] as? String == "plan"
        switch event["hook_event_name"] as? String {
        case "UserPromptSubmit": return isPlanning ? .planning : .working
        case "Stop": return isPlanning ? .planUpdate : .completion
        case "SessionEnd": return .sessionEnd
        case "SubagentStart": return .delegated
        case "PostToolUse":
            // Only a fixed tool-name allowlist influences copy. Never read inputs,
            // outputs, transcript paths, command text, or arbitrary tool names.
            switch event["tool_name"] as? String {
            case "Read", "Glob", "Grep", "read_file", "list_dir", "grep_files": return .reading
            case "Edit", "Write", "MultiEdit", "apply_patch": return .editing
            case "Bash", "exec_command", "shell", "shell_command": return .commands
            default: return nil
            }
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
    var name: String = "events"

    private struct Entry: Codable {
        let id: String
        let time: TimeInterval
        var phase: String? = nil
        var endedAt: TimeInterval? = nil
    }

    func claimProgress(key: String, phase: String, id: String, at date: Date) throws -> Bool {
        try edit { entries in
            let time = date.timeIntervalSince1970
            entries = entries.filter { time - max($0.value.time, $0.value.endedAt ?? 0) < 86_400 }
            let digest = StableIdentity.digest(key)
            if let previous = entries[digest] {
                guard previous.endedAt == nil, previous.phase != phase, time - previous.time >= 60 else { return false }
            }
            if entries.count >= 256, let oldest = entries.min(by: { $0.value.time < $1.value.time })?.key {
                entries.removeValue(forKey: oldest)
            }
            // Reserve the interval before networking. Only an accepted send commits
            // its stage; an uncertain attempt still consumes this interval.
            entries[digest] = Entry(id: id, time: time, phase: entries[digest]?.phase)
            return true
        }
    }

    func endProgress(key: String, at date: Date) throws {
        _ = try edit { entries in
            let time = date.timeIntervalSince1970
            entries = entries.filter { time - max($0.value.time, $0.value.endedAt ?? 0) < 86_400 }
            if entries.count >= 256, let oldest = entries.min(by: { $0.value.time < $1.value.time })?.key {
                entries.removeValue(forKey: oldest)
            }
            let digest = StableIdentity.digest(key)
            var entry = entries[digest] ?? Entry(id: UUID().uuidString, time: time - 60)
            entry.endedAt = time
            entries[digest] = entry
            return true
        }
    }

    func hasEnded(key: String) throws -> Bool {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path) else { return false }
        var ended = false
        _ = try edit { entries in
            ended = entries[StableIdentity.digest(key)]?.endedAt != nil
            return false
        }
        return ended
    }

    func resumeProgress(key: String, at date: Date) throws {
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".json").path) else { return }
        _ = try edit { entries in
            let digest = StableIdentity.digest(key)
            guard var entry = entries[digest], let endedAt = entry.endedAt,
                  endedAt < date.timeIntervalSince1970 else { return false }
            entry.endedAt = nil
            entries[digest] = entry
            return true
        }
    }

    func recordProgressSent(key: String, phase: String, id: String) throws {
        _ = try edit { entries in
            let digest = StableIdentity.digest(key)
            guard var entry = entries[digest], entry.id == id, entry.endedAt == nil else { return false }
            entry.phase = phase
            entries[digest] = entry
            return true
        }
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
        let lock = directory.appendingPathComponent(name + ".lock")
        let descriptor = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw HookError("Cannot lock hook cache; deduplication unavailable.") }
        defer { close(descriptor) }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw HookError("Hook cache is busy or unsafe; deduplication unavailable.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let dataURL = directory.appendingPathComponent(name + ".json")
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
