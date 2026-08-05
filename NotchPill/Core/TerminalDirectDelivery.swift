import AppKit

/// Delivers a reply into a terminal **without taking focus**.
///
/// The normal path pastes into the frontmost window, which means the terminal
/// has to become frontmost — you see it flash forward and back, and for a
/// second you are somewhere you did not ask to be. Some terminals expose
/// scripting that writes straight into a specific panel, and where that exists
/// there is no reason to touch focus at all.
///
/// cmux is the first: `input text … to <terminal>` pastes into a named panel
/// and `perform action "text:\r"` submits it, both while another app stays
/// frontmost — verified end to end, with the reply arriving while FaceTime held
/// focus throughout.
///
/// Everything here is best-effort. Any doubt at all — an ambiguous target, text
/// that cannot be represented safely, a terminal with no scripting — returns
/// `false` and lets the focus-stealing path handle it, because a reply that
/// arrives with a flicker beats one that goes to the wrong window.
enum TerminalDirectDelivery {
    /// Terminals that can be written to without being focused.
    ///
    /// Terminal and iTerm both expose a write-to-a-specific-session command,
    /// so they get the same treatment as cmux — which matters because most
    /// people are not on cmux, and everyone else was still watching their
    /// screen flick away and back on every reply.
    static let supportedBundleIds: Set<String> = [
        "com.cmuxterm.app", "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    /// Terminals located by the agent's controlling tty rather than by working
    /// directory. cmux exposes a panel's directory but not its tty; these two
    /// are the other way round.
    static let ttyAddressedBundleIds: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2",
    ]

    static func supports(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return supportedBundleIds.contains(bundleId)
    }

    /// True when `text` can be carried inside an AppleScript string literal.
    ///
    /// A raw newline cannot: AppleScript has no line continuation inside
    /// quotes, so a multi-line reply would be a syntax error rather than a
    /// wrong result. Those fall back to the paste path, which handles them
    /// fine.
    static func canRepresent(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: \.isNewline)
    }

    static func escaped(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Locates the panel by working directory, exactly as the jump-to-session
    /// script does, and declines when the answer is not unique — writing a
    /// reply into the wrong agent is worse than a flicker.
    static func cmuxScript(text: String, directory: String?, appendReturn: Bool) -> String? {
        guard canRepresent(text) else { return nil }
        let body = escaped(text)
        let submit = appendReturn
            ? "                perform action \"text:\\\\r\" on target\n" : ""
        guard let directory, !directory.isEmpty else {
            // No directory to match on: only safe when there is exactly one
            // terminal open anywhere, which is common enough to be worth it.
            return """
            tell application "cmux"
                set found to {}
                repeat with cmuxWindow in windows
                    repeat with cmuxTab in tabs of cmuxWindow
                        try
                            set end of found to focused terminal of cmuxTab
                        end try
                    end repeat
                end repeat
                if (count of found) is not 1 then return false
                set target to item 1 of found
                input text "\(body)" to target
            \(submit)    return true
            end tell
            """
        }
        return """
        tell application "cmux"
            set found to {}
            repeat with cmuxWindow in windows
                repeat with cmuxTab in tabs of cmuxWindow
                    try
                        set cmuxTerminal to focused terminal of cmuxTab
                        if working directory of cmuxTerminal is "\(escaped(directory))" then
                            set end of found to cmuxTerminal
                        end if
                    end try
                end repeat
            end repeat
            if (count of found) is not 1 then return false
            set target to item 1 of found
            input text "\(body)" to target
        \(submit)    return true
        end tell
        """
    }

    /// Terminal.app addresses a tab by its tty and `do script … in` writes to
    /// it without focusing anything.
    ///
    /// `do script` with no target opens a *new window*, so the tab clause is
    /// not optional here — it is the difference between answering an agent and
    /// spawning a window with your reply typed into a fresh shell.
    static func terminalScript(text: String, tty: String, appendReturn: Bool) -> String? {
        guard canRepresent(text), !tty.isEmpty else { return nil }
        // Terminal submits what `do script` sends; there is no way to type
        // without a return, so a reply that must not submit cannot use it.
        guard appendReturn else { return nil }
        return """
        tell application "Terminal"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    if tty of aTab is "\(escaped(tty))" then
                        do script "\(escaped(text))" in aTab
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// iTerm2's `write text` goes to one session, chosen by tty, and does not
    /// bring the window forward.
    static func iTermScript(text: String, tty: String, appendReturn: Bool) -> String? {
        guard canRepresent(text), !tty.isEmpty else { return nil }
        // `write text` always ends with a newline; `write text … newline no`
        // is the form that does not.
        let newline = appendReturn ? "" : " newline no"
        return """
        tell application "iTerm2"
            repeat with aWindow in windows
                repeat with aTab in tabs of aWindow
                    repeat with aSession in sessions of aTab
                        if tty of aSession is "\(escaped(tty))" then
                            tell aSession to write text "\(escaped(text))"\(newline)
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// Attempts focus-free delivery. `false` means "not handled" — never
    /// "handled badly": the script returns false rather than guessing whenever
    /// the target is ambiguous.
    @MainActor
    static func send(text: String, bundleId: String?, directory: String?,
                     appendReturn: Bool,
                     agent: String? = nil,
                     resolveTTY: (String?, String?) -> String? = { directory, agent in
                         AgentSessionLocator.tty(forDirectory: directory, agent: agent,
                                                 in: AgentSessionLocator.processTable())
                     }) -> Bool {
        guard let bundleId, supports(bundleId: bundleId) else { return false }
        let source: String?
        if ttyAddressedBundleIds.contains(bundleId) {
            // No tty means no way to name the tab. Declining here is the whole
            // safety story for these two: unlike cmux there is no "only one
            // terminal open" fallback, because a stray Terminal window is
            // ordinary and writing a reply into someone's shell is not.
            guard let tty = resolveTTY(directory, agent), !tty.isEmpty else {
                TerminalReplyInjector.log("direct delivery declined "
                                          + "(no tty for \(bundleId)) — falling back")
                return false
            }
            source = bundleId == "com.apple.Terminal"
                ? terminalScript(text: text, tty: tty, appendReturn: appendReturn)
                : iTermScript(text: text, tty: tty, appendReturn: appendReturn)
        } else {
            source = cmuxScript(text: text, directory: directory, appendReturn: appendReturn)
        }
        guard let source else { return false }
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            // Automation can be denied, and that must not look like "delivered".
            TerminalReplyInjector.log("direct delivery failed: "
                                      + "\(error[NSAppleScript.errorNumber] ?? "?")")
            return false
        }
        let delivered = result?.booleanValue == true
        TerminalReplyInjector.log(delivered
            ? "delivered without taking focus"
            : "direct delivery declined (no unique terminal) — falling back")
        return delivered
    }
}
