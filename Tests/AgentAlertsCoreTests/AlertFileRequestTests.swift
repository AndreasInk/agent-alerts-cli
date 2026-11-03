import Darwin
import Foundation
import Testing
@testable import AgentAlertsCore

@Suite struct AlertFileRequestTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test(arguments: ["progress", "build-health"])
    func exampleFilesPreserveTheLayoutAndGenerateFreshMetadata(name: String) throws {
        let file = root.appendingPathComponent("examples/\(name).json")
        let original = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let first = try AlertFileRequest(contentsOf: file, activityID: "checks")
        let second = try AlertFileRequest(contentsOf: file, activityID: "checks")
        let body = try object(first.body)
        let payload = try #require(body["payload"] as? [String: Any])
        #expect(NSDictionary(dictionary: try #require(payload["builderSpec"] as? [String: Any]))
            .isEqual(to: try #require(original["builderSpec"] as? [String: Any])))
        #expect(payload["title"] as? String == original["title"] as? String)
        #expect(payload["generatedAt"] as? Int != nil)
        #expect(body["activity_id"] as? String == "checks")
        #expect(body["update_mode"] as? String == "upsert_single")
        #expect(body["surfaces"] as? [String] == ["live_activity", "notification"])
        #expect(first.idempotencyKey != second.idempotencyKey)
        #expect(body["idempotency_key"] as? String == first.idempotencyKey)
        #expect(body["apns_env"] as? String == "production")
    }

    @Test func fileSendsReuseHeadlineDefaultsAndStartEndRouting() throws {
        let data = Data(#"{"title":" Build finished "}"#.utf8)
        for event in [AlertEvent.start, .update, .end] {
            let request = try AlertFileRequest(data: data, activityID: "build", event: event, now: Date(timeIntervalSince1970: 1234))
            let body = try object(request.body)
            let payload = try #require(body["payload"] as? [String: Any])
            #expect(payload["title"] as? String == "Build finished")
            #expect(payload["summary"] as? String == "Build finished")
            #expect(payload["status"] as? String == "good")
            #expect(payload["template"] as? String == "agent")
            #expect(payload["generatedAt"] as? Int == 1234)
            #expect(body["event"] as? String == event.rawValue)
            if event == .start {
                #expect(body["attributes_type"] as? String == "ReportKitSimpleAttributes")
                #expect((body["attributes"] as? [String: String])?["reportID"] == "build")
                #expect((body["alert"] as? [String: String])?["body"] == "Build finished")
                #expect(body["update_mode"] == nil)
            } else if event == .end {
                #expect(body["update_mode"] as? String == "update_existing")
                #expect(body["notification"] == nil)
                #expect(body["alert"] == nil)
                #expect(body["surfaces"] as? [String] == ["live_activity"])
            }
        }
    }

    @Test(arguments: [
        "not JSON", "[]", "{}", #"{"title":5}"#, #"{"title":"Build","summary":42}"#,
        #"{"title":"Build","status":"okay"}"#, #"{"payload":{"title":"Build"}}"#,
        #"{"title":"Build","activity_id":"bypass"}"#, #"{"title":"Build","generatedAt":1}"#,
        #"{"title":"Build","systemState":"quota_limited"}"#, #"{"title":"Build","template":"unknown"}"#,
        #"{"title":"Build","template":"builder"}"#,
        #"{"title":"Build","template":"builder","builderSpec":{"version":2,"surfaces":{}}}"#,
        #"{"title":"Build","template":"builder","builderSpec":{"version":1,"surfaces":{"minimal":{"type":"statusDot"}}}}"#,
    ])
    func malformedContentFailsBeforeSending(json: String) {
        #expect(throws: AppError.self) { try AlertFileRequest(data: Data(json.utf8), activityID: "build") }
    }

    @Test func reusesVisibleTextValidation() throws {
        for content: [String: Any] in [
            ["title": String(repeating: "a", count: 33)],
            ["title": "Build", "summary": String(repeating: "a", count: 97)],
            ["title": "Build\u{1B}"],
        ] {
            let data = try JSONSerialization.data(withJSONObject: content)
            #expect(throws: AppError.self) { try AlertFileRequest(data: data, activityID: "build") }
        }
    }

    @Test func countsTheWholePotentialStartIncludingUnicodeAndDuplicatedCopy() throws {
        let content: [String: Any] = [
            "title": String(repeating: "🙂", count: 32), "summary": String(repeating: "🙂", count: 96),
            "data": ["notes": String(repeating: "a", count: 1900)],
        ]
        let data = try JSONSerialization.data(withJSONObject: content)
        #expect(data.count < 4096)
        let longID = String(repeating: "🙂", count: 255)
        #expect(throws: AppError.self) { try AlertFileRequest(data: data, activityID: longID, event: .update) }
        #expect(throws: AppError.self) { try AlertFileRequest(data: data, activityID: longID, event: .start) }
        // End messages don't carry the start attributes or duplicate alert text.
        _ = try AlertFileRequest(data: data, activityID: longID, event: .end)
        #expect(throws: AppError.self) {
            try AlertFileRequest(data: Data(repeating: 32, count: 65_537), activityID: "build")
        }
    }

    @Test func rejectsNonRegularAndMissingFilesWithoutWaiting() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fifo = directory.appendingPathComponent("input.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: AppError.self) { try AlertFileRequest(contentsOf: fifo, activityID: "build") }
        #expect(throws: AppError.self) { try AlertFileRequest(contentsOf: directory, activityID: "build") }
        #expect(throws: AppError.self) { try AlertFileRequest(contentsOf: directory.appendingPathComponent("missing"), activityID: "build") }
    }

    @Test func budgetsNumbersForServiceJSONReencoding() throws {
        // JavaScript expands each 1e20 to 21 digits; Foundation writes the shorter 1e+20.
        let content: [String: Any] = ["title": "Build", "data": ["values": Array(repeating: 1e20, count: 200)]]
        let data = try JSONSerialization.data(withJSONObject: content)
        #expect(data.count < 4096)
        #expect(throws: AppError.self) { try AlertFileRequest(data: data, activityID: "build") }
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
