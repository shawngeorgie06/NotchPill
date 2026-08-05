import AppKit

/// Delivers a typed reply into a CLI agent's terminal: focus the terminal app,
/// paste the text, press Return, then restore the clipboard. Targeting policy
/// and precondition checks are pure (unit-tested); the CGEvent posting + timing
/// are validated manually.
enum ReplyError: Error, Equatable {
    case emptyText, noTarget, targetNotRunning, accessibilityDenied
    /// The target app never became frontmost within the focus window, so the
    /// paste was aborted rather than fired into whatever else was focused.
    case focusTimeout
}

enum TerminalReplyInjector {
    /// Traces the whole delivery path (NOTCHPILL_LOG_REPLY=1). Every failure mode
    /// here — a denied TCC grant, a target that isn't running, a focus handoff
    /// that never lands — looks identical from the outside: "the answer just
    /// didn't arrive". Without this you are guessing.
    static let logReply = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_REPLY"] == "1"
    static func log(_ msg: @autoclosure () -> String) {
        guard logReply else { return }
        print("REPLY \(msg())")
    }

    /// Delay after a *paste* before pressing Return. Deliberately generous: a
    /// TUI receives a bracketed paste as one chunk, and a Return arriving inside
    /// that window is treated as a newline *within* the pasted text rather than
    /// "submit" — the reply then sits in the composer, typed but never sent.
    private static let pasteToReturn: TimeInterval = 0.35
    /// Delay after *typed* characters before Return. These are already discrete
    /// key events, so Return only has to land after the last one.
    private static let keystrokeToReturn: TimeInterval = 0.08
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

    /// How the text reaches the terminal.
    enum Delivery {
        /// Clipboard + ⌘V. Right for free-text replies: the terminal emits it as a
        /// *bracketed paste*, which a TUI routes to its text input.
        case paste
        /// Synthetic key events, one per character. Required for answering a TUI
        /// prompt: Claude Code's permission prompt selects on **keypress**, and a
        /// bracketed paste is not a keypress — verified end-to-end, where a pasted
        /// `y` landed in the composer and submitted as a chat message while the
        /// prompt sat untouched.
        case keystrokes
    }

    /// Sends `text` to `bundleId`'s frontmost window.
    ///
    /// The synchronous return reports **pre-flight** failures only (`validate`)
    /// — Phase 1's `performReply` and Phase 2's `performAnswer` both rely on
    /// `nil` meaning "accepted". Failures that can only be discovered later (the
    /// target never taking focus) are reported through `completion`, which fires
    /// at most once and only for the async outcome.
    /// - Parameter returnFocus: hand focus back to whatever was frontmost when
    ///   the reply was sent. The target *has* to take focus to receive the
    ///   paste, so this cannot mean "never leave" — it means "come straight
    ///   back", which is the difference between a reply interrupting your work
    ///   and a reply being sent from it.
    @MainActor
    @discardableResult
    static func send(text: String, bundleId: String?, appendReturn: Bool = true,
                     delivery: Delivery = .paste, returnFocus: Bool = false,
                     directory: String? = nil, agent: String? = nil,
                     completion: ((ReplyError?) -> Void)? = nil) -> ReplyError? {
        let app = (bundleId?.isEmpty == false)
            ? NSRunningApplication.runningApplications(withBundleIdentifier: bundleId!).first
            : nil
        let granted = AccessibilityAuthorization.isGranted
        log("send text=\(text.debugDescription) bundleId=\(bundleId ?? "nil") "
            + "appRunning=\(app != nil) accessibilityGranted=\(granted) appendReturn=\(appendReturn)")
        log("frontmost at entry=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil")")
        if let err = validate(text: text, bundleId: bundleId,
                              isRunning: app != nil,
                              accessibilityGranted: granted) {
            log("REJECTED pre-flight: \(err)")
            return err
        }
        guard let app else { log("REJECTED: app vanished"); return .targetNotRunning }

        // Preferred when the terminal supports it: writes into the panel
        // directly, so focus never moves and there is no flicker to return
        // from. Falls through to the paste path whenever it declines.
        if TerminalDirectDelivery.send(text: text, bundleId: bundleId,
                                       directory: directory,
                                       appendReturn: appendReturn,
                                       agent: agent) {
            completion?(nil)
            return nil
        }

        // Keystroke delivery never touches the clipboard — nothing to save or
        // restore, and no window where the user's clipboard holds our payload.
        let pb = NSPasteboard.general
        let saved = (delivery == .paste) ? pb.string(forType: .string) : nil
        if delivery == .paste {
            pb.clearContents()
            pb.setString(text, forType: .string)
        }

        let targetBundleId = bundleId ?? ""
        // Captured before activation, or it would just be the target.
        // NotchPill itself is an accessory app and never frontmost, so this is
        // the real app the user was looking at.
        let previousApp = returnFocus
            ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
        // `app.activate()` alone reports success without moving focus when the
        // caller is a background accessory app, which is what NotchPill always
        // is. Every reply then hit the abort below and nothing was ever sent.
        AppActivator.activate(bundleId: targetBundleId)

        let restoreClipboard = {
            guard delivery == .paste else { return }
            pb.clearContents()
            if let saved { pb.setString(saved, forType: .string) }
        }

        // Condition-based wait: only paste once the target is actually the
        // frontmost app, so a slow cross-app switch never drops the paste into
        // whatever happened to be focused. On timeout we *abort* — never
        // blind-fire: a stray ⏎ into a frontmost modal confirms its default button.
        // 125 × 20ms ≈ 2.5s. Generous on purpose: exceeding this now *discards*
        // the send rather than firing it blind, and the case this feature exists
        // for — the terminal is on another Space — routinely costs more than the
        // 600ms that was fine back when overrunning it was harmless.
        waitUntilFrontmost(targetBundleId, attemptsLeft: 125) { becameFrontmost in
            guard becameFrontmost else {
                log("ABORT: \(targetBundleId) never became frontmost "
                    + "(still \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"))")
                restoreClipboard()
                completion?(.focusTimeout)
                return
            }
            let settle: TimeInterval
            switch delivery {
            case .paste:
                log("focused \(targetBundleId) — posting ⌘V")
                postCommandV()
                settle = pasteToReturn
            case .keystrokes:
                log("focused \(targetBundleId) — typing \(text.debugDescription) as key events")
                postCharacters(text)
                settle = keystrokeToReturn
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
                if appendReturn { log("posting ⏎"); postReturn() }
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    restoreClipboard()
                    log("done — clipboard restored")
                    // After the ⏎, never before: taking focus away mid-paste
                    // would drop the rest of the reply into the wrong window.
                    if let previousApp, previousApp != targetBundleId {
                        log("returning focus to \(previousApp)")
                        AppActivator.activate(bundleId: previousApp)
                    }
                    completion?(nil)
                }
            }
        }
        return nil
    }

    /// Polls (every 20ms, up to `attemptsLeft`) until `bundleId` is frontmost,
    /// then runs `body(true)`. Once attempts are exhausted it runs `body(false)`
    /// so the caller can abort — it never assumes focus it didn't observe.
    @MainActor
    private static func waitUntilFrontmost(_ bundleId: String, attemptsLeft: Int,
                                           then body: @escaping (Bool) -> Void) {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleId {
            body(true)
            return
        }
        if attemptsLeft <= 0 {
            body(false)
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

    /// Types `text` as individual key events. Uses `keyboardSetUnicodeString`
    /// rather than a character→virtual-keycode table so it doesn't depend on the
    /// user's keyboard layout — the terminal writes these straight through to the
    /// pty as ordinary input, with none of the bracketed-paste framing that makes
    /// a TUI treat the payload as text instead of a keypress.
    @MainActor private static func postCharacters(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for char in text.unicodeScalars {
            var utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
            else { log("CGEvent creation FAILED for \(char.debugDescription)"); continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
    @MainActor private static func postReturn() {
        postKey(36, flags: [])
    }
    @MainActor private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { log("CGEvent creation FAILED for keyCode \(keyCode)"); return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
