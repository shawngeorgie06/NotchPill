import Foundation

/// The latest concrete action an agent wrote to its local transcript.
struct AgentToolActivity: Equatable {
    var tool: String
    var detail: String?

    var displayText: String {
        guard let detail, !detail.isEmpty else { return tool }
        return "\(tool) · \(detail)"
    }
}

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
    var agent: String          // "claude-code" | "codex" | "cursor" | "opencode"
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
    /// Latest Read/Edit/Write/Bash-style action, when the transcript exposes it.
    var toolActivity: AgentToolActivity?

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
        case .openCode: return "OpenCode"
        case nil: return agent.isEmpty ? "Agent" : agent
        }
    }

    /// A glyph for the vendor, because nothing else on the row reliably says
    /// which one it is.
    ///
    /// Colour cannot: it is spoken for by state — orange is "waiting on you",
    /// not a brand — and that is read as branding often enough to be worth
    /// designing against. The name cannot either: `displayName` shows the
    /// persona for a sub-agent, so "Code Reviewer" appears with the vendor
    /// nowhere on the row at all.
    ///
    /// Nil for an agent we do not know, rather than a stand-in glyph: a
    /// wrong-but-confident mark is worse than none, and the name still shows.
    var vendorSymbol: String? {
        switch knownAgent {
        case .claudeCode: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .openCode: return "curlybraces"
        case nil: return nil
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
        // Before truncation, so a token cannot survive by being cut in half:
        // the card shows whatever you typed, and people paste credentials to
        // their agents.
        text = SecretRedactor.redact(text)
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

    /// The task line is phrased as an activity, so the card answers the human
    /// question — “what is it doing?” — rather than reading like transcript
    /// metadata. The actual task text remains the source of truth.
    var taskLeadIn: String {
        switch state {
        case .working: return "Working on"
        case .waiting: return "Needs your reply about"
        case .idle: return "Last worked on"
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

    /// Eight seconds was measured against an agent writing steadily, which is
    /// the easy case. An agent running a build, a test suite, or any tool call
    /// longer than a breath writes nothing while it works — so the card called
    /// four busy agents "idle 4m" and was believed, because that is what it
    /// said. A tool call is the unit here, not a keystroke.
    static let workingWindow: TimeInterval = 45
    /// Past this, a session is history rather than something you are "in".
    ///
    /// Thirty minutes sounds generous until an agent sits on one long task, or
    /// waits on a permission prompt nobody has answered: it writes nothing, and
    /// the row did not go stale — it disappeared, while the agent was still
    /// running. Two hours costs a few extra rows, sorted below the live ones,
    /// and they age visibly. Silently dropping a running agent is the worse
    /// failure.
    static let liveWindow: TimeInterval = 7200

    /// How long a *quiet* session stays on the card.
    ///
    /// `liveWindow` is two hours because an agent blocked on a permission prompt
    /// writes nothing, and dropping one that is still running is the worse
    /// failure. But that generosity was applied to every session, so a card that
    /// should have said "one agent working" said "7 agents" — six of them idle
    /// for a quarter of an hour, occupying the row you actually wanted to read.
    ///
    /// So the long window is spent only where it was earned: on sessions that
    /// are working or blocked on you. A session that is merely quiet is history
    /// after five minutes, and comes straight back the moment it writes again.
    static let idleWindow: TimeInterval = 300

    /// Drops quiet sessions that have stopped being news. Working and waiting
    /// sessions are kept whatever their age — a long build and an unanswered
    /// question are both exactly what the card is for.
    static func current(_ sessions: [AgentSession], now: Date = Date()) -> [AgentSession] {
        sessions.filter { session in
            guard case .idle(let since) = session.state else { return true }
            return now.timeIntervalSince(since) < idleWindow
        }
    }

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

/// OpenCode's locally recorded activity for the current day.
///
/// This is intentionally usage, not a quota estimate: the database records
/// tokens and cost per session but carries no provider allowance or reset time.
struct OpenCodeUsage: Equatable {
    var inputTokens: Int64
    var outputTokens: Int64
    var reasoningTokens: Int64
    var cacheReadTokens: Int64
    var cacheWriteTokens: Int64
    var cost: Double

    var totalTokens: Int64 {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheWriteTokens
    }

    var hasActivity: Bool { totalTokens > 0 || cost > 0 }

    var tokenLabel: String { Self.compact(totalTokens) + " tokens" }

    var costLabel: String {
        cost == 0 ? "No cost" : cost.formatted(.currency(code: "USD"))
    }

    private static func compact(_ value: Int64) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }
}

/// The rate-limit signal written locally by Codex desktop. Unlike a token total,
/// this is the provider's own current-window percentage and reset timestamp.
struct CodexQuota: Equatable {
    var usedPercent: Int
    var resetsAt: Date?
    /// Opaque balance recorded by Codex desktop for credit-backed plans.
    var creditBalance: Decimal?

    var remainingPercent: Int { max(0, 100 - usedPercent) }
    var usageLabel: String { "\(usedPercent)% used" }

    var resetLabel: String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = max(0, Int(resetsAt.timeIntervalSinceNow))
        if seconds < 3600 { return "Resets in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "Resets in \(seconds / 3600)h" }
        return "Resets in \(seconds / 86_400)d"
    }

    var creditsLabel: String? {
        guard let creditBalance else { return nil }
        let value = NSDecimalNumber(decimal: creditBalance).doubleValue
        let compact: String
        if value >= 1_000 {
            compact = String(format: "%.1fk", value / 1_000)
        } else {
            compact = creditBalance.formatted(.number.precision(.fractionLength(0...2)))
        }
        return compact + " credits"
    }
}
