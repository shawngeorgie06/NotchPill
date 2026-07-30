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
    static func focus(sessionId: String?, fallbackBundleId: String?) -> Bool {
        let table = processTable()
        let candidateEntries: [Entry] = sessionId.map { candidates(forSessionId: $0, in: table) } ?? []
        let target: String? = candidateEntries.lazy.compactMap { bundleId(walkingUpFrom: $0.pid, in: table) }.first
            ?? fallbackBundleId
        guard let target, !target.isEmpty else { return false }

        // Terminal exposes each tab's TTY to AppleScript. That lets us return
        // to the exact agent pane rather than merely bringing every Terminal
        // window forward. Automation can be denied or Terminal may not own the
        // process, so this is intentionally best-effort and falls through to
        // the normal focus path in every failure case.
        if target == "com.apple.Terminal",
           let pid = candidateEntries.first?.pid,
           let tty = controllingTTY(for: pid),
           focusTerminalTab(tty: tty) {
            return true
        }

        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: target).first else { return false }
        return app.activate(options: [.activateAllWindows])
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
        var error: NSDictionary?
        let result = NSAppleScript(source: terminalFocusScript(tty: tty))?
            .executeAndReturnError(&error)
        return error == nil && result?.booleanValue == true
    }

    /// Exposed for a small pure test. Inputs are escaped before being placed in
    /// AppleScript, even though a real TTY cannot normally contain quotes.
    static func terminalFocusScript(tty: String) -> String {
        let escaped = tty
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
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
