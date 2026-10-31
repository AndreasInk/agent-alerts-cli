import Darwin
import Foundation

public enum HookAgent: String, CaseIterable, Sendable {
    case codex
    case claude

    public var displayName: String { self == .codex ? "Codex" : "Claude" }
}

public enum HookTarget: String, CaseIterable, Sendable {
    case codex
    case claude
    case all

    var agents: [HookAgent] {
        self == .all ? HookAgent.allCases : [HookAgent(rawValue: rawValue)!]
    }
}

public enum HookApprovalMode: String, CaseIterable, Sendable {
    case local
    case phone
}

public struct HookInstallationStatus: Sendable {
    public let agent: HookAgent
    public let present: Bool
    public let installed: Bool
    public let configPath: String
    public let changed: Bool
    public let approvals: HookApprovalMode
}

typealias HookError = AppError

public struct HookInstaller {
    private let home: URL
    private let environment: [String: String]
    private let executable: String
    private let files = FileManager.default

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executable: String
    ) {
        self.home = home
        self.environment = environment
        self.executable = executable
    }

    public func install(target: HookTarget = .all, approvals: HookApprovalMode = .local) throws -> [HookInstallationStatus] {
        guard executable.hasPrefix("/"), !executable.contains("\n"), !executable.contains("\r") else {
            throw HookError("The hook executable must be an absolute path without newlines.")
        }
        // Read and validate every selected file before writing any of them.
        let configurations = try target.agents.map { agent -> (HookAgent, URL, [String: Any], Data?) in
            let url = configURL(agent)
            let (root, original) = try readConfiguration(url)
            return (agent, url, root, original)
        }
        return try configurations.map { agent, url, root, original in
            let present = isPresent(agent, config: url)
            if target == .all && !present {
                return result(agent, present: false, root: root, path: url, changed: false)
            }
            var edited = removingManagedHooks(from: root, agent: agent)
            var hooks = edited["hooks"] as? [String: Any] ?? [:]
            for definition in definitions(for: agent) {
                let waitsForReply = definition.event == "PermissionRequest" && approvals == .phone
                var groups = hooks[definition.event] as? [[String: Any]] ?? []
                var group: [String: Any] = ["hooks": [[
                    "type": "command",
                    "command": command(for: agent, approvals: waitsForReply ? .phone : .local),
                    "timeout": waitsForReply ? 86_415 : 8,
                ]]]
                if let matcher = definition.matcher { group["matcher"] = matcher }
                groups.append(group)
                hooks[definition.event] = groups
            }
            edited["hooks"] = hooks
            let changed = !NSDictionary(dictionary: edited).isEqual(to: root)
            if changed { try writeConfiguration(edited, to: url, expected: original) }
            return result(agent, present: present, root: edited, path: url, changed: changed)
        }
    }

    public func uninstall(target: HookTarget = .all) throws -> [HookInstallationStatus] {
        let configurations = try target.agents.map { agent -> (HookAgent, URL, [String: Any], Data?) in
            let url = configURL(agent)
            let (root, original) = try readConfiguration(url)
            return (agent, url, root, original)
        }
        return try configurations.map { agent, url, root, original in
            let edited = removingManagedHooks(from: root, agent: agent)
            let changed = !NSDictionary(dictionary: edited).isEqual(to: root)
            if changed { try writeConfiguration(edited, to: url, expected: original) }
            return result(agent, present: isPresent(agent, config: url), root: edited, path: url, changed: changed)
        }
    }

    public func status() throws -> [HookInstallationStatus] {
        try HookAgent.allCases.map { agent in
            let url = configURL(agent)
            let (root, _) = try readConfiguration(url)
            return result(agent, present: isPresent(agent, config: url), root: root, path: url, changed: false)
        }
    }

    private func configURL(_ agent: HookAgent) -> URL {
        let key = agent == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let fallback = home.appendingPathComponent(agent == .codex ? ".codex" : ".claude")
        let directory = environment[key].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? fallback
        return directory.appendingPathComponent(agent == .codex ? "hooks.json" : "settings.json")
    }

    private func isPresent(_ agent: HookAgent, config: URL) -> Bool {
        if files.fileExists(atPath: config.path) || files.fileExists(atPath: config.deletingLastPathComponent().path) {
            return true
        }
        return (environment["PATH"] ?? "").split(separator: ":", omittingEmptySubsequences: false).contains { directory in
            let url = URL(fileURLWithPath: String(directory.isEmpty ? "." : directory))
                .appendingPathComponent(agent.rawValue)
            return files.isExecutableFile(atPath: url.path)
        }
    }

    private struct Definition {
        let event: String
        var matcher: String? = nil
    }

    private func definitions(for agent: HookAgent) -> [Definition] {
        if agent == .codex {
            return [Definition(event: "UserPromptSubmit"), Definition(event: "Stop"), Definition(event: "PermissionRequest")]
        }
        return [
            Definition(event: "UserPromptSubmit"),
            Definition(event: "Stop"),
            Definition(event: "StopFailure"),
            Definition(event: "PermissionRequest"),
            Definition(event: "PreToolUse", matcher: "^(AskUserQuestion|ExitPlanMode)$"),
            Definition(event: "Notification", matcher: "^(permission_prompt|elicitation_dialog|elicitation_url_dialog)$"),
        ]
    }

    private func command(for agent: HookAgent, approvals: HookApprovalMode) -> String {
        let quoted = "'" + executable.replacingOccurrences(of: "'", with: "'\\''") + "'"
        // The fallback makes a removed executable harmless to the parent agent.
        let approvalFlag = approvals == .phone ? " --approvals phone" : ""
        return "\(quoted) _hook \(agent.rawValue)\(approvalFlag) || printf '{}\\n' # agent-alerts-managed-v1"
    }

    private func managedOptions(_ handler: [String: Any], agent: HookAgent) -> HookApprovalMode? {
        guard handler["type"] as? String == "command", let command = handler["command"] as? String else { return nil }
        // Match the complete generated invocation, not a substring in someone else's hook.
        let pattern = "^'(?:[^']|'\\\\'')+' _hook " + agent.rawValue
            + "(?: --idle-seconds ([0-9]+))?( --approvals phone)? \\|\\| printf '\\{\\}\\\\n' # agent-alerts-managed-v1$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)) else { return nil }
        return match.range(at: 2).location == NSNotFound ? .local : .phone
    }

    private func removingManagedHooks(from root: [String: Any], agent: HookAgent) -> [String: Any] {
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        var edited = root
        var changed = false
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let retained = groups.compactMap { group -> [String: Any]? in
                guard let handlers = group["hooks"] as? [[String: Any]] else { return group }
                let remaining = handlers.filter { managedOptions($0, agent: agent) == nil }
                guard remaining.count != handlers.count else { return group }
                guard !remaining.isEmpty else { return nil }
                var updated = group
                updated["hooks"] = remaining
                return updated
            }
            guard !NSArray(array: retained).isEqual(to: groups) else { continue }
            changed = true
            if retained.isEmpty { hooks.removeValue(forKey: event) }
            else { hooks[event] = retained }
        }
        guard changed else { return root }
        if hooks.isEmpty { edited.removeValue(forKey: "hooks") }
        else { edited["hooks"] = hooks }
        return edited
    }

    private func result(
        _ agent: HookAgent, present: Bool, root: [String: Any], path: URL, changed: Bool
    ) -> HookInstallationStatus {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var matched = 0
        var approvals: HookApprovalMode = .local
        for definition in definitions(for: agent) {
            let groups = hooks[definition.event] as? [[String: Any]] ?? []
            var eventMatches = 0
            for group in groups where group["matcher"] as? String == definition.matcher {
                for handler in group["hooks"] as? [[String: Any]] ?? [] {
                    if let options = managedOptions(handler, agent: agent) {
                        eventMatches += 1
                        if definition.event == "PermissionRequest" { approvals = options }
                    }
                }
            }
            if eventMatches == 1 { matched += 1 }
        }
        return HookInstallationStatus(
            agent: agent, present: present,
            installed: matched == definitions(for: agent).count,
            configPath: path.path, changed: changed, approvals: approvals
        )
    }

    private func readConfiguration(_ url: URL) throws -> ([String: Any], Data?) {
        try checkPathForSymlinks(url)
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return ([:], nil) }
            throw HookError("Cannot read hook configuration at \(url.path).")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 2_097_152 else {
            throw HookError("Hook configuration must be a regular file owned by you, under 2 MiB: \(url.path).")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: 2_097_153) ?? Data()
        guard data.count <= 2_097_152 else { throw invalidConfig(url) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw HookError("Invalid JSON object at \(url.path). The file was left unchanged.")
        }
        if let raw = root["hooks"] {
            guard let hooks = raw as? [String: Any] else { throw invalidConfig(url) }
            for (_, value) in hooks {
                guard let groups = value as? [[String: Any]] else { throw invalidConfig(url) }
                for group in groups {
                    guard group["matcher"] == nil || group["matcher"] is String,
                          let handlers = group["hooks"] as? [[String: Any]] else { throw invalidConfig(url) }
                    for handler in handlers {
                        guard let type = handler["type"] as? String,
                              type != "command" || handler["command"] is String else { throw invalidConfig(url) }
                    }
                }
            }
        }
        return (root, data)
    }

    private func invalidConfig(_ url: URL) -> HookError {
        HookError("Invalid hook configuration at \(url.path). The file was left unchanged.")
    }

    private func checkPathForSymlinks(_ url: URL) throws {
        // URL.standardizedFileURL can rewrite an existing /private/tmp path to
        // the /tmp symlink on macOS. Inspect the exact configured path lexically.
        var cursor = url.path
        while !cursor.isEmpty && cursor != "/" {
            var info = stat()
            if lstat(cursor, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                throw HookError("Refusing to follow a symlink in hook configuration: \(url.path).")
            }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
    }

    private func writeConfiguration(_ root: [String: Any], to url: URL, expected: Data?) throws {
        try checkPathForSymlinks(url)
        let parent = url.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parentInfo = stat()
        guard lstat(parent.path, &parentInfo) == 0, parentInfo.st_mode & S_IFMT == S_IFDIR,
              parentInfo.st_uid == getuid(), parentInfo.st_mode & 0o022 == 0 else {
            throw HookError("Hook configuration directory must be owned by you and not writable by others: \(parent.path).")
        }
        let lockURL = parent.appendingPathComponent(".agent-alerts-hooks.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw HookError("Cannot lock hook configuration at \(url.path).") }
        defer { close(descriptor) }
        var lockInfo = stat()
        guard fstat(descriptor, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(), flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw HookError("Hook configuration is busy or unsafe at \(url.path). Try again.")
        }
        defer { flock(descriptor, LOCK_UN) }
        let (_, current) = try readConfiguration(url)
        guard current == expected else { throw HookError("Hook configuration changed during installation. Try again.") }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) + Data("\n".utf8)
        try data.write(to: url, options: [.atomic])
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
