import Foundation

/// Whether the approval loop is armed.
///
/// The `PreToolUse` hook blocks the agent while it waits for you, and it cannot
/// know whether Claude was going to prompt at all — for a tool you have already
/// allowed, waiting is pure latency on every call. So it is off unless you opt
/// in, and the opt-in is the presence of a file:
///
///     ~/.notchpill/approvals-enabled
///
/// The file is the *only* record of that fact, deliberately. `UserDefaults`
/// would be the natural home for a checkbox, but the thing that reads this is a
/// shell script (`Scripts/claude-code-permission.sh`) and it cannot read
/// defaults. Storing it in both places would mean two records of one fact that
/// can disagree — the same drift that once left the approval peek rendering
/// stale text because only one of two parsers had been updated.
enum ApprovalGate {
    static func file(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".notchpill/approvals-enabled", isDirectory: false)
    }

    static func isEnabled(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        FileManager.default.fileExists(atPath: file(home: home).path)
    }

    /// Turning it off is the reversible half and must not be able to fail for a
    /// reason the user cannot act on: a file that is already gone is the state
    /// being asked for, not an error.
    static func setEnabled(_ enabled: Bool,
                           home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let target = file(home: home)
        guard enabled else {
            do { try FileManager.default.removeItem(at: target) }
            catch CocoaError.fileNoSuchFile {}
            catch let error as NSError where error.domain == NSPOSIXErrorDomain
                && error.code == Int(ENOENT) {}
            return
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        // Empty: only the existence carries meaning, and writing nothing keeps
        // an enable idempotent rather than truncating something a future
        // version might have put here.
        guard !isEnabled(home: home) else { return }
        try Data().write(to: target)
    }
}
