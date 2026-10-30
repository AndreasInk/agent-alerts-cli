import Foundation
import Testing
@testable import AgentAlertsCore

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    // Only this serialized suite accesses the handler; URLSession reads it after assignment.
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (response, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct ClientTests {
    @Test func pollsThePublicEndpointWithTheSameOriginatingToken() async throws {
        let token = token
        let id = UUID().uuidString
        let session = session { request in
            #expect(request.url == AgentAlertsClient.endpoint)
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
            #expect(body == ["operation": "interaction_status", "interaction_id": id])
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"ok\":true,\"interaction\":{\"interaction_id\":\"\(id)\",\"status\":\"pending\",\"kind\":\"yes_no\",\"expires_at\":\"2099-01-01T00:00:00Z\"}}".utf8)
            )
        }
        defer { session.invalidateAndCancel() }
        let response = try await AgentAlertsClient(session: session).interactionStatus(id: id, token: token)
        #expect(response.interaction.interactionID == id)
        #expect(response.interaction.status == "pending")
    }

    private let token = "rk_agent_" + String(repeating: "T", count: 43)

    private func session(
        _ handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        StubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func sendsOnlyBearerToPublicEndpoint() async throws {
        let token = token
        let session = session { request in
            #expect(request.url?.absoluteString == "https://www.andreas.ink/api/agent")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "fixture-key")
            #expect(request.value(forHTTPHeaderField: "apikey") == nil)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("{\"ok\":true,\"status\":\"sent\",\"target_count\":1,\"success_count\":1,\"failure_count\":0}".utf8))
        }
        defer { session.invalidateAndCancel() }
        let response = try await AgentAlertsClient(session: session).send(
            AlertRequest(title: "Build finished", activityID: "test", idempotencyKey: "fixture-key"), token: token
        )
        #expect(response.accepted)
        #expect(response.successCount == 1)
    }

    @Test(arguments: [401, 403, 429, 500, 302])
    func httpErrorsNeverEchoResponseSecrets(status: Int) async throws {
        let token = token
        let session = session { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(token.utf8))
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AgentAlertsClient(session: session).send(AlertRequest(title: "Test", activityID: "test"), token: token)
            Issue.record("HTTP error accepted")
        } catch {
            #expect(error.localizedDescription.contains("HTTP \(status)"))
            #expect(!error.localizedDescription.contains(token))
            if status == 401 {
                #expect(error.localizedDescription.contains("setup to reconnect"))
            } else if status == 403 {
                #expect(error.localizedDescription.contains("Check its permissions"))
                #expect(!error.localizedDescription.contains("reconnect"))
            }
        }
    }

    @Test func timeoutReportsUnknownDeliveryWithoutRetrying() async throws {
        let session = session { _ in throw URLError(.timedOut) }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AgentAlertsClient(session: session).send(AlertRequest(title: "Test", activityID: "test"), token: token)
            Issue.record("Timeout accepted")
        } catch {
            #expect(error.localizedDescription.contains("Delivery is unknown"))
            #expect(error.localizedDescription.contains("did not retry"))
        }
    }

    @Test func malformedAcknowledgementIsNotAccepted() async throws {
        let session = session { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("not JSON".utf8))
        }
        defer { session.invalidateAndCancel() }
        do {
            _ = try await AgentAlertsClient(session: session).send(AlertRequest(title: "Test", activityID: "test"), token: token)
            Issue.record("Malformed acknowledgement accepted")
        } catch {
            #expect(error.localizedDescription.contains("unreadable acknowledgement"))
        }
    }

    @Test func redirectDelegateDoesNotForwardCredentials() throws {
        let delegate = NoRedirects()
        let original = URLRequest(url: AgentAlertsClient.endpoint)
        let redirected = URLRequest(url: URL(string: "https://example.com/collect")!)
        let response = try #require(HTTPURLResponse(
            url: AgentAlertsClient.endpoint, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": redirected.url!.absoluteString]
        ))
        let task = URLSession.shared.dataTask(with: original)
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            #expect($0 == nil)
        }
        task.cancel()
    }
}
