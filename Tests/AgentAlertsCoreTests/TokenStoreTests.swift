import Darwin
import Foundation
import Testing
@testable import AgentAlertsCore

@Suite struct TokenStoreTests {
    private let token = "rk_agent_" + String(repeating: "A", count: 43)

    private func temporaryHome() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func saveUsesPrivateAtomicFileAndReadsIt() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        #expect(try store.read() == token)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.deletingLastPathComponent().path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        let contents = try FileManager.default.contentsOfDirectory(atPath: store.fileURL.deletingLastPathComponent().path)
        #expect(contents == ["token.env"])
    }

    @Test func environmentThenFileThenCompatibilityAlias() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let other = "rk_agent_" + String(repeating: "B", count: 43)
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        #expect(try TokenStore(home: home, environment: ["AGENTALERTS_AGENT_TOKEN": other]).read() == other)
        #expect(try TokenStore(home: home, environment: ["REPORTKIT_AGENT_TOKEN": other]).read() == token)
        try FileManager.default.removeItem(at: store.fileURL)
        #expect(try TokenStore(home: home, environment: ["REPORTKIT_AGENT_TOKEN": other]).read() == other)
    }

    @Test func savingDoesNotConcealEnvironmentOverride() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let exported = "rk_agent_" + String(repeating: "B", count: 43)
        let store = TokenStore(home: home, environment: ["AGENTALERTS_AGENT_TOKEN": exported])
        try store.save(token)
        #expect(store.environmentOverridesFile)
        #expect(try store.read() == exported)
        let message = try SetupInstructions().savedTokenMessage(using: store)
        #expect(message.hasPrefix("Token saved."))
        #expect(message.contains("AGENTALERTS_AGENT_TOKEN still overrides"))
        #expect(!message.contains(token) && !message.contains(exported))
        #expect(!message.hasPrefix("Connected"))
    }

    @Test(arguments: [nil, "", " \n\t "] as [String?])
    func absentOrBlankEnvironmentDoesNotWarn(value: String?) throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        var environment: [String: String] = [:]
        environment["AGENTALERTS_AGENT_TOKEN"] = value
        // The compatibility alias follows the token file and must not trigger this warning.
        environment["REPORTKIT_AGENT_TOKEN"] = "rk_agent_" + String(repeating: "B", count: 43)
        let store = TokenStore(home: home, environment: environment)
        try store.save(token)
        #expect(!store.environmentOverridesFile)
        #expect(try store.read() == token)
        let message = try SetupInstructions().savedTokenMessage(using: store)
        #expect(message.hasPrefix("Token saved."))
        #expect(!message.contains("overrides"))
        #expect(!message.contains(token))
    }

    @Test func neverEvaluatesShellSyntax() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        try Data("AGENTALERTS_AGENT_TOKEN=$(touch SHOULD_NOT_EXIST)\n".utf8).write(to: store.fileURL)
        #expect(throws: AppError.self) { try store.read() }
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("SHOULD_NOT_EXIST").path))
    }

    @Test func rejectsLoosePermissionsAndDoesNotSilentlyUseAlias() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: ["REPORTKIT_AGENT_TOKEN": token])
        try store.save(token)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path)
        #expect(throws: AppError.self) { try store.read() }
        #expect(throws: AppError.self) { try store.save(token) }
    }

    @Test func rejectsSymlinkOnReadAndWrite() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        let target = home.appendingPathComponent("other-token.env")
        try FileManager.default.moveItem(at: store.fileURL, to: target)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        #expect(throws: AppError.self) { try store.read() }
        #expect(throws: AppError.self) { try store.save(token) }
        #expect(try String(contentsOf: target, encoding: .utf8) == "AGENTALERTS_AGENT_TOKEN=\(token)\n")
    }

    @Test func rejectsFIFOWithoutBlocking() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        try FileManager.default.removeItem(at: store.fileURL)
        #expect(mkfifo(store.fileURL.path, 0o600) == 0)
        #expect(throws: AppError.self) { try store.read() }
    }

    @Test func rejectsDuplicateOrOversizedEntries() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = TokenStore(home: home, environment: [:])
        try store.save(token)
        for source in ["AGENTALERTS_AGENT_TOKEN=\(token)\nAGENTALERTS_AGENT_TOKEN=\(token)\n", String(repeating: "#", count: 4097)] {
            try Data(source.utf8).write(to: store.fileURL)
            #expect(throws: AppError.self) { try store.read() }
        }
    }

    @Test func honorsXDGDirectoryAndQuotedFileWithoutSourcing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let xdg = home.appendingPathComponent("custom")
        let store = TokenStore(home: home, environment: ["XDG_CONFIG_HOME": xdg.path])
        try store.save(token)
        #expect(store.fileURL.path == xdg.appendingPathComponent("agent-alerts/token.env").path)
        try Data("# Local token\nAGENTALERTS_AGENT_TOKEN='\(token)'\n".utf8).write(to: store.fileURL)
        #expect(try store.read() == token)
    }

    @Test func validationDoesNotIncludeTokenInError() {
        let secret = "rk_agent_sensitive_invalid_value!"
        do {
            _ = try TokenStore.validate(secret)
            Issue.record("Invalid token accepted")
        } catch {
            #expect(!error.localizedDescription.contains(secret))
        }
    }
}
