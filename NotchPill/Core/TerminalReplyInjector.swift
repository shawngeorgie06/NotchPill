import AppKit

/// Delivers a typed reply into a CLI agent's terminal: focus the terminal app,
/// paste the text, press Return, then restore the clipboard. Targeting policy
/// and precondition checks are pure (unit-tested); the CGEvent posting + timing
/// are validated manually.
enum ReplyError: Error, Equatable {
    case emptyText, noTarget, targetNotRunning, accessibilityDenied
}

enum TerminalReplyInjector {
    /// Settle delay after activating the terminal before pasting.
    private static let activateSettle: TimeInterval = 0.12
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

        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + activateSettle) {
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
