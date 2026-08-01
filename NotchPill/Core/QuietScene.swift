import CoreGraphics
import Foundation

/// Times when the notch should keep its mouth shut.
///
/// A peek that fires while the Mac is locked is worse than useless: the sound
/// plays to an empty room, and the peek itself spends its few seconds on a
/// screen nobody is looking at — so the one thing it existed to tell you is
/// gone by the time you come back. Suppressing it means the follow-up reminder
/// raises it properly later, which is the behaviour you actually wanted.
///
/// Only lock state is implemented, and that is deliberate. The obvious
/// companions do not have honest answers on this platform:
///
/// - **Focus / Do Not Disturb** lives in `~/Library/DoNotDisturb/DB/`, which is
///   TCC-protected — reading it returns "Operation not permitted" without Full
///   Disk Access. The legacy `com.apple.notificationcenterui` `doNotDisturb`
///   key still reads without permission but returns `false` regardless of the
///   real Focus state, so honouring it would be a silent lie.
/// - **Screen recording or sharing** has no public API to observe in another
///   process.
///
/// A quiet mode that silently fails to be quiet is worse than not offering it,
/// so neither is guessed at.
enum QuietScene {
    /// Whether the login session's screen is locked.
    ///
    /// `CGSessionCopyCurrentDictionary` needs no entitlement and no permission
    /// prompt. Absent keys read as "not locked": the failure that matters is
    /// going silent when we should not have, so an unreadable session errs
    /// towards speaking.
    static func screenIsLocked(
        session: () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }
    ) -> Bool {
        guard let info = session() else { return false }
        if let locked = info["CGSSessionScreenIsLocked"] as? Bool { return locked }
        // Some macOS versions report it as 0/1 rather than a boolean.
        if let locked = info["CGSSessionScreenIsLocked"] as? Int { return locked != 0 }
        return false
    }

    /// Whether this login session owns the display at all. Fast user switching
    /// leaves us running behind somebody else's session, where a peek would
    /// either be invisible or — worse — appear over their screen.
    static func onConsole(
        session: () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }
    ) -> Bool {
        guard let info = session() else { return true }
        if let on = info["kCGSSessionOnConsoleKey"] as? Bool { return on }
        if let on = info["kCGSSessionOnConsoleKey"] as? Int { return on != 0 }
        return true
    }

    static func shouldStayQuiet(
        enabled: Bool,
        session: () -> [String: Any]? = { CGSessionCopyCurrentDictionary() as? [String: Any] }
    ) -> Bool {
        guard enabled else { return false }
        return screenIsLocked(session: session) || !onConsole(session: session)
    }
}
