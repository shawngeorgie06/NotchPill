import AppKit

/// Now-playing snapshot. Equatable ignores artwork bitmap identity so that
/// unrelated artwork object churn does not register as a state change.
struct NowPlaying {
    var title: String
    var artist: String
    var isPlaying: Bool
    var artwork: NSImage?
    var elapsed: TimeInterval?
    var duration: TimeInterval?
    var playbackRate: Double = 1
    var timestamp: Date?

    var isEmpty: Bool { title.isEmpty && artist.isEmpty }

    var hasProgress: Bool {
        guard let duration, duration > 0, elapsed != nil else { return false }
        return true
    }

    /// Interpolates playback position between stream updates while playing.
    func interpolatedElapsed(at date: Date = Date()) -> TimeInterval? {
        guard let elapsed else { return nil }
        guard isPlaying, let timestamp, playbackRate > 0 else { return elapsed }
        let projected = elapsed + date.timeIntervalSince(timestamp) * playbackRate
        if let duration { return min(max(0, projected), duration) }
        return max(0, projected)
    }
}

extension NowPlaying: Equatable {
    static func == (lhs: NowPlaying, rhs: NowPlaying) -> Bool {
        lhs.title == rhs.title && lhs.artist == rhs.artist && lhs.isPlaying == rhs.isPlaying
    }
}

struct CalendarEvent: Equatable {
    var title: String
    var start: Date
    var location: String?
    var isAllDay: Bool
}

/// A transient "task finished" ping from a terminal, IDE, or automation hook.
struct DevReadyAlert: Equatable, Codable, Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    /// Host app or tool, e.g. Cursor, Terminal, Claude Code.
    var source: String?
    /// Specific agent identity, e.g. Composer, claude-opus-4, Worker 2.
    var agent: String?
    var bundleId: String?
    var kind: AlertKind = .finished
    var message: String?
    /// When the signal was written, as Unix epoch seconds. Optional: signals from
    /// older hook scripts have none, and a missing value means "unknown age",
    /// never "stale".
    var createdAt: TimeInterval?
    /// The agent's own session identifier (Claude Code's `session_id`), when the
    /// hook passes one. This is the only field that distinguishes two agent
    /// sessions running in the *same project* from the *same terminal app*.
    var sessionId: String?
    /// How this agent wants to be answered, e.g. `Yes:y|No:n|1|2|3`. See
    /// `AgentAnswer.parse`. Absent means Claude Code's set — what every hook
    /// written before this sent implicitly.
    var answerSpec: String?
    /// How an answer should reach the agent: `keystrokes` (default), `paste`, or
    /// `none` for an agent that cannot be answered from the notch at all.
    var deliverySpec: String?
    /// Identifies a blocked `PreToolUse` hook waiting on a verdict. Present only
    /// on an approval request; it names the file the hook is watching, so
    /// without it there is nowhere to send an answer.
    var requestId: String?
    /// The raw `PreToolUse` payload, so the peek can show the change itself
    /// rather than the sentence "Claude needs your permission to use Edit".
    var permissionPayload: String?
    /// What the agent last said, for the reply composer to show above the
    /// field. Set for finished peeks, where there is no question but there is
    /// still something you are replying *to*.
    var agentMessage: String?

    static let notificationName = Notification.Name("com.shawngeorgie06.NotchPill.devReady")

    /// The agent's question, when this alert is one. Single source of truth for
    /// "is there a question to show" — the peek row, the composer, and both
    /// height budgets read it, so they can't disagree about whether the space is
    /// reserved and whether anything fills it.
    var questionText: String? {
        guard kind == .waiting, let message, !message.isEmpty else { return nil }
        // The question is quoted from the agent, and for a permission request
        // it is the command it wants to run — which is exactly where a token
        // ends up on a command line. The peek floats above every window.
        return SecretRedactor.redact(message)
    }

    /// What to show above the reply field: the question when there is one,
    /// otherwise whatever the agent last said.
    ///
    /// Replying with nothing on screen means answering a question you cannot
    /// see — and a finished peek's subtitle is "finished · branch", which says
    /// an agent stopped but not what it said. Every agent gets this, not just
    /// the ones that send a `waiting` signal.
    var replyContextText: String? {
        if let questionText { return questionText }
        guard let agentMessage, !agentMessage.isEmpty else { return nil }
        return SecretRedactor.redact(agentMessage)
    }

    /// The change or command this alert is asking permission for, ready to draw.
    ///
    /// Nil unless the alert came from the `PreToolUse` hook *and* names a live
    /// request — a payload with no `requestId` has nowhere to send a verdict,
    /// and offering Allow/Deny that go nowhere is worse than not offering them.
    var permissionRequest: PermissionRequest? {
        guard kind == .waiting, requestId != nil,
              let permissionPayload,
              let request = PermissionRequest.parse(payload: Data(permissionPayload.utf8))
        else { return nil }
        return request.redacted
    }

    /// Title and subtitle as they should appear on screen. Both are carried
    /// through from hook payloads, so neither is ours to trust.
    var displayTitle: String { SecretRedactor.redact(title) }
    var displaySubtitle: String? { subtitle.map(SecretRedactor.redact) }

    /// Whether two alerts came from the same agent session.
    ///
    /// `sessionId` wins whenever both alerts carry one — it is the only key that
    /// can tell apart two agent sessions in the *same project* and the *same*
    /// terminal app, which is the ordinary case when you run several Claude Code
    /// windows on one repo. Without it, one session's question replaces the
    /// other's and either session finishing retires both.
    ///
    /// The `bundleId` + `title` (project) fallback covers signals that carry no
    /// session id: an older hook script, or anything else invoking
    /// `notify-notchpill.sh` directly. Those keep the previous behaviour rather
    /// than being treated as distinct sessions — a waiting peek that nothing can
    /// ever supersede would sit there offering to answer a question that is long
    /// gone.
    func isSameSession(as other: DevReadyAlert) -> Bool {
        if let mine = sessionId, !mine.isEmpty,
           let theirs = other.sessionId, !theirs.isEmpty {
            return mine == theirs
        }
        return bundleId == other.bundleId && title == other.title
    }

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        source: String? = nil,
        agent: String? = nil,
        bundleId: String? = nil,
        kind: AlertKind = .finished,
        message: String? = nil,
        createdAt: TimeInterval? = nil,
        sessionId: String? = nil,
        answerSpec: String? = nil,
        deliverySpec: String? = nil,
        requestId: String? = nil,
        permissionPayload: String? = nil,
        agentMessage: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.agent = agent
        self.bundleId = bundleId
        self.kind = kind
        self.message = message
        self.agentMessage = agentMessage
        self.createdAt = createdAt
        self.sessionId = Self.normalized(sessionId)
        self.answerSpec = Self.normalized(answerSpec)
        self.deliverySpec = Self.normalized(deliverySpec)
        self.requestId = Self.normalized(requestId)
        self.permissionPayload = Self.normalized(permissionPayload)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, source, agent, bundleId, kind, message, createdAt, sessionId
        case answerSpec = "answers", deliverySpec = "delivery"
        case requestId, permissionPayload = "permission"
    }

    /// Blank/whitespace-only ids are the same as absent — the shell writers omit
    /// the key entirely, but a caller passing "" must not read as a session.
    private static func normalized(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        subtitle = try? c.decode(String.self, forKey: .subtitle)
        source = try? c.decode(String.self, forKey: .source)
        agent = try? c.decode(String.self, forKey: .agent)
        bundleId = try? c.decode(String.self, forKey: .bundleId)
        kind = (try? c.decode(AlertKind.self, forKey: .kind)) ?? .finished
        message = try? c.decode(String.self, forKey: .message)
        // Tolerate a number, a numeric string, or nothing at all — a malformed
        // timestamp must never drop an alert (matching the fields above).
        createdAt = Self.epochSeconds(
            (try? c.decode(Double.self, forKey: .createdAt))
                ?? (try? c.decode(String.self, forKey: .createdAt))
        )
        sessionId = Self.normalized(try? c.decode(String.self, forKey: .sessionId))
        answerSpec = Self.normalized(try? c.decode(String.self, forKey: .answerSpec))
        deliverySpec = Self.normalized(try? c.decode(String.self, forKey: .deliverySpec))
        requestId = Self.normalized(try? c.decode(String.self, forKey: .requestId))
        permissionPayload = Self.normalized(try? c.decode(String.self, forKey: .permissionPayload))
    }

    /// Normalises a JSON `createdAt` (number or numeric string) to epoch seconds.
    /// Non-positive and unparseable values become nil = "unknown age".
    static func epochSeconds(_ raw: Any?) -> TimeInterval? {
        let value: TimeInterval?
        switch raw {
        case let d as Double: value = d
        case let i as Int: value = TimeInterval(i)
        case let s as String: value = TimeInterval(s.trimmingCharacters(in: .whitespaces))
        default: value = nil
        }
        guard let value, value > 0, value.isFinite else { return nil }
        return value
    }

    /// Age in seconds, or nil when the signal carries no usable timestamp.
    func age(at now: Date = Date()) -> TimeInterval? {
        guard let createdAt else { return nil }
        return now.timeIntervalSince1970 - createdAt
    }

    func shortAgeText(at now: Date = Date()) -> String {
        guard let age = age(at: now), age >= 0 else { return "Earlier" }
        if age < 60 { return "Now" }
        if age < 3_600 { return "\(Int(age / 60))m" }
        return "\(Int(age / 3_600))h"
    }

    /// Short label for the agent or source shown in the peek row.
    var agentLabel: String? {
        if let agent, !agent.isEmpty { return agent }
        if let source, !source.isEmpty { return source }
        return nil
    }

    var appIcon: NSImage? {
        guard let bundleId,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// Ordered applications that can safely receive a tap-to-jump request.
    /// The hook-provided bundle wins: a Codex CLI notification belongs back in
    /// its terminal, not in ChatGPT. When a hook has no host (or an older hook
    /// sent a stale host), fall back only to apps whose identity is certain.
    var jumpTargetBundleIds: [String] {
        var targets: [String] = []
        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty, !targets.contains(value) else { return }
            targets.append(value)
        }
        append(bundleId)

        let sourceName = source?.lowercased() ?? ""
        switch sourceName {
        case let value where value.contains("cmux"): append("com.cmuxterm.app")
        case let value where value.contains("cursor"): append("com.todesktop.230313mzl4w4u92")
        case let value where value.contains("iterm"): append("com.googlecode.iterm2")
        case let value where value.contains("terminal"): append("com.apple.Terminal")
        case let value where value.contains("ghostty"): append("com.mitchellh.ghostty")
        case let value where value.contains("warp"): append("dev.warp.Warp-Stable")
        default: break
        }

        switch knownAgent {
        case .codex: append("com.openai.codex") // ChatGPT desktop's bundle id.
        case .cursor: append("com.todesktop.230313mzl4w4u92")
        default: break
        }
        return targets
    }

    var canJumpToSource: Bool { !jumpTargetBundleIds.isEmpty }

    /// Which agent this alert came from, when it is one we recognise.
    enum KnownAgent { case claudeCode, codex, cursor, openCode }
    var knownAgent: KnownAgent? {
        switch (agent ?? source ?? "").lowercased() {
        case "claude-code", "claude", "claude code": return .claudeCode
        case "codex", "openai-codex": return .codex
        case "cursor", "composer": return .cursor
        case "opencode", "open-code": return .openCode
        default: return nil
        }
    }

    /// Which app the peek should *present* as, which is not always the agent
    /// that produced it.
    ///
    /// Cursor runs Claude Code as a backend. Finish a task in Cursor and the
    /// Claude Code hook fires, carrying `agent=claude-code` with `source=cursor`
    /// — both true, and shown side by side they read as two different agents
    /// arguing about who did the work. You did it in Cursor; that is the window
    /// you would switch back to, so that is what it is called and whose icon it
    /// wears. The engine stays visible, just not in the lead.
    ///
    /// Kept separate from `knownAgent` on purpose: that one decides *behaviour*
    /// (whether typed answers can reach it), which still depends on the agent
    /// rather than on the window it happens to be hosted in.
    var displayAgent: KnownAgent? {
        if let host = source?.lowercased(), host.contains("cursor") { return .cursor }
        return knownAgent
    }

    /// The name to lead with, and the one to keep as a footnote. Nil second
    /// element when there is nothing distinct left to say.
    var displayIdentity: (lead: String, secondary: String?) {
        let agentName = agent?.trimmingCharacters(in: .whitespaces)
        let hostName = source?.trimmingCharacters(in: .whitespaces)
        // Host in the lead only when it is a recognised app that is genuinely
        // hosting a different agent — otherwise the agent's own name is best.
        if displayAgent == .cursor, knownAgent != .cursor,
           let hostName, !hostName.isEmpty {
            return (hostName, agentName)
        }
        if let agentName, !agentName.isEmpty {
            let second = (hostName?.caseInsensitiveCompare(agentName) == .orderedSame)
                ? nil : hostName
            return (agentName, second?.isEmpty == true ? nil : second)
        }
        return (hostName ?? "agent", nil)
    }

    /// Whether an answer typed at this alert would actually reach the agent.
    ///
    /// Delivery is synthetic key events posted to the target app's frontmost
    /// window (`TerminalReplyInjector`), which only means anything when that
    /// window is a terminal running a TUI that reads keypresses — and when the
    /// keys we send are the ones that agent's prompt expects.
    ///
    /// - Claude Code: yes. The Yes/No/1/2/3 set is its permission prompt, and it
    ///   runs in a terminal.
    /// - Codex: no. It has its own approval keymap (`approval.approve_for_session`,
    ///   `approval.deny`, …), so those keys are wrong, and in the desktop app
    ///   there is no TUI to type into at all.
    /// - Cursor: no. A GUI app — keystrokes land in whatever holds focus, which
    ///   may be the editor rather than the chat box.
    ///
    /// Unrecognised producers keep the previous behaviour: someone wiring their
    /// own terminal agent to `notify-notchpill.sh` opted in by sending
    /// `kind=waiting`, and silently dropping their buttons would be a regression.
    ///
    /// A signal that *declares* how to answer it overrides all of this — the
    /// guesswork above only exists for hooks that say nothing.
    var supportsTypedAnswers: Bool {
        if deliverySpec?.lowercased() == "none" { return false }
        if AgentAnswer.parse(answerSpec) != nil { return true }
        switch knownAgent {
        case .claudeCode, nil: return true
        // OpenCode's prompt format is unknown to us, and buttons that send the
        // wrong keys are worse than no buttons — the same reason Codex and
        // Cursor are excluded. A signal that declares its own answers still
        // wins above.
        case .codex, .cursor, .openCode: return false
        }
    }

    /// Whether the row should draw answer buttons at all.
    ///
    /// Lives here rather than in the view because the height budget has to make
    /// the identical decision — when the two disagreed, the peek reserved space
    /// for buttons it never drew, or drew them into space it never reserved.
    @MainActor
    func canAnswerFromNotch(replyEnabled: Bool) -> Bool {
        guard replyEnabled, supportsTypedAnswers else { return false }
        // A stale question is not a live one: its answer would land somewhere
        // that has long since moved on.
        guard DevReadyProvider.demotingStaleWaiting(self).kind == kind else { return false }
        // A verdict goes to a waiting hook, so there is no terminal to target
        // and nothing to type — the one path that needs no window at all.
        // Permission prompts (Allow/Deny) and plan reviews (Approve/Revise)
        // keep their buttons: they are a decision the notch exists to collect.
        if answersByDecision { return true }
        // The generic quick-answer capsules — Yes / No / 1 / 2 / 3 — are gone
        // by request. They guessed at an agent's options from a signal, and
        // guessing wrong put a wrong keystroke into someone's terminal. The ↰
        // composer answers the same prompts without guessing.
        return false
    }

    /// Apps that host a terminal, and so can receive a pasted reply.
    ///
    /// Membership is about the *window*, not the agent: whatever CLI is running
    /// inside, a bracketed paste followed by Return reaches its prompt. This is
    /// why it is a separate question from `supportsTypedAnswers`, which asks
    /// whether a specific agent's *keymap* matches the buttons we would draw.
    static let terminalHostBundleIds: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "dev.warp.Warp",
        "com.cmuxterm.app",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
        "com.raphaelamorim.rio",
    ]

    /// Whether a **free-text** reply typed in the notch would reach this agent.
    ///
    /// Deliberately a looser test than `supportsTypedAnswers`. That one gates
    /// the quick-answer capsules, which fire specific keys at a specific prompt
    /// — send Claude Code's `y` at Codex's approval keymap and you press the
    /// wrong thing. A free-text reply has no such problem: it is a bracketed
    /// paste plus Return, which every terminal-hosted CLI routes to its input
    /// box, Codex and OpenCode included.
    ///
    /// Conflating the two is why a finished Codex peek had no reply button at
    /// all. The exclusion that belongs to the *buttons* silently took the
    /// composer with it, so the one thing you actually wanted to do from a
    /// finished notification — say the next thing — was unreachable.
    ///
    /// Still excluded, and for the original reasons:
    /// - **Cursor** and the **ChatGPT/Codex desktop app**: GUI windows with no
    ///   TUI. Keystrokes land in whatever view holds focus, which may be the
    ///   editor rather than the chat box.
    /// - Any signal that declared `delivery=none`.
    var supportsTypedReply: Bool {
        if deliverySpec?.lowercased() == "none" { return false }
        if let bundleId = bundleId?.trimmingCharacters(in: .whitespaces),
           Self.terminalHostBundleIds.contains(bundleId) {
            return true
        }
        // No recognised terminal host. Fall back to what we know about the
        // agent, which is what decided this before terminals were considered.
        return supportsTypedAnswers
    }

    /// Whether the row should draw the reply (↰) control.
    ///
    /// Same shape as `canAnswerFromNotch` and for the same reason — the view and
    /// the width budget must not disagree — but it never short-circuits on
    /// `answersByDecision`: a verdict unblocks the hook without a window, while
    /// a typed reply has nowhere to go without one.
    @MainActor
    func canReplyFromNotch(replyEnabled: Bool) -> Bool {
        guard replyEnabled, supportsTypedReply else { return false }
        guard DevReadyProvider.demotingStaleWaiting(self).kind == kind else { return false }
        return TerminalReplyInjector.canTarget(self)
    }

    /// The buttons to offer. Declared by the signal, else Claude Code's set.
    var answers: [AgentAnswer] {
        AgentAnswer.parse(answerSpec) ?? AgentAnswer.standardSet
    }

    /// How to deliver an answer. Keystrokes by default: a permission prompt in a
    /// TUI selects on keypress, and a clipboard paste arrives as a bracketed
    /// paste, which such a prompt routes to its text field instead.
    var answerDelivery: TerminalReplyInjector.Delivery {
        deliverySpec?.lowercased() == "paste" ? .paste : .keystrokes
    }

    /// Whether this alert is answered by handing a verdict to a blocked hook
    /// rather than by typing into a terminal. Requires a `requestId`, because
    /// that names the file the hook is watching — a `decision` delivery without
    /// one would silently answer nothing.
    var answersByDecision: Bool {
        deliverySpec?.lowercased() == "decision" && requestId != nil
    }

    /// Icon of the *agent's own* app, preferred over the host terminal's: the
    /// row already carries a badge naming the terminal, so showing its icon too
    /// spends the only graphical slot on the least distinguishing fact. Nil when
    /// the agent has no app installed — Claude Code is usually a CLI with no
    /// bundle to look up, which is what `ClaudeMark` draws instead.
    var agentAppIcon: NSImage? {
        let candidates: [String]
        switch displayAgent {
        case .claudeCode: candidates = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: candidates = ["com.openai.codex", "com.openai.chat"]
        // Cursor pings already carry Cursor's own bundle id, so `appIcon` covers
        // it — no need to look the app up a second time here.
        // OpenCode is a CLI with no app bundle to look up.
        case .cursor, .openCode, nil: return nil
        }
        for id in candidates {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
        }
        return nil
    }

    static func parse(from data: Data) -> DevReadyAlert? {
        guard var alert = try? JSONDecoder().decode(DevReadyAlert.self, from: data) else { return nil }
        if alert.id.isEmpty { alert.id = UUID().uuidString }
        guard !alert.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return alert
    }

    static func parse(userInfo: [AnyHashable: Any]) -> DevReadyAlert? {
        let title = (userInfo["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty else { return nil }
        let id = (userInfo["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let kindRaw = userInfo["kind"] as? String
        return DevReadyAlert(
            id: (id?.isEmpty == false) ? id! : UUID().uuidString,
            title: title,
            subtitle: userInfo["subtitle"] as? String,
            source: userInfo["source"] as? String,
            agent: userInfo["agent"] as? String,
            bundleId: userInfo["bundleId"] as? String,
            kind: AlertKind(rawValue: kindRaw ?? "") ?? .finished,
            message: userInfo["message"] as? String,
            createdAt: epochSeconds(userInfo["createdAt"]),
            sessionId: userInfo["sessionId"] as? String,
            answerSpec: userInfo["answers"] as? String,
            deliverySpec: userInfo["delivery"] as? String,
            requestId: userInfo["requestId"] as? String,
            permissionPayload: userInfo["permission"] as? String
        )
    }
}

/// Whether an agent alert is a completed task (finished) or a pending question (waiting).
enum AlertKind: String, Codable { case finished, waiting }

extension DevReadyAlert {
    /// Orders a burst of activity into the one thing that merits attention
    /// first, followed by the quiet backlog. A blocked agent always outranks a
    /// completion notification; among equal kinds, the newest event wins.
    static func focusOrdered(_ alerts: [DevReadyAlert]) -> [DevReadyAlert] {
        alerts.sorted { lhs, rhs in
            let lhsPriority = lhs.kind == .waiting ? 0 : 1
            let rhsPriority = rhs.kind == .waiting ? 0 : 1
            if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
            return (lhs.createdAt ?? 0) > (rhs.createdAt ?? 0)
        }
    }
}

extension Notification.Name {
    static let notchPillTestDevReady = Notification.Name("com.shawngeorgie06.NotchPill.testDevReady")
    static let notchPillTestMultipleDevReady = Notification.Name("com.shawngeorgie06.NotchPill.testMultipleDevReady")
}

/// Compact chip shown in the collapsed pill preview.
enum CollapsedChip: Equatable, Identifiable {
    case media(NowPlaying)
    case calendar(CalendarEvent)
    case shelf(count: Int)
    case appSwitch(String)
    case timer(ActiveTimer)
    case systemStats(SystemStats)
    case battery(BatteryStatus)
    case agent(name: String, state: String, count: Int)
    case clock

    var id: String {
        switch self {
        case .media(let np): return "media-\(np.title)-\(np.artist)"
        case .calendar(let e): return "cal-\(e.title)-\(e.start.timeIntervalSince1970)"
        case .shelf(let count): return "shelf-\(count)"
        case .appSwitch(let name): return "app-\(name)"
        case .timer(let t): return "timer-\(t.endDate.timeIntervalSince1970)"
        case .systemStats(let s): return "stats-\(s.cpuPercent)-\(s.memoryPercent)"
        case .battery(let b): return "battery-\(b.level)-\(b.isCharging)"
        case .agent(let name, let state, let count): return "agent-\(name)-\(state)-\(count)"
        case .clock: return "clock"
        }
    }
}

/// Live activity shown in the expanded pill (status cards, not utility panels).
enum ExpandedActivity: Equatable, Identifiable {
    case media(NowPlaying)
    case appSwitch(String)
    case activeApp(name: String)
    case volume(Int)
    case clock
    case calendar(CalendarEvent)
    case timer(ActiveTimer)
    case systemStats(SystemStats)
    case battery(BatteryStatus)
    case shelf(count: Int, names: [String])
    case agents([AgentSession])
    case openCodeUsage(OpenCodeUsage)
    case codexQuota(CodexQuota)
    case claudeQuota(ClaudeQuota)
    case cursorQuota(CursorQuota)
    case ci([CIRun])
    case recentAlerts([DevReadyAlert])

    /// Stable identity for the *kind* of card, unlike `id`, which changes with
    /// the content. Weights are stored against this.
    var kind: String {
        switch self {
        case .media: return "media"
        case .appSwitch, .activeApp: return "activeApp"
        case .volume: return "volume"
        case .clock: return "clock"
        case .calendar: return "calendar"
        case .timer: return "timer"
        case .systemStats: return "systemStats"
        case .battery: return "battery"
        case .shelf: return "shelf"
        case .agents: return "agents"
        case .openCodeUsage: return "openCodeUsage"
        case .codexQuota: return "codexQuota"
        case .claudeQuota: return "claudeQuota"
        case .cursorQuota: return "cursorQuota"
        case .ci: return "ci"
        case .recentAlerts: return "recentAlerts"
        }
    }

    /// Human label for the settings row.
    var kindLabel: String {
        switch self {
        case .media: return "Now playing"
        case .appSwitch, .activeApp: return "Active app"
        case .volume: return "Volume"
        case .clock: return "Clock"
        case .calendar: return "Calendar"
        case .timer: return "Timer"
        case .systemStats: return "CPU & memory"
        case .battery: return "Battery"
        case .shelf: return "File shelf"
        case .agents: return "Live agents"
        case .openCodeUsage: return "OpenCode usage"
        case .codexQuota: return "Codex quota"
        case .claudeQuota: return "Claude quota"
        case .cursorQuota: return "Cursor quota"
        case .ci: return "CI status"
        case .recentAlerts: return "Recent activity"
        }
    }

    var id: String {
        switch self {
        case .media(let np): return "media-\(np.title)-\(np.artist)-\(np.isPlaying)"
        case .appSwitch(let name): return "switch-\(name)"
        case .activeApp(let name): return "app-\(name)"
        case .volume(let level): return "vol-\(level)"
        case .clock: return "clock"
        case .calendar(let e): return "cal-\(e.title)-\(e.start.timeIntervalSince1970)"
        case .timer(let t): return "timer-\(t.endDate.timeIntervalSince1970)"
        case .systemStats(let s): return "stats-\(s.cpuPercent)-\(s.memoryPercent)"
        case .battery(let b): return "battery-\(b.level)-\(b.isCharging)"
        case .shelf(let count, _): return "shelf-\(count)"
        case .agents(let list): return "agents-" + list.map(\.id).joined(separator: ",")
        case .openCodeUsage(let usage): return "opencode-\(usage.totalTokens)-\(usage.cost)"
        case .codexQuota(let quota): return "codex-quota-\(quota.usedPercent)-\(quota.resetsAt?.timeIntervalSince1970 ?? 0)-\(quota.creditBalance?.description ?? "")-\(quota.updatedAt?.timeIntervalSince1970 ?? 0)"
        case .claudeQuota(let quota): return "claude-quota-\(quota.sessionPercent)-\(quota.weeklyPercent)-\(quota.extraSpentMinor ?? -1)-\(quota.updatedAt?.timeIntervalSince1970 ?? 0)"
        case .cursorQuota(let quota): return "cursor-quota-\(quota.used)-\(quota.limit)-\(quota.percentUsed)-\(quota.updatedAt?.timeIntervalSince1970 ?? 0)"
        case .ci(let runs): return "ci-" + runs.map { $0.id + $0.statusLabel }.joined(separator: ",")
        case .recentAlerts(let alerts): return "recent-" + alerts.map(\.id).joined(separator: ",")
        }
    }
}

/// What the collapsed notch is presenting right now. Resolved by the single
/// state manager from priority + debounce logic.
enum NotchActivity: Equatable {
    case idle
    case media(NowPlaying)
    case appSwitch(String)

    var priority: Int {
        switch self {
        // A frontmost-app switch is transient and briefly overrides media so the
        // switch is visible as a crossfade, then reverts to media/idle.
        case .appSwitch: return 3
        case .media: return 2
        case .idle: return 0
        }
    }

    /// Stable identity used to key SwiftUI crossfade transitions.
    var transitionKey: String {
        switch self {
        case .idle: return "idle"
        case .media: return "media"
        case .appSwitch: return "appSwitch"
        }
    }
}
