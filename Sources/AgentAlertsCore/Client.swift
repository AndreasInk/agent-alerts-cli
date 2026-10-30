import Foundation

final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

public struct AgentAlertsClient: Sendable {
    public static let endpoint = URL(string: "https://www.andreas.ink/api/agent")!
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    // Tests inject a URLProtocol-backed session; the destination remains the public HTTPS endpoint.
    init(session: URLSession) {
        self.session = session
    }

    public func send(_ alert: AlertRequest, token: String) async throws -> SendResponse {
        try await request(body: JSONEncoder().encode(alert), token: token, idempotencyKey: alert.idempotencyKey)
    }

    public func interactionStatus(id: String, token: String) async throws -> InteractionStatusResponse {
        guard UUID(uuidString: id) != nil else { throw AppError("Invalid approval interaction ID.") }
        return try await request(
            body: JSONSerialization.data(withJSONObject: ["operation": "interaction_status", "interaction_id": id]),
            token: token
        )
    }

    private func request<Response: Decodable>(body: Data, token: String, idempotencyKey: String? = nil) async throws -> Response {
        let token = try TokenStore.validate(token)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("agentalerts/0.1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if (error as? URLError)?.code == .timedOut {
                throw AppError("Agent Alerts timed out. Delivery is unknown; the CLI did not retry.")
            }
            throw AppError("Could not reach Agent Alerts. Check your connection; the CLI did not retry.")
        }
        guard let response = response as? HTTPURLResponse else {
            throw AppError("Agent Alerts returned an invalid response.")
        }
        guard (200..<300).contains(response.statusCode) else {
            let advice: String
            switch response.statusCode {
            case 401:
                advice = " Run agentalerts setup to reconnect."
            case 403:
                let serviceError = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
                switch serviceError {
                case "pro_required":
                    advice = " Phone replies require Agent Alerts Pro or Founder Pro."
                case "Interact scope required":
                    advice = " Run agentalerts setup --access interactive to approve reply access."
                default:
                    advice = " This connection is not permitted to make this request. Check its permissions in Agent Alerts."
                }
            default:
                advice = " The CLI did not retry."
            }
            throw AppError("Agent Alerts rejected the request (HTTP \(response.statusCode)).\(advice)")
        }
        guard data.count <= 65_536, let acknowledgement = try? JSONDecoder().decode(Response.self, from: data) else {
            throw AppError("Agent Alerts returned an unreadable acknowledgement. Delivery is unknown; the CLI did not retry.")
        }
        return acknowledgement
    }
}
