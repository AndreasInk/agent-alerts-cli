import Foundation
import Testing
@testable import AgentAlertsCore

struct PermissionOutputTests {
    @Test(arguments: [ApprovalDecision.allow, .deny])
    func emitsOnlyTheSingleRequestDecision(decision: ApprovalDecision) throws {
        let output = PermissionHookOutput(decision: decision)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(output)) as? [String: Any])
        let expected: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": decision == .allow ? "allow" : "deny"],
            ],
        ]
        #expect(NSDictionary(dictionary: object).isEqual(to: expected))
    }
}
