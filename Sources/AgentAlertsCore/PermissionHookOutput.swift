public struct PermissionHookOutput: Encodable, Sendable {
    struct Output: Encodable, Sendable {
        struct Decision: Encodable, Sendable { let behavior: String }
        let hookEventName = "PermissionRequest"
        let decision: Decision
    }
    let hookSpecificOutput: Output

    public init(decision: ApprovalDecision) {
        hookSpecificOutput = Output(decision: .init(behavior: decision == .allow ? "allow" : "deny"))
    }
}
