import Darwin
import Foundation

public struct TokenStore: Sendable {
    public let fileURL: URL
    private let environment: [String: String]

    public init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.environment = environment
        let base = environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".config", isDirectory: true)
        fileURL = base.appendingPathComponent("agent-alerts/token.env")
    }

    public func read() throws -> String {
        if let token = nonempty(environment["AGENTALERTS_AGENT_TOKEN"]) {
            return try Self.validate(token)
        }
        if let token = try readFile() { return token }
        if let token = nonempty(environment["REPORTKIT_AGENT_TOKEN"]) {
            return try Self.validate(token)
        }
        throw AppError("No Agent Alerts token. Run agentalerts setup to connect your iPhone.")
    }

    public var environmentOverridesFile: Bool {
        nonempty(environment["AGENTALERTS_AGENT_TOKEN"]) != nil
    }

    public static func validate(_ raw: String) throws -> String {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard token.hasPrefix("rk_agent_"), (32...256).contains(token.utf8.count),
              token.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AppError("Invalid Agent Alerts token. Paste the complete one-time token from the setup page.")
        }
        return token
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    private func readFile() throws -> String? {
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor == -1 {
            if errno == ENOENT { return nil }
            throw AppError("Could not safely open the token file. Use a regular, current-user-owned mode-0600 file.")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_mode & 0o777 == 0o600,
              metadata.st_size <= 4096 else {
            throw AppError("Unsafe token file. It must be a regular, current-user-owned mode-0600 file of at most 4 KB.")
        }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let length = Darwin.read(descriptor, &buffer, buffer.count)
        guard length >= 0, length <= 4096,
              let source = String(bytes: buffer.prefix(length), encoding: .utf8) else {
            throw AppError("Could not read the token file.")
        }
        var values: [String] = []
        for rawLine in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces)
            guard name == "AGENTALERTS_AGENT_TOKEN" else { continue }
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") {
                value = String(value.dropFirst().dropLast())
            }
            values.append(value)
        }
        guard values.count == 1 else {
            throw AppError("The token file must contain exactly one AGENTALERTS_AGENT_TOKEN entry.")
        }
        return try Self.validate(values[0])
    }

    public func save(_ raw: String) throws {
        let token = try Self.validate(raw)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var directoryMetadata = stat()
        guard lstat(directory.path, &directoryMetadata) == 0,
              directoryMetadata.st_mode & S_IFMT == S_IFDIR,
              directoryMetadata.st_uid == getuid(), directoryMetadata.st_mode & 0o022 == 0 else {
            throw AppError("Unsafe token directory. Use a current-user-owned directory that others cannot modify.")
        }
        let directoryFD = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw AppError("Could not safely open the token directory.") }
        defer { close(directoryFD) }
        guard fchmod(directoryFD, 0o700) == 0 else { throw AppError("Could not secure the token directory.") }

        var existing = stat()
        if fstatat(directoryFD, "token.env", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_uid == getuid(),
                  existing.st_mode & 0o777 == 0o600 else {
                throw AppError("Refusing to replace an unsafe token file. It must be regular, current-user-owned, and mode 0600.")
            }
        } else if errno != ENOENT {
            throw AppError("Could not inspect the existing token file.")
        }

        let temporaryName = ".token-\(UUID().uuidString)"
        let descriptor = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AppError("Could not create a private token file.") }
        defer {
            close(descriptor)
            unlinkat(directoryFD, temporaryName, 0)
        }
        let data = Data("AGENTALERTS_AGENT_TOKEN=\(token)\n".utf8)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(descriptor, bytes.baseAddress, bytes.count)
        }
        guard written == data.count, fsync(descriptor) == 0,
              renameat(directoryFD, temporaryName, directoryFD, "token.env") == 0 else {
            throw AppError("Could not save the token securely.")
        }
    }
}
