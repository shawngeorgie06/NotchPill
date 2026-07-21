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

    static let notificationName = Notification.Name("com.shawngeorgie06.NotchPill.devReady")

    init(
        id: String = UUID().uuidString,
        title: String,
        subtitle: String? = nil,
        source: String? = nil,
        agent: String? = nil,
        bundleId: String? = nil
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.source = source
        self.agent = agent
        self.bundleId = bundleId
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
        return DevReadyAlert(
            id: (id?.isEmpty == false) ? id! : UUID().uuidString,
            title: title,
            subtitle: userInfo["subtitle"] as? String,
            source: userInfo["source"] as? String,
            agent: userInfo["agent"] as? String,
            bundleId: userInfo["bundleId"] as? String
        )
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
