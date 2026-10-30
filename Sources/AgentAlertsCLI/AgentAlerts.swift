import AgentAlertsCore
import ArgumentParser
import Darwin
import Foundation

@main
enum Main {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == "_hook" {
            await runHook(Array(CommandLine.arguments.dropFirst(2)))
        } else {
            // Reject misplaced credentials before the parser can echo an unexpected argument.
            if CommandLine.arguments.dropFirst().contains(where: { $0.contains("rk_agent_") }) {
                AgentAlerts.exit(withError: ValidationError("Tokens cannot be passed as arguments. Use agentalerts setup or AGENTALERTS_AGENT_TOKEN."))
            }
            await AgentAlerts.main()
        }
    }

    // Passive hooks are neutral. Phone approvals return only the user's one-request decision.
    private static func runHook(_ arguments: [String]) async {
        do {
            if let decision = try await runHookArguments(arguments) {
                try printJSON(PermissionHookOutput(decision: decision))
            } else {
                print("{}")
            }
        } catch {
            Terminal.error("Agent Alerts hook: \(safeMessage(error))")
            print("{}")
        }
    }

    private static func runHookArguments(_ arguments: [String]) async throws -> ApprovalDecision? {
        guard arguments.count == 3 || arguments.count == 5, let agent = HookAgent(rawValue: arguments[0]),
              arguments[1] == "--idle-seconds", let seconds = Int(arguments[2]), seconds >= 0 else {
            throw AppError("Invalid hook invocation. Reinstall with agentalerts hooks install.")
        }
        let phoneApprovals = arguments.count == 5
        if phoneApprovals && (arguments[3] != "--approvals" || arguments[4] != "phone") {
            throw AppError("Invalid hook invocation. Reinstall with agentalerts hooks install.")
        }
        let input = try FileHandle.standardInput.read(upToCount: 1_048_577) ?? Data()
        guard input.count <= 1_048_576 else { throw AppError("Hook event is too large; alert skipped.") }
        let client = AgentAlertsClient()
        if phoneApprovals {
            let token = try TokenStore().read()
            let decision = try await ApprovalCoordinator().request(
                agent: agent, input: input,
                send: { try await client.send($0, token: token) },
                status: { try await client.interactionStatus(id: $0, token: token) }
            )
            if decision == nil {
                Terminal.error("Agent Alerts hook: Waiting for approval in the agent's native UI.")
                try await HookHandler().handle(agent: agent, input: input, idleSeconds: 0) { request in
                    let acknowledgement = try await client.send(request, token: token)
                    guard acknowledgement.accepted else { throw AppError(acknowledgement.description) }
                }
            }
            return decision
        }
        try await HookHandler().handle(agent: agent, input: input, idleSeconds: seconds) { request in
            let acknowledgement = try await client.send(request, token: TokenStore().read())
            guard acknowledgement.accepted else { throw AppError(acknowledgement.description) }
        }
        return nil
    }
}

struct AgentAlerts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentalerts",
        abstract: "Send Agent Alerts to your iPhone.",
        version: "0.1.0",
        subcommands: [Setup.self, Send.self, Hooks.self]
    )
}

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Connect your iPhone and save its approved token.")

    @Option(help: "Name shown when approving this connection.")
    var name = "My Mac"

    @Option(help: "Connection access: publish, or interactive for phone replies (includes alarm access in the current setup flow).")
    var access: SetupAccess = .publish

    @Flag(help: "Print the setup URL as JSON without opening a browser or prompting.")
    var json = false

    func run() throws {
        let instructions = try SetupInstructions(name: name, access: access)
        if json {
            try printJSON(instructions)
            return
        }
        print("Approve this connection with Agent Alerts on iPhone:")
        print(instructions.setupURL.absoluteString)
        guard isatty(STDIN_FILENO) == 1 else {
            print("Run agentalerts setup in a terminal to save the one-time token, or set AGENTALERTS_AGENT_TOKEN in your secret environment.")
            return
        }
        let browser = Process()
        browser.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        browser.arguments = [instructions.setupURL.absoluteString]
        browser.standardOutput = FileHandle.nullDevice
        browser.standardError = FileHandle.nullDevice
        do {
            try browser.run()
            browser.waitUntilExit()
            if browser.terminationStatus != 0 { print("Open the URL above in your browser.") }
        } catch {
            print("Open the URL above in your browser.")
        }
        let token = try Terminal.readSecret(prompt: "Paste the one-time token (hidden): ")
        let store = TokenStore()
        try store.save(token)
        print(instructions.savedTokenMessage(using: store))
    }
}

extension AlertEvent: ExpressibleByArgument {}
extension AlertStatus: ExpressibleByArgument {}
extension HookTarget: ExpressibleByArgument {}
extension HookApprovalMode: ExpressibleByArgument {}
extension SetupAccess: ExpressibleByArgument {}

struct Send: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Send a Live Activity and notification.")

    @Argument(help: "A short headline, up to 32 characters.")
    var title: String

    @Option(help: "Additional detail, up to 96 characters. Defaults to the headline.")
    var summary: String?

    @Option(name: .customLong("activity-id"), help: "Reuse an activity ID. Defaults to this working directory.")
    var activityID: String?

    @Option(help: "Alert status: good, warning, or critical.")
    var status: AlertStatus = .good

    @Option(help: "Activity event: start, update, or end. Updates start an activity if needed.")
    var event: AlertEvent = .update

    @Flag(help: "Print the service acknowledgement as JSON.")
    var json = false

    func run() async throws {
        let request = try AlertRequest(
            title: title, summary: summary,
            activityID: activityID ?? StableIdentity.manualActivityID(directory: FileManager.default.currentDirectoryPath),
            status: status, event: event
        )
        let response = try await AgentAlertsClient().send(request, token: TokenStore().read())
        if json { try printJSON(response) } else { print(response.description) }
        if !response.accepted { throw ExitCode.failure }
    }
}

struct Hooks: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install automatic Codex and Claude alerts.",
        subcommands: [Install.self, Status.self, Uninstall.self]
    )

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install hooks for detected agents.")

        @Argument(help: "Agent to configure: codex, claude, or all.")
        var target: HookTarget = .all

        @Option(help: "Skip alerts while active. Seconds of idle time required; 0 always sends.")
        var idleSeconds = 300

        @Option(help: "Handle approvals locally, or wait for a phone reply. Phone mode sends the pending action details.")
        var approvals: HookApprovalMode = .local

        func validate() throws {
            guard idleSeconds >= 0 else { throw ValidationError("--idle-seconds must be a non-negative integer.") }
        }

        func run() throws {
            let results = try installer().install(target: target, idleSeconds: idleSeconds, approvals: approvals)
            for result in results {
                if result.installed {
                    print("\(result.agent.rawValue): \(result.changed ? "installed" : "already configured") · idle \(result.idleSeconds ?? idleSeconds)s · approvals \(result.approvals.rawValue)")
                } else {
                    print("\(result.agent.rawValue): not detected; skipped")
                }
            }
            if approvals == .phone {
                print("Phone approvals send action details and wait for a reply for up to 24 hours. Run agentalerts setup --access interactive if your connection cannot read replies.")
            }
            if results.contains(where: { $0.agent == .codex && $0.installed }) {
                print("In Codex, open /hooks to review and trust the Agent Alerts hooks.")
            }
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show agent hooks and snoozing settings.")

        func run() throws {
            for result in try installer().status() {
                let state = result.installed ? "installed" : (result.present ? "not installed" : "not detected")
                let idle = result.idleSeconds.map { " · idle \($0)s" } ?? ""
                print("\(result.agent.rawValue): \(state)\(idle) · approvals \(result.approvals.rawValue)\n  \(result.configPath)")
            }
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove only Agent Alerts hooks.")

        @Argument(help: "Agent to remove hooks from: codex, claude, or all.")
        var target: HookTarget = .all

        func run() throws {
            for result in try installer().uninstall(target: target) {
                print("\(result.agent.rawValue): \(result.changed ? "removed" : "no Agent Alerts hooks")")
            }
        }
    }
}

private func installer() throws -> HookInstaller {
    HookInstaller(executable: try executablePath())
}

private func executablePath() throws -> String {
    let argument = CommandLine.arguments[0]
    let path: String
    if argument.contains("/") {
        path = URL(fileURLWithPath: argument).standardizedFileURL.path
    } else {
        let directories = ProcessInfo.processInfo.environment["PATH", default: ""].split(separator: ":")
        guard let match = directories.map({ URL(fileURLWithPath: String($0)).appendingPathComponent(argument).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw AppError("Could not locate agentalerts. Run it using its installed path.")
        }
        path = match
    }
    // Homebrew's opt symlink remains stable across versioned Cellar upgrades.
    if let range = path.range(of: "/Cellar/agentalerts/") {
        let stable = String(path[..<range.lowerBound]) + "/opt/agentalerts/bin/agentalerts"
        if FileManager.default.isExecutableFile(atPath: stable) { return stable }
    }
    return path
}

private func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

private func safeMessage(_ error: Error) -> String {
    (error as? AppError)?.message ?? "Could not process the event; alert skipped."
}

private enum Terminal {
    static func error(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }

    static func readSecret(prompt: String) throws -> String {
        // readpassphrase restores terminal echo even when interrupted by a signal.
        var buffer = [CChar](repeating: 0, count: 258)
        guard let value = readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY) else {
            throw AppError("Token entry cancelled. Run agentalerts setup to try again.")
        }
        defer { buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        return String(cString: value)
    }
}
