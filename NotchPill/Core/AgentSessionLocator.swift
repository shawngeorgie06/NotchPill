import AppKit

/// Finds which application a terminal agent session is running inside, so
/// tapping its row can take you there.
///
/// Nothing on disk records this. A transcript names the project and the session
/// but never the window, which is why finished peeks from the watcher carry no
/// bundle id. The process tree does know, though: the agent's process descends
/// from whatever app opened the terminal, so walking up from it lands on
/// `…/Something.app/Contents/MacOS/…`.
///
/// This runs **only when a row is tapped**, never on a timer. Enumerating
/// processes is far too expensive to poll, and the answer is only ever needed
/// at the moment someone asks for it.
enum AgentSessionLocator {

    /// Bundle id of the app hosting this session, if it can be determined.
    static func hostingBundleId(forSessionId sessionId: String) -> String? {
        guard !sessionId.isEmpty else { return nil }
        return hostingBundleId(forSessionId: sessionId, in: processTable())
    }

    /// Split from the `ps` call so the choice of process can be tested.
    ///
    /// Any process merely *mentioning* the id matches — a grep, an editor with
    /// the transcript open, this app's own diagnostics — and focusing whatever
    /// that descends from would send you somewhere random. So candidates that
    /// look like the agent binary are preferred, and the rest are only a
    /// fallback.
    static func hostingBundleId(forSessionId sessionId: String, in table: [Entry]) -> String? {
        for candidate in candidates(forSessionId: sessionId, in: table) {
            if let id = bundleId(walkingUpFrom: candidate.pid, in: table) { return id }
        }
        return nil
    }

    /// Brings that app forward. Returns false when the session could not be
    /// placed, so the caller can decide whether to say so.
    @discardableResult
    static func focus(sessionId: String?,
                      fallbackBundleId: String?,
                      directory: String? = nil,
                      agent: String? = nil) -> Bool {
        let table = processTable()
        let candidateEntries: [Entry] = sessionId.map { candidates(forSessionId: $0, in: table) } ?? []
        let located = candidateEntries.lazy.compactMap { entry in
            bundleId(walkingUpFrom: entry.pid, in: table).map { (entry, $0) }
        }.first
        // Last resort before giving up: the terminal that is demonstrably
        // hosting agents right now.
        let target: String? = located?.1 ?? fallbackBundleId
            ?? soleTerminalHost(agent: agent, in: table)
        guard let target, !target.isEmpty else {
            // Silent until now, and it is the likeliest outcome: a terminal
            // agent writes no bundle id anywhere, so it can only be placed by
            // walking the process tree from a process whose command line
            // mentions the session id. When that fails there is no fallback
            // except for Cursor, and the tap did nothing with nothing to show
            // for it.
            LogStore.log("focus", "no host found for session "
                         + "\(sessionId ?? "-") (candidates=\(candidateEntries.count), "
                         + "fallback=\(fallbackBundleId ?? "none"))")
            return false
        }
        LogStore.log("focus", "session \(sessionId ?? "-") hosted by \(target) "
                     + "(\(located == nil ? "fallback" : "process tree"))")

        // Inside tmux the terminal has one tab and every pane shares it, so
        // focusing the tab alone leaves you on whichever pane was last active.
        // Selecting the pane first means the terminal focus below then brings
        // the right thing forward. No-ops when this session is not in tmux.
        if let pid = located?.0.pid, let tty = controllingTTY(for: pid) {
            TmuxLocator.focusPane(tty: tty)
        }

        // Terminal exposes each tab's TTY to AppleScript. That lets us return
        // to the exact agent pane rather than merely bringing every Terminal
        // window forward. Automation can be denied or Terminal may not own the
        // process, so this is intentionally best-effort and falls through to
        // the normal focus path in every failure case.
        if target == "com.apple.Terminal",
           let pid = located?.0.pid,
           let tty = controllingTTY(for: pid),
           focusTerminalTab(tty: tty) {
            return true
        }

        if target == "com.googlecode.iterm2",
           let pid = located?.0.pid,
           let tty = controllingTTY(for: pid),
           focusITermSession(tty: tty) {
            return true
        }

        // cmux exposes each terminal's working directory but not its TTY, so
        // the session is matched by directory instead. Ambiguity is declined
        // rather than guessed at — see `cmuxFocusScript`.
        if target == "com.cmuxterm.app",
           let directory, !directory.isEmpty,
           runAppleScript(cmuxFocusScript(directory: directory)) {
            return true
        }

        // The AppleScript paths above each `activate` the target themselves, so
        // they are unaffected. This last-resort branch is the one that used to
        // report success while leaving focus exactly where it was.
        guard NSRunningApplication
            .runningApplications(withBundleIdentifier: target).first != nil else { return false }
        DispatchQueue.main.async { AppActivator.activate(bundleId: target) }
        // "Asked, and the app is running." The escalation is asynchronous, so
        // this cannot report the observed outcome; `AppActivator` logs it.
        return true
    }

    /// The executable name of a CLI agent, per agent.
    ///
    /// Split by agent rather than pooled, because pooling is wrong the moment
    /// someone runs two: measured here with Claude Code in cmux and Codex on
    /// the desktop, a pooled lookup saw two hosts, called it ambiguous, and
    /// declined — leaving the tap as broken as before.
    static func executableName(for agent: String?) -> String? {
        switch agent {
        case "codex": return "codex"
        case "opencode": return "opencode"
        case "claude-code": return "claude"
        default: return nil
        }
    }

    /// True when this process *is* the named binary, rather than merely
    /// mentioning it.
    ///
    /// Substring matching was measured picking up a `grep -iE "claude|codex"`
    /// — a shell that mentions both, descends from a terminal, and is not an
    /// agent at all. It made Codex look like it was hosted in two places and
    /// the lookup declined. Only the executable itself counts.
    static func isProcess(_ args: String, named executable: String) -> Bool {
        guard let first = args.split(separator: " ", maxSplits: 1,
                                     omittingEmptySubsequences: true).first else { return false }
        let name = first.split(separator: "/").last.map(String.init) ?? String(first)
        return name == executable
    }

    /// The terminal app hosting CLI agents, when there is exactly one.
    ///
    /// The session-id lookup only succeeds while a process carrying that id is
    /// alive, and for Claude Code those are the *transient* shells it spawns to
    /// run tools — they exist during a Bash call and vanish the moment it ends.
    /// So an idle agent, which is precisely the row you want to jump to, could
    /// not be placed at all, and terminal agents had no fallback: the tap did
    /// nothing. This walks up from the agent processes themselves, which live
    /// as long as the session does.
    ///
    /// Ambiguity declines. Two terminals hosting agents means jumping to the
    /// wrong one is as likely as the right one, and a tap that does nothing is
    /// better than a tap that takes you somewhere false.
    static func soleTerminalHost(agent: String?, in table: [Entry]) -> String? {
        guard let executable = executableName(for: agent) else { return nil }
        let hosts = Set(table.lazy
            .filter { isProcess($0.args, named: executable) }
            .compactMap { bundleId(walkingUpFrom: $0.pid, in: table) }
            .filter { $0 != Bundle.main.bundleIdentifier })
        return hosts.count == 1 ? hosts.first : nil
    }

    /// Candidates in preference order. Kept independent of the process query
    /// both for tests and so focusing uses precisely the same safety rule as
    /// the host-app lookup.
    static func candidates(forSessionId sessionId: String, in table: [Entry]) -> [Entry] {
        guard !sessionId.isEmpty else { return [] }
        let matches = table.filter { $0.args.contains(sessionId) }
        let agentish = matches.filter { entry in
            ["/claude", "/codex", "claude ", "codex "].contains { entry.args.contains($0) }
        }
        return agentish + matches.filter { candidate in !agentish.contains { $0.pid == candidate.pid } }
    }

    // MARK: - Process tree

    struct Entry {
        let pid: Int32
        let ppid: Int32
        let args: String
    }

    /// One `ps` invocation rather than repeated `sysctl` calls: this happens
    /// once per tap, and correctness beats micro-optimisation here.
    static func processTable() -> [Entry] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,ppid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return parse(text)
    }

    /// `ps` reports the controlling terminal as (for example) `ttys012`.
    /// Terminal's scripting API uses the corresponding `/dev/ttys012` value.
    private static func controllingTTY(for pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "tty="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let name = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name != "??" else { return nil }
        return name.hasPrefix("/dev/") ? name : "/dev/" + name
    }

    private static func focusTerminalTab(tty: String) -> Bool {
        runAppleScript(terminalFocusScript(tty: tty))
    }

    /// iTerm2's AppleScript dictionary exposes each split-pane session's TTY
    /// and `select` operations at every level. Unlike an accessibility-tree
    /// guess, this returns the process to the exact pane that owns it.
    private static func focusITermSession(tty: String) -> Bool {
        runAppleScript(iTermFocusScript(tty: tty))
    }

    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?
            .executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    /// Exposed for a small pure test. Inputs are escaped before being placed in
    /// AppleScript, even though a real TTY cannot normally contain quotes.
    static func terminalFocusScript(tty: String) -> String {
        let escaped = escapedAppleScriptString(tty)
        return """
        tell application "Terminal"
            activate
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    if tty of terminalTab is "\(escaped)" then
                        set selected tab of terminalWindow to terminalTab
                        set index of terminalWindow to 1
                        return true
                    end if
                end repeat
            end repeat
            return false
        end tell
        """
    }

    /// Exposed for a pure test. cmux is matched on working directory because
    /// its scripting dictionary exposes one and no TTY.
    ///
    /// The leading `activate` is not decoration. `focus` selects a tab *within*
    /// cmux and does nothing about which app is in front, so without it this
    /// script matched, focused, and returned true while cmux stayed in the
    /// background — and because the caller treats true as success, it returned
    /// before reaching the activation fallback. Tapping a live-agent row did
    /// nothing visible at all. Terminal's and iTerm's scripts have always
    /// activated first; this one was the odd one out.
    ///
    /// Two tabs open on the same directory are indistinguishable this way, so
    /// the script counts matches first and focuses nothing unless there is
    /// exactly one. Landing you in the wrong tab is worse than landing you in
    /// the right app: the caller falls through to plain activation, which is
    /// the same thing an unscriptable terminal gets.
    static func cmuxFocusScript(directory: String) -> String {
        let escaped = escapedAppleScriptString(directory)
        return """
        tell application "cmux"
            activate
            set matches to {}
            repeat with cmuxWindow in windows
                repeat with cmuxTab in tabs of cmuxWindow
                    try
                        set cmuxTerminal to focused terminal of cmuxTab
                        if working directory of cmuxTerminal is "\(escaped)" then
                            set end of matches to cmuxTerminal
                        end if
                    end try
                end repeat
            end repeat
            if (count of matches) is 1 then
                focus (item 1 of matches)
                return true
            end if
            return false
        end tell
        """
    }

    /// Exposed for a pure test. iTerm sessions remain distinct in split panes,
    /// so selecting all three levels is required for a true return-to-work.
    static func iTermFocusScript(tty: String) -> String {
        let escaped = escapedAppleScriptString(tty)
        return """
        tell application "iTerm2"
            activate
            repeat with terminalWindow in windows
                repeat with terminalTab in tabs of terminalWindow
                    repeat with terminalSession in sessions of terminalTab
                        if tty of terminalSession is "\(escaped)" then
                            tell terminalWindow to select
                            tell terminalTab to select
                            tell terminalSession to select
                            return true
                        end if
                    end repeat
                end repeat
            end repeat
            return false
        end tell
        """
    }

    private static func escapedAppleScriptString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Split out so the walk can be tested without spawning anything.
    static func parse(_ psOutput: String) -> [Entry] {
        psOutput.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", maxSplits: 2,
                                      omittingEmptySubsequences: true)
            guard parts.count >= 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1])
            else { return nil }
            return Entry(pid: pid, ppid: ppid, args: String(parts[2]))
        }
    }

    /// Climbs the parent chain until an app bundle appears.
    ///
    /// Depth-capped and cycle-guarded: a malformed table must not spin forever,
    /// and this runs on a tap, in front of the user.
    static func bundleId(walkingUpFrom pid: Int32, in table: [Entry]) -> String? {
        var byPid: [Int32: Entry] = [:]
        for e in table { byPid[e.pid] = e }
        var current = pid
        var seen = Set<Int32>()
        for _ in 0..<12 {
            guard let entry = byPid[current], !seen.contains(current) else { return nil }
            seen.insert(current)
            if let path = appBundlePath(in: entry.args) {
                return Bundle(path: path)?.bundleIdentifier
            }
            if entry.ppid <= 1 { return nil }
            current = entry.ppid
        }
        return nil
    }

    /// Pulls `/Applications/Foo.app` out of an executable path.
    static func appBundlePath(in args: String) -> String? {
        guard let range = args.range(of: ".app/Contents/MacOS/") else { return nil }
        let prefix = String(args[args.startIndex..<range.lowerBound]) + ".app"
        // The command may be preceded by an interpreter or wrapper, so keep only
        // the last path-looking run of characters.
        guard let start = prefix.range(of: " /", options: .backwards)?.upperBound
                ?? (prefix.hasPrefix("/") ? prefix.startIndex : nil) else { return nil }
        let path = String(prefix[start...])
        return path.hasPrefix("/") ? path : nil
    }
}
