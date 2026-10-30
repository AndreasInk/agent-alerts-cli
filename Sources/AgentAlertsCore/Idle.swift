import CoreGraphics
import Foundation

public enum Idle {
    public static func seconds() throws -> TimeInterval {
        // kCGAnyInputEventType (all keyboard/mouse events), rather than .null.
        let anyInput = CGEventType(rawValue: UInt32.max)!
        let inputSeconds = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard inputSeconds.isFinite, inputSeconds >= 0, inputSeconds < Double.greatestFiniteMagnitude else {
            throw HookError("Cannot measure keyboard/mouse idle time; automatic alert skipped.")
        }
        return inputSeconds
    }
}
