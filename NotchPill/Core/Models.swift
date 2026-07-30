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
        deliverySpec: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.agent = agent
        self.bundleId = bundleId
        self.kind = kind
        self.message = message
        self.createdAt = createdAt
        self.sessionId = Self.normalized(sessionId)
        self.answerSpec = Self.normalized(answerSpec)
        self.deliverySpec = Self.normalized(deliverySpec)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, source, agent, bundleId, kind, message, createdAt, sessionId
        case answerSpec = "answers", deliverySpec = "delivery"
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

    /// Which agent this alert came from, when it is one we recognise.
    enum KnownAgent { case claudeCode, codex, cursor }
    var knownAgent: KnownAgent? {
        switch (agent ?? source ?? "").lowercased() {
        case "claude-code", "claude", "claude code": return .claudeCode
        case "codex", "openai-codex": return .codex
        case "cursor", "composer": return .cursor
        default: return nil
        }
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
        case .codex, .cursor: return false
        }
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

    /// Icon of the *agent's own* app, preferred over the host terminal's: the
    /// row already carries a badge naming the terminal, so showing its icon too
    /// spends the only graphical slot on the least distinguishing fact. Nil when
    /// the agent has no app installed — Claude Code is usually a CLI with no
    /// bundle to look up, which is what `ClaudeMark` draws instead.
    var agentAppIcon: NSImage? {
        let candidates: [String]
        switch knownAgent {
        case .claudeCode: candidates = ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        case .codex: candidates = ["com.openai.codex", "com.openai.chat"]
        // Cursor pings already carry Cursor's own bundle id, so `appIcon` covers
        // it — no need to look the app up a second time here.
        case .cursor, nil: return nil
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
            deliverySpec: userInfo["delivery"] as? String
        )
    }
}

/// Whether an agent alert is a completed task (finished) or a pending question (waiting).
enum AlertKind: String, Codable { case finished, waiting }

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
    case ci([CIRun])

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
        case .ci: return "ci"
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
        case .ci: return "CI status"
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
        case .ci(let runs): return "ci-" + runs.map { $0.id + $0.statusLabel }.joined(separator: ",")
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
