import SwiftUI

/// Where a usage window's spending would sit if it were spread evenly across
/// the window.
///
/// A bare percentage cannot say whether 40% is a problem: 40% an hour into a
/// five-hour session will run out, 40% with an hour left will not. The tick on
/// a meter answers that, and a fill past it means the window is being spent
/// faster than it renews.
enum UsagePace {
    /// Anthropic's two account-wide windows. They are not reported in the
    /// payload, but they are the plan's definition rather than a guess.
    static let claudeSession: TimeInterval = 5 * 3600
    static let claudeWeek: TimeInterval = 7 * 86_400

    /// How far through a window `now` is, 0…1, from when it renews and how
    /// long it lasts. Nil when either is unknown, or when the reset is already
    /// past or further away than the window is long — a reading from before a
    /// renewal, where a tick would point at the wrong window.
    static func elapsed(resetsAt: Date?, length: TimeInterval?, now: Date = Date()) -> Double? {
        guard let resetsAt, let length, length > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0, remaining <= length else { return nil }
        return 1 - remaining / length
    }

    /// The same for a window known by its two ends, like a billing cycle.
    static func elapsed(start: Date?, end: Date?, now: Date = Date()) -> Double? {
        guard let start, let end, end > start else { return nil }
        return elapsed(resetsAt: end, length: end.timeIntervalSince(start), now: now)
    }

    /// Ahead of pace by more than a rounding point. A meter that sits on its
    /// tick is on pace, not over it.
    static func isAhead(percent: Int, elapsed: Double) -> Bool {
        Double(percent) / 100 > elapsed + 0.01
    }
}

/// How much a usage reading can still be trusted.
///
/// Every provider polls within a minute or two while the app runs, so a
/// reading this old missed at least several checks — the Mac slept, the
/// network dropped, or the provider stopped answering — and use elsewhere may
/// not be in it. It is still the latest number known, so it stays on the card,
/// drawn quieter, rather than vanishing.
enum UsageFreshness {
    static let staleAfter: TimeInterval = 10 * 60

    static func isStale(_ updatedAt: Date?, now: Date = Date()) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > staleAfter
    }
}

/// One colour per agent, used everywhere that agent appears: its usage
/// meters, its row's mark, and its bars in the history.
///
/// The colour is identity, not status. A meter wears its agent's colour while
/// there is room, and only turns amber once the window runs low — green for
/// everything made "fine" carry no information about whose card it was.
enum AgentTint {
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.45, green: 0.62, blue: 0.98)
    static let cursor = Color(red: 0.72, green: 0.74, blue: 0.80)
    static let openCode = Color(red: 0.62, green: 0.78, blue: 0.45)

    static func color(for agent: DevReadyAlert.KnownAgent?) -> Color? {
        switch agent {
        case .claudeCode: return claude
        case .codex: return codex
        case .cursor: return cursor
        case .openCode: return openCode
        case nil: return nil
        }
    }

    /// Token-history tool names, as `TokenUsageSummary` keys them.
    static func color(forTool tool: String) -> Color {
        switch tool {
        case TokenUsageSummary.codex: return codex
        default: return claude
        }
    }

    /// The point a window counts as running low.
    static let lowAt = 70

    /// The meter's colour: the agent's own until the window runs low, then
    /// amber deepening toward the limit. Nothing on a usage card is an
    /// emergency, so it never turns red.
    static func meter(percent: Int, agent: Color) -> Color {
        if percent >= 90 { return NotchDesign.devReadyAmber.opacity(0.95) }
        if percent >= lowAt { return NotchDesign.devReadyAmber.opacity(0.75) }
        return agent.opacity(0.85)
    }
}

/// Tokens per day, per agent, from the transcripts already being read for the
/// usage cards.
///
/// The quota cards say how much of a window is left; this says what the
/// recent weeks looked like, which is the question a limit raises next.
struct UsageHistory: Equatable {
    /// Day (`yyyy-MM-dd`) → tool → full-price tokens.
    var daily: [String: [String: Int]]

    /// Columns in the activity grid, newest on the right.
    static let weeks = 13
    /// Bars in the recent-days chart.
    static let recentDays = 14

    var isEmpty: Bool { daily.values.allSatisfy { $0.values.allSatisfy { $0 <= 0 } } }

    /// The oldest day the grid can show: the start of the week `weeks - 1`
    /// weeks before this one.
    static func firstDay(now: Date = Date(), calendar: Calendar = .current) -> Date {
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start
            ?? calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -7 * (weeks - 1), to: thisWeek) ?? thisWeek
    }

    func tokens(on day: Date) -> [String: Int] {
        daily[TokenLedger.day(from: day)] ?? [:]
    }

    func total(on day: Date) -> Int {
        tokens(on: day).values.reduce(0, +)
    }

    /// The last `count` days, oldest first, today included and empty days kept
    /// so the bars line up with the calendar.
    func lastDays(_ count: Int = recentDays, now: Date = Date(),
                  calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<count).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
    }

    /// Week columns of seven days each, oldest week first. Days after today
    /// are nil so the current week ends where today does.
    func grid(now: Date = Date(), calendar: Calendar = .current) -> [[Date?]] {
        let start = Self.firstDay(now: now, calendar: calendar)
        let today = calendar.startOfDay(for: now)
        return (0..<Self.weeks).map { week in
            (0..<7).map { weekday in
                guard let day = calendar.date(byAdding: .day, value: week * 7 + weekday, to: start)
                else { return nil }
                return day > today ? nil : day
            }
        }
    }

    /// Shading level 0…4 for a day. Zero is reserved for no use; the rest
    /// split the days that had any into quartiles, so one enormous day does
    /// not wash every other day out to the faintest shade.
    static func level(_ value: Int, among values: [Int]) -> Int {
        guard value > 0 else { return 0 }
        let used = values.filter { $0 > 0 }.sorted()
        guard !used.isEmpty else { return 0 }
        let below = used.filter { $0 < value }.count
        return min(4, 1 + below * 4 / used.count)
    }
}
