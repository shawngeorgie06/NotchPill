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
        /// terminal agents it arrives via the waiting peek. `since` is when the
        /// block was first recorded, so the row can say how long it has been
        /// sitting there — nil when that moment isn't known.
        case waiting(since: Date?)
        /// Alive but quiet. `since` is when it went quiet, so the row can age.
        case idle(since: Date)
        /// A turn ended. Unlike `.idle`, this is an explicit completion signal,
        /// so it remains in the session card as recent history rather than
        /// pretending the agent is still running.
        case completed(since: Date)

        /// Name without the payload — for logging, where the timestamp inside
        /// `.idle` would make every entry look different.
        var name: String {
            switch self {
            case .working: return "working"
            case .waiting: return "waiting"
            case .idle: return "idle"
            case .completed: return "completed"
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
    /// The host terminal's own name for this session, when it has one —
    /// cmux auto-names every session after the work it is doing. Nothing in a
    /// transcript carries this: the agent does not name itself.
    var sessionTitle: String?
    /// The host terminal's stable id for the pane this runs in, so a tap can
    /// focus that exact pane instead of matching on a directory two sessions
    /// might share.
    var hostPaneId: String?
    /// Whether the agent's process is still alive, when the host terminal
    /// recorded a pid to ask about.
    ///
    /// Nil means unknown, not dead — Codex, Cursor, and anything launched
    /// outside cmux have no runtime record, and judging those dead would empty
    /// the card. Only a definite `false` retires a row early.
    var isAlive: Bool?

    /// How the agent is named on the row. The raw values are wire identifiers,
    /// not labels: "claude-code" reads like a package name.
    ///
    /// Most specific answer wins. A running sub-agent is the most specific —
    /// "which agent is this?" means the persona doing the work. Failing that,
    /// the terminal's name for the session says what it is *about*, which beats
    /// the vendor: three sessions in one repo used to be three rows all reading
    /// "Claude", distinguishable only by a task line that is often missing.
    var displayName: String {
        if let subagent, !subagent.isEmpty { return prettify(subagent) }
        if let sessionTitle, !sessionTitle.isEmpty { return sessionTitle }
        return agentName
    }

    /// "code-reviewer" → "Code Reviewer".
    private func prettify(_ slug: String) -> String {
        AgentSession.prettifyAgentType(slug)
    }

    /// Shared with the peek path, which names a finishing sub-agent the same
    /// way the row does — the two must agree or the same agent reads as two
    /// different things depending on where you saw it.
    nonisolated static func prettifyAgentType(_ slug: String) -> String {
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

    /// The compact context beside the agent name. Generated workspaces such as
    /// `w` identify a folder, not the work, so showing them in the notch is
    /// actively misleading. In that case the request is the useful context;
    /// when even that is unavailable, omit the label rather than inventing one.
    var displayContext: String? {
        let cleanedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let generatedWorkspaceNames = ["w", "tmp", "work"]
        if !cleanedProject.isEmpty,
           !generatedWorkspaceNames.contains(cleanedProject.lowercased()) {
            return cleanedProject
        }
        return task?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw model id the session is running, as its transcript reported it —
    /// `claude-opus-5`, `gpt-5.6-terra`. Nil before the first response.
    var model: String?
    /// Reasoning effort, where the agent records one: `low`, `medium`, `high`.
    var effort: String?
    /// Live context size in tokens: everything the next request will carry —
    /// prompt plus cache. The number people actually want from a running
    /// session, because it is the one that ends it: a session near the window
    /// is about to compact and lose the thread.
    var contextTokens: Int?
    /// When the session's transcript was first written. Approximate by design —
    /// it answers "have I been at this for twenty minutes or three hours",
    /// which does not need to be exact.
    var startedAt: Date?

    /// "132k", "1.2M" — a raw 132460 in a notch row is unreadable.
    static func compactTokens(_ tokens: Int) -> String {
        if tokens < 1000 { return "\(tokens)" }
        if tokens < 1_000_000 {
            let k = Double(tokens) / 1000
            return k < 10 ? String(format: "%.1fk", k) : "\(Int(k.rounded()))k"
        }
        return String(format: "%.1fM", Double(tokens) / 1_000_000)
    }

    var contextLabel: String? {
        guard let contextTokens, contextTokens > 0 else { return nil }
        return Self.compactTokens(contextTokens) + " ctx"
    }

    var runtimeLabel: String? {
        guard let startedAt else { return nil }
        // Under a minute is noise: every session passes through it, and "0m"
        // says less than nothing.
        guard Date().timeIntervalSince(startedAt) >= 60 else { return nil }
        return "running " + Self.shortDuration(since: startedAt)
    }

    /// The model as it should read on a notch row.
    ///
    /// Vendor prefixes and date stamps are stripped: the row already says which
    /// tool this is, and `claude-haiku-4-5-20251001` spends most of its width
    /// on a build date nobody is choosing between. The remaining variant is
    /// kept: `gpt-5.6-terra` is a different choice from another 5.6 variant,
    /// and hiding that final word made the live card materially less useful.
    ///
    /// Unknown ids pass through cleaned rather than dropped. A model we have
    /// never seen is exactly the one worth naming, and printing it verbatim is
    /// honest in a way that a guess or a blank would not be.
    static func modelLabel(_ raw: String?) -> String? {
        guard var id = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !id.isEmpty, id != "<synthetic>" else { return nil }
        for prefix in ["claude-", "openai-", "anthropic."] where id.hasPrefix(prefix) {
            id = String(id.dropFirst(prefix.count))
        }
        var parts = id.split(separator: "-").map(String.init)
        // Trailing 8-digit build stamp, e.g. …-4-5-20251001.
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        guard let family = parts.first, !family.isEmpty else { return nil }

        // Families we can shorten confidently. Anything else keeps its full id
        // rather than being trimmed down to a word: `gpt-5.6-terra` reduced to
        // its first segment reads "Gpt", which has thrown away the only part
        // that distinguishes it.
        let known = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku",
                     "gpt": "GPT", "o1": "o1", "o3": "o3",
                     "gemini": "Gemini", "grok": "Grok", "llama": "Llama"]
        guard let name = known[family] else { return id }

        // A version segment starts with a digit, so "5", "4" and "5.6" all
        // count while codenames like "terra" do not. Numeric-only segments
        // rejoin with dots: ["4", "8"] → "4.8". Everything after that is a
        // model variant, not disposable metadata — e.g. 5.6 Terra.
        let remaining = Array(parts.dropFirst())
        let versionParts = remaining.prefix { $0.first?.isNumber == true }
        let version = versionParts.joined(separator: ".")
        let variant = remaining.dropFirst(versionParts.count)
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
        return [name, version, variant].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// `GPT 5.6 Terra · medium`. The reasoning effort is part of the active
    /// Codex configuration, including `medium`: omitting the default made two
    /// otherwise identical live sessions impossible to distinguish at a glance.
    var modelLabel: String? {
        guard let base = Self.modelLabel(model) else { return nil }
        guard let effort = effort?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !effort.isEmpty, effort != "default" else { return base }
        return "\(base) · \(effort)"
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

    /// Where to jump when the session cannot be placed in the process tree.
    ///
    /// `AgentSessionLocator` finds a terminal agent by looking for a process
    /// whose arguments contain the session id. That works for CLI agents —
    /// `claude --resume <id>`, `codex` in a terminal — and not at all for
    /// desktop apps, which run one process for every conversation:
    ///
    ///     /Applications/ChatGPT.app/Contents/Resources/codex … app-server
    ///
    /// No session id, so nothing to walk up from. Only Cursor had a fallback,
    /// so tapping a desktop Codex row returned false and did nothing at all.
    ///
    /// The app is the honest ceiling here. Neither Cursor nor the ChatGPT
    /// desktop app exposes a way to select one conversation, so this brings the
    /// app forward and stops — better than the tap doing nothing, and it does
    /// not pretend to more precision than exists.
    var fallbackAppBundleIds: [String] {
        switch knownAgent {
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        // Claude Code and OpenCode are CLIs. They have no app of their own to
        // fall back to, and guessing a terminal would send you to the wrong
        // window as often as the right one.
        case .claudeCode, .openCode, nil: return []
        }
    }

    /// How the row reads on the right-hand side.
    var isWaiting: Bool { if case .waiting = state { return true }; return false }

    var isCompleted: Bool { if case .completed = state { return true }; return false }

    var statusLabel: String {
        switch state {
        case .working: return "working"
        // How long it has been blocked on you is the whole point of the row:
        // "waiting" alone reads the same at ten seconds and forty minutes.
        case .waiting(let since):
            guard let since else { return "waiting" }
            return "waiting " + Self.shortDuration(since: since)
        case .idle(let since): return "idle " + Self.shortDuration(since: since)
        case .completed(let since): return "completed " + Self.shortDuration(since: since)
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
        case .completed: return "Completed"
        }
    }

    /// Compact enough for a notch row: "4m", "2h", never "2 hours ago".
    static func shortDuration(since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        // Days past two of them. Idle rows never get here (they expire at two
        // hours), but a session resumed across a fortnight does, and it read
        // "running 334h".
        if s < 172_800 { return "\(s / 3600)h" }
        return "\(s / 86_400)d"
    }

    /// Decides a session's state from when it was last written to.
    ///
    /// Separated from any file access so the thresholds can be tested directly.
    /// `working` has to be generous: an agent thinking between two tool calls
    /// writes nothing for a few seconds, and flickering a row from working to
    /// idle and back is worse than being briefly stale.
    static func state(lastWrite: Date, blocked: Bool, blockedSince: Date? = nil,
                      now: Date = Date()) -> State {
        if blocked { return .waiting(since: blockedSince) }
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
    /// almost immediately, and comes straight back the moment it writes again.
    ///
    /// Thirty seconds by request. Note what this does *not* change: a session
    /// still counts as working for `workingWindow`, so a row leaves about
    /// three quarters of a minute after the last write rather than exactly
    /// thirty seconds. Making the two equal would drop an agent in the middle
    /// of a long build, which is the failure `workingWindow` exists to prevent.
    static let idleWindow: TimeInterval = 30

    /// Drops quiet sessions that have stopped being news. Working and waiting
    /// sessions are kept whatever their age — a long build and an unanswered
    /// question are both exactly what the card is for.
    ///
    /// Where the process is known, it overrules the clock in both directions.
    /// A dead agent goes immediately, however recently it wrote: closing a
    /// terminal used to leave a row insisting the agent was "working" for the
    /// next forty-five seconds. A living one keeps the long window even while
    /// quiet, because the thirty-second rule was only ever a guess at whether
    /// it was still there, and now we know.
    static func current(_ sessions: [AgentSession], now: Date = Date()) -> [AgentSession] {
        sessions.filter { session in
            if session.isAlive == false { return false }
            guard case .idle(let since) = session.state else { return true }
            let window = session.isAlive == true ? liveWindow : idleWindow
            return now.timeIntervalSince(since) < window
        }
    }

    /// Newest first, but anything blocked on you floats to the top — that is the
    /// row you can actually act on.
    static func ordered(_ sessions: [AgentSession]) -> [AgentSession] {
        sessions.sorted { a, b in
            let ar = stateRank(a.state), br = stateRank(b.state)
            if ar != br { return ar < br }
            return a.lastActivity > b.lastActivity
        }
    }

    /// The card has two evidence streams: transcripts tell us what is alive;
    /// peeks tell us a turn completed or is blocked on a question. Keep the
    /// streams separate until this boundary, then reconcile them by session id.
    /// A newer transcript wins over an older completion, while a waiting prompt
    /// wins immediately because it is actionable and may not be in a transcript
    /// yet.
    static func displaySessions(live: [AgentSession],
                                waitingAlerts: [DevReadyAlert],
                                completedAlerts: [DevReadyAlert]) -> [AgentSession] {
        // A provider can briefly report the same session through two discovery
        // paths while an app is moving its transcript. Prefer the newer one;
        // never let a duplicate id turn a dashboard refresh into a crash.
        var byID: [String: AgentSession] = [:]
        for session in live {
            guard (byID[session.id]?.lastActivity ?? .distantPast) < session.lastActivity else {
                continue
            }
            byID[session.id] = session
        }
        var extras: [AgentSession] = []

        for alert in completedAlerts where isAgentAlert(alert) {
            let session = session(for: alert, state: .completed(since: alert.date))
            if let existing = byID[session.id] {
                // A transcript written after the completion means the agent has
                // started another turn; it is more current than the old event.
                if existing.lastActivity <= session.lastActivity { byID[session.id] = session }
            } else {
                extras.append(session)
            }
        }
        for alert in waitingAlerts where alert.kind == .waiting && isAgentAlert(alert) {
            let session = session(for: alert, state: .waiting(since: alert.date))
            if var existing = byID[session.id] {
                existing.state = session.state
                existing.lastActivity = max(existing.lastActivity, session.lastActivity)
                byID[session.id] = existing
            } else if let index = extras.firstIndex(where: { $0.id == session.id }) {
                extras[index] = session
            } else {
                extras.append(session)
            }
        }
        return ordered(Array(byID.values) + extras)
    }

    private static func stateRank(_ state: State) -> Int {
        switch state {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .completed: return 3
        }
    }

    private static func isAgentAlert(_ alert: DevReadyAlert) -> Bool {
        alert.knownAgent != nil || !(alert.agent ?? "").isEmpty
    }

    private static func session(for alert: DevReadyAlert, state: State) -> AgentSession {
        let date = alert.date
        let agent: String
        switch alert.knownAgent {
        case .claudeCode: agent = "claude-code"
        case .codex: agent = "codex"
        case .cursor: agent = "cursor"
        case .openCode: agent = "opencode"
        case nil: agent = alert.agent ?? "agent"
        }
        return AgentSession(
            id: alert.sessionId ?? "alert-\(alert.id)", agent: agent,
            project: alert.displayTitle, state: state, lastActivity: date,
            locatorId: alert.sessionId, directory: nil, subagent: nil,
            task: summarize(alert.agentMessage ?? alert.message), toolActivity: nil)
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
    var updatedAt: Date?

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
        return creditBalance.formatted(.number.precision(.fractionLength(0...2))) + " credits balance"
    }

    var updatedLabel: String? {
        guard let updatedAt else { return nil }
        let seconds = max(0, Int(Date().timeIntervalSince(updatedAt)))
        if seconds < 10 { return "Updated now" }
        if seconds < 60 { return "Updated \(seconds)s ago" }
        return "Updated \(seconds / 60)m ago"
    }
}
