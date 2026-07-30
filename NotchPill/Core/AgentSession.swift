import Foundation

/// One agent conversation that is alive right now.
///
/// This is the "what am I actually in?" view. A peek tells you a turn *ended*;
/// this tells you what is still running, which is the thing you cannot get from
/// notifications no matter how many you send.
struct AgentSession: Equatable, Identifiable {
    enum State: Equatable {
        /// The transcript is still growing — the agent is mid-turn.
        case working
        /// Blocked on you. Only Cursor reports this without a hook; for the
        /// terminal agents it arrives via the waiting peek.
        case waiting
        /// Alive but quiet. `since` is when it went quiet, so the row can age.
        case idle(since: Date)

        /// Name without the payload — for logging, where the timestamp inside
        /// `.idle` would make every entry look different.
        var name: String {
            switch self {
            case .working: return "working"
            case .waiting: return "waiting"
            case .idle: return "idle"
            }
        }
    }

    var id: String
    var agent: String          // "claude-code" | "codex" | "cursor"
    var project: String
    var state: State
    var lastActivity: Date
    /// The id to search the process tree with. A sub-agent has no process of
    /// its own — it runs inside its parent's — so tapping its row has to look
    /// for the parent, or it finds nothing and the tap does nothing.
    var locatorId: String?
    /// Working directory, when it can be recovered — the CI card resolves the
    /// repo from it.
    var directory: String?
    /// The named sub-agent currently running inside this session, if any —
    /// "code-reviewer", "debugger". Nil means the main agent is doing the work.
    var subagent: String?
    /// What the session was last asked to do. Nil when the source has nothing
    /// to offer — a brand-new session, or a transcript we could not read.
    var task: String?

    /// How the agent is named on the row. The raw values are wire identifiers,
    /// not labels: "claude-code" reads like a package name.
    /// The name shown on the row. A running sub-agent is the more specific and
    /// more useful answer — "which agent is this?" means the persona doing the
    /// work, not the vendor.
    var displayName: String {
        if let subagent, !subagent.isEmpty { return prettify(subagent) }
        return agentName
    }

    /// "code-reviewer" → "Code Reviewer".
    private func prettify(_ slug: String) -> String {
        slug.split(whereSeparator: { $0 == "-" || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    var agentName: String {
        switch knownAgent {
        case .claudeCode: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case nil: return agent.isEmpty ? "Agent" : agent
        }
    }

    /// Trims a prompt to something that fits one notch row.
    ///
    /// Prompts arrive with wrappers the user never typed — Claude Code brackets
    /// pasted text and command output in tags — so those are stripped before
    /// truncating, otherwise every row would read "<command-name>".
    static func summarize(_ raw: String?, limit: Int = 52) -> String? {
        guard var text = raw else { return nil }
        // Whole elements go first, content included: `<command-name>/compact
        // </command-name>` is entirely machinery, and stripping only the tags
        // would leave "/compact" as the visible task. Then any stray unmatched
        // tag, then collapse the whitespace it all left behind.
        for pattern in ["(?s)<([a-zA-Z][\\w-]*)[^>]*>.*?</\\1>", "<[^>]+>", "\\s+"] {
            text = text.replacingOccurrences(of: pattern, with: " ",
                                             options: .regularExpression)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.count > limit else { return text }
        // Break on a word so the tail is not a half word.
        let cut = text.prefix(limit)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > limit / 2 {
            return String(cut[cut.startIndex..<space]) + "…"
        }
        return String(cut) + "…"
    }

    var knownAgent: DevReadyAlert.KnownAgent? {
        DevReadyAlert(title: "", agent: agent).knownAgent
    }

    /// How the row reads on the right-hand side.
    var statusLabel: String {
        switch state {
        case .working: return "working"
        case .waiting: return "waiting"
        case .idle(let since): return "idle " + Self.shortDuration(since: since)
        }
    }

    /// Compact enough for a notch row: "4m", "2h", never "2 hours ago".
    static func shortDuration(since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// Decides a session's state from when it was last written to.
    ///
    /// Separated from any file access so the thresholds can be tested directly.
    /// `working` has to be generous: an agent thinking between two tool calls
    /// writes nothing for a few seconds, and flickering a row from working to
    /// idle and back is worse than being briefly stale.
    static func state(lastWrite: Date, blocked: Bool, now: Date = Date()) -> State {
        if blocked { return .waiting }
        return now.timeIntervalSince(lastWrite) < workingWindow
            ? .working
            : .idle(since: lastWrite)
    }

    static let workingWindow: TimeInterval = 8
    /// Past this, a session is history rather than something you are "in".
    static let liveWindow: TimeInterval = 1800

    /// Newest first, but anything blocked on you floats to the top — that is the
    /// row you can actually act on.
    static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            let aw = a.state == .waiting, bw = b.state == .waiting
            if aw != bw { return aw }
            return a.lastActivity > b.lastActivity
        }
    }
}
