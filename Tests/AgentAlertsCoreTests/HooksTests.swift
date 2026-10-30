import Foundation
import Testing
@testable import AgentAlertsCore

struct HooksTests {
    @Test func phoneApprovalsWaitOnlyOnPermissionRequestsAndRemainIdempotent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = installer(root)
        let result = try configured.install(target: .codex, approvals: .phone)
        #expect(result[0].approvals == .phone)
        let file = root.appendingPathComponent(".codex/hooks.json")
        let data = try Data(contentsOf: file)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: [[String: Any]]])
        for (name, groups) in hooks {
            let command = try #require((groups[0]["hooks"] as? [[String: Any]])?.first)
            #expect(command["timeout"] as? Int == (name == "PermissionRequest" ? 86_415 : 8))
            #expect((command["command"] as? String)?.contains("--approvals phone") == (name == "PermissionRequest"))
            #expect(command["async"] == nil)
        }
        #expect(try !configured.install(target: .codex, approvals: .phone)[0].changed)
        #expect(try Data(contentsOf: file) == data)
        #expect(try configured.status().first?.approvals == .phone)
        #expect(try configured.install(target: .codex, approvals: .local)[0].approvals == .local)
        #expect(try configured.uninstall(target: .codex)[0].changed)
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("agent-alerts-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func installer(_ root: URL, executable: String = "/opt/homebrew/bin/agentalerts") -> HookInstaller {
        HookInstaller(home: root, environment: ["PATH": ""], executable: executable)
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: object).write(to: url)
    }

    @Test func explicitInstallCreatesAbsentAgentAndIsIdempotent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try installer(root).install(target: .codex)
        #expect(first.count == 1)
        #expect(first[0].installed)
        #expect(first[0].changed)
        #expect(first[0].idleSeconds == 300)
        let file = root.appendingPathComponent(".codex/hooks.json")
        let before = try Data(contentsOf: file)
        let second = try installer(root).install(target: .codex)
        #expect(!second[0].changed)
        #expect(try Data(contentsOf: file) == before)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func allSkipsAbsentAgents() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try installer(root).install()
        #expect(status.count == 2)
        #expect(status.allSatisfy { !$0.present && !$0.installed && !$0.changed })
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
    }

    @Test func preservesUnrelatedSettingsAndMixedHandlersOnUninstall() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude/settings.json")
        let original: [String: Any] = [
            "theme": "dark",
            "permissions": ["allow": ["Bash(git status)"]],
            "hooks": [
                "Stop": [["hooks": [["type": "command", "command": "echo other"]]]],
                "SessionStart": [],
            ],
        ]
        try write(original, to: file)
        let result = try installer(root).install(target: .claude, idleSeconds: 0)
        #expect(result[0].installed)
        #expect(result[0].idleSeconds == 0)
        let removed = try installer(root).uninstall(target: .claude)
        #expect(removed[0].changed)
        #expect(!removed[0].installed)
        let output = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(NSDictionary(dictionary: original).isEqual(to: output))
        let before = try Data(contentsOf: file)
        #expect(try !installer(root).uninstall(target: .claude)[0].changed)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func updatesOnlyManagedInvocationsAcrossBinaryPaths() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installer(root).install(target: .codex)
        let updated = try installer(root, executable: "/Users/test/my tools/agentalerts").install(target: .codex, idleSeconds: 0)
        #expect(updated[0].installed)
        #expect(updated[0].changed)
        #expect(updated[0].idleSeconds == 0)
        let data = try Data(contentsOf: root.appendingPathComponent(".codex/hooks.json"))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("/opt/homebrew/bin"))
        #expect(try installer(root).uninstall(target: .codex)[0].changed)
    }

    @Test func executableWithQuoteRemainsManaged() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let configured = installer(root, executable: "/Users/test/Andrea's Tools/agentalerts")
        #expect(try configured.install(target: .claude)[0].installed)
        #expect(try !configured.install(target: .claude)[0].changed)
        #expect(try configured.uninstall(target: .claude)[0].changed)
    }

    @Test func honorsConfigDirectoryOverrides() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent("custom-codex")
        let claude = root.appendingPathComponent("custom-claude")
        let custom = HookInstaller(home: root, environment: ["PATH": "", "CODEX_HOME": codex.path, "CLAUDE_CONFIG_DIR": claude.path], executable: "/tmp/agentalerts")
        _ = try custom.install(target: .codex)
        _ = try custom.install(target: .claude)
        #expect(FileManager.default.fileExists(atPath: codex.appendingPathComponent("hooks.json").path))
        #expect(FileManager.default.fileExists(atPath: claude.appendingPathComponent("settings.json").path))
        #expect(try custom.status().allSatisfy(\.installed))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
    }

    @Test func malformedConfigurationIsNeverOverwritten() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        for bad in ["{", "[]", "{\"hooks\":null}", "{\"hooks\":{\"Stop\":\"bad\"}}", "{\"hooks\":{\"Stop\":[{}]}}"] {
            let data = Data(bad.utf8)
            try data.write(to: file)
            #expect(throws: (any Error).self) { try installer(root).install(target: .codex) }
            #expect(try Data(contentsOf: file) == data)
            #expect(throws: (any Error).self) { try installer(root).uninstall(target: .codex) }
        }
    }

    @Test func allValidatesBeforeWriting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bad".utf8).write(to: file)
        #expect(throws: (any Error).self) { try installer(root).install() }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/hooks.json").path))
    }

    @Test func rejectsSymlinkedConfigAndParent() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("outside.json")
        try Data("{}".utf8).write(to: outside)
        let file = root.appendingPathComponent(".codex/hooks.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try installer(root).install(target: .codex) }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "{}")
        let custom = HookInstaller(home: root, environment: ["PATH": "", "CLAUDE_CONFIG_DIR": root.appendingPathComponent("link").path], executable: "/tmp/agentalerts")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link"), withDestinationURL: root.appendingPathComponent(".codex"))
        #expect(throws: (any Error).self) { try custom.install(target: .claude) }
    }

    @Test func preservesLookalikeCommandsAndEmptyUnrelatedHooks() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent(".codex/hooks.json")
        let original: [String: Any] = ["hooks": [
            "Stop": [["hooks": [["type": "command", "command": "echo '_hook codex --idle-seconds 300 # agent-alerts-managed-v1'"]]]],
            "SessionStart": [],
        ]]
        try write(original, to: file)
        #expect(try !installer(root).uninstall(target: .codex)[0].changed)
        _ = try installer(root).install(target: .codex)
        _ = try installer(root).uninstall(target: .codex)
        let output = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(NSDictionary(dictionary: original).isEqual(to: output))
    }

    @Test func negativeIdleIsRejectedBeforeWriting() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try installer(root).install(target: .codex, idleSeconds: -1) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex").path))
    }

    @Test func installsModeAndExitPlanHooksForBothAgents() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installer(root).install(target: .codex)
        _ = try installer(root).install(target: .claude)
        let codexRoot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".codex/hooks.json"))) as? [String: Any])
        let claudeRoot = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent(".claude/settings.json"))) as? [String: Any])
        let codexHooks = try #require(codexRoot["hooks"] as? [String: Any])
        let claudeHooks = try #require(claudeRoot["hooks"] as? [String: Any])
        #expect(codexHooks["UserPromptSubmit"] != nil)
        #expect(claudeHooks["UserPromptSubmit"] != nil)
        let preToolUse = try #require(claudeHooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolUse.first?["matcher"] as? String == "^(AskUserQuestion|ExitPlanMode)$")
    }
}
