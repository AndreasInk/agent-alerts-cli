import Foundation

public enum SetupAccess: String, Sendable {
    case publish
    case interactive
}

public struct SetupInstructions: Encodable, Sendable {
    public let setupURL: URL
    public let tokenEnvironmentVariable = "AGENTALERTS_AGENT_TOKEN"
    public let message = "Open the setup page, approve the QR on iPhone, then save the one-time token with agentalerts setup."

    enum CodingKeys: String, CodingKey {
        case setupURL = "setup_url"
        case tokenEnvironmentVariable = "token_environment_variable"
        case message
    }

    public init(name: String = "My Mac", access: SetupAccess = .publish) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.unicodeScalars.count <= 80,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError("Connection name must be 1–80 characters without control characters.")
        }
        var components = URLComponents(string: "https://www.andreas.ink/agent")!
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        if access == .interactive {
            components.queryItems?.append(URLQueryItem(name: "access", value: "interactive"))
        }
        setupURL = components.url!
    }

    public func savedTokenMessage(using store: TokenStore) -> String {
        if store.environmentOverridesFile {
            return "Token saved. AGENTALERTS_AGENT_TOKEN still overrides the saved token. Unset it to use this token."
        }
        return "Token saved. Try agentalerts send \"Connected\", then agentalerts hooks install."
    }
}
