import Foundation

/// Returns you to the right tmux pane, not just the right terminal window.
///
/// tmux is the case the per-terminal AppleScript work cannot reach. Inside a
/// multiplexer the terminal has one tab, and every agent you are running shares
/// it — Terminal.app and iTerm2 will happily focus that tab and leave you
/// looking at whichever pane happened to be active.
///
/// But the TTY we already resolve for the agent process *is* the tmux pane's
/// TTY, so the pane can be named exactly. That makes this orthogonal to the
/// terminal: it works the same whether tmux is running inside Terminal, iTerm,
/// cmux or an ssh session, and it runs before the terminal-specific paths so
/// the pane is selected first and the window brought forward after.
enum TmuxLocator {
    /// Where tmux is looked for. It is usually not on the PATH a GUI app
    /// inherits, which is a very short list that does not include Homebrew or
    /// a user's own bin directory.
    static let searchPaths = [
        "/opt/homebrew/bin/tmux",
        "/usr/local/bin/tmux",
        "/usr/bin/tmux",
        NSHomeDirectory() + "/.local/bin/tmux",
    ]

    static func executable(fileExists: (String) -> Bool = {
        FileManager.default.isExecutableFile(atPath: $0)
    }) -> String? {
        searchPaths.first(where: fileExists)
    }

    /// What we ask tmux to print: one line per pane, TTY first.
    static let listFormat = "#{pane_tty}\t#{session_name}:#{window_index}.#{pane_index}"

    static let listArguments = ["list-panes", "-a", "-F", listFormat]

    /// Finds the pane whose TTY owns the agent.
    ///
    /// Matching is exact. A prefix match would be wrong in a way that is hard
    /// to notice: `/dev/ttys1` is a prefix of `/dev/ttys12`, so a loose rule
    /// would occasionally drop you into a completely unrelated pane and look
    /// like tmux misbehaving rather than like a bug here.
    static func paneTarget(forTTY tty: String, in listOutput: String) -> String? {
        let wanted = tty.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        for line in listOutput.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespaces) == wanted else { continue }
            let target = parts[1].trimmingCharacters(in: .whitespaces)
            return target.isEmpty ? nil : target
        }
        return nil
    }

    /// Selecting a pane takes two steps, and both are needed.
    ///
    /// `select-window` moves the session to the right window; `select-pane`
    /// moves within it. Doing only the second leaves you on the correct pane of
    /// a window you cannot see. `switch-client` is deliberately not used: it
    /// would yank an *attached* client away from whatever else you were doing
    /// in another session, which is a far ruder thing to do than showing you
    /// the pane in the session it belongs to.
    static func selectArguments(target: String) -> [[String]] {
        [["select-window", "-t", target], ["select-pane", "-t", target]]
    }

    /// Best effort by design: no tmux, no server, or no matching pane all mean
    /// "this session is not in tmux", and the caller carries on to the normal
    /// terminal focus path.
    @discardableResult
    static func focusPane(tty: String,
                          tmuxPath: String? = executable(),
                          run: (String, [String]) -> Data? = ProcessRunner.capture) -> Bool {
        guard let tmux = tmuxPath,
              let data = run(tmux, listArguments),
              let text = String(data: data, encoding: .utf8),
              let target = paneTarget(forTTY: tty, in: text) else { return false }
        for arguments in selectArguments(target: target) {
            _ = run(tmux, arguments)
        }
        return true
    }
}
