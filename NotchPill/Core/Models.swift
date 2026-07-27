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

    static let notificationName = Notification.Name("com.shawngeorgie06.NotchPill.devReady")

    /// The agent's question, when this alert is one. Single source of truth for
    /// "is there a question to show" — the peek row, the composer, and both
    /// height budgets read it, so they can't disagree about whether the space is
    /// reserved and whether anything fills it.
    var questionText: String? {
        guard kind == .waiting, let message, !message.isEmpty else { return nil }
        return message
    }

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
        sessionId: String? = nil
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
    }

    enum CodingKeys: String, CodingKey {
        case id, title, subtitle, source, agent, bundleId, kind, message, createdAt, sessionId
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
            sessionId: userInfo["sessionId"] as? String
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
