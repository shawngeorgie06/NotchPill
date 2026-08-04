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
    static let supportedBundleIds: Set<String> = ["com.cmuxterm.app"]

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

    /// Attempts focus-free delivery. `false` means "not handled" — never
    /// "handled badly": the script returns false rather than guessing whenever
    /// the target is ambiguous.
    @MainActor
    static func send(text: String, bundleId: String?, directory: String?,
                     appendReturn: Bool) -> Bool {
        guard supports(bundleId: bundleId),
              let source = cmuxScript(text: text, directory: directory,
                                      appendReturn: appendReturn) else { return false }
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
