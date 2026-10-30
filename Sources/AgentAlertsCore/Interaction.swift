import Foundation

public struct InteractionStatusResponse: Decodable, Sendable {
    public let ok: Bool
    public let interaction: InteractionState
}

public struct InteractionState: Decodable, Sendable {
    public let interactionID: String
    public let status: String
    public let kind: String
    public let responseValue: String?
    public let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case status, kind
        case interactionID = "interaction_id"
        case responseValue = "response_value"
        case expiresAt = "expires_at"
    }
}
