import AppKit

/// Delivers a typed reply into a CLI agent's terminal: focus the terminal app,
/// paste the text, press Return, then restore the clipboard. Targeting policy
/// and precondition checks are pure (unit-tested); the CGEvent posting + timing
/// are validated manually.
enum ReplyError: Error, Equatable {
    case emptyText, noTarget, targetNotRunning, accessibilityDenied
}

enum TerminalReplyInjector {
    /// Delay after paste before pressing Return.
    private static let pasteToReturn: TimeInterval = 0.05
    /// Delay after Return before restoring the previous clipboard.
    private static let restoreDelay: TimeInterval = 0.30

    static func canTarget(_ alert: DevReadyAlert) -> Bool {
        !(alert.bundleId ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Pure precondition check. nil = ok to send.
    static func validate(text: String, bundleId: String?,
                         isRunning: Bool, accessibilityGranted: Bool) -> ReplyError? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyText }
        if (bundleId ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return .noTarget }
        if !accessibilityGranted { return .accessibilityDenied }
        if !isRunning { return .targetNotRunning }
        return nil
    }

    @MainActor
    static func send(text: String, bundleId: String?) -> ReplyError? {
        let app = (bundleId?.isEmpty == false)
            ? NSRunningApplication.runningApplications(withBundleIdentifier: bundleId!).first
            : nil
        if let err = validate(text: text, bundleId: bundleId,
                              isRunning: app != nil,
                              accessibilityGranted: AccessibilityAuthorization.isGranted) {
            return err
        }
        guard let app else { return .targetNotRunning }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        let targetBundleId = bundleId ?? ""
        app.activate()

        // Condition-based wait: only paste once the target is actually the
        // frontmost app, so a slow cross-app switch never drops the paste into
        // whatever happened to be focused. Falls through after the timeout.
        waitUntilFrontmost(targetBundleId, attemptsLeft: 30) {
            postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + pasteToReturn) {
                postReturn()
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    pb.clearContents()
                    if let saved { pb.setString(saved, forType: .string) }
                }
            }
        }
        return nil
    }

    /// Polls (every 20ms, up to `attemptsLeft`) until `bundleId` is frontmost,
    /// then runs `body`. Runs `body` anyway once attempts are exhausted.
    @MainActor
    private static func waitUntilFrontmost(_ bundleId: String, attemptsLeft: Int,
                                           then body: @escaping () -> Void) {
        if attemptsLeft <= 0
            || NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
            body()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitUntilFrontmost(bundleId, attemptsLeft: attemptsLeft - 1, then: body)
        }
    }

    // MARK: - CGEvent posting (virtual keycodes: v = 9, return = 36)

    @MainActor private static func postCommandV() {
        postKey(9, flags: .maskCommand)
    }
    @MainActor private static func postReturn() {
        postKey(36, flags: [])
    }
    @MainActor private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
