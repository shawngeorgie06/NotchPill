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

/// Compact chip shown in the collapsed pill preview.
enum CollapsedChip: Equatable, Identifiable {
    case media(NowPlaying)
    case calendar(CalendarEvent)
    case shelf(count: Int)
    case appSwitch(String)

    var id: String {
        switch self {
        case .media(let np): return "media-\(np.title)-\(np.artist)"
        case .calendar(let e): return "cal-\(e.title)-\(e.start.timeIntervalSince1970)"
        case .shelf(let count): return "shelf-\(count)"
        case .appSwitch(let name): return "app-\(name)"
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

    var id: String {
        switch self {
        case .media(let np): return "media-\(np.title)-\(np.artist)-\(np.isPlaying)"
        case .appSwitch(let name): return "switch-\(name)"
        case .activeApp(let name): return "app-\(name)"
        case .volume(let level): return "vol-\(level)"
        case .clock: return "clock"
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
