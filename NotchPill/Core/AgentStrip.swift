import AppKit
import Foundation

/// The one place an agent's look is decided: which installed app stands for
/// it, and which glyph to fall back to when that app is not on this Mac.
///
/// The session rows, the peeks, the usage cards and the closed-notch strip
/// each kept their own copy of these bundle lists, and the copies drifted:
/// Cursor was missing from the peek's, so a `cursor-agent` turn run in a
/// terminal wore the terminal's icon.
extension DevReadyAlert.KnownAgent {
    /// Apps whose icon can stand for this agent, most specific first. Read
    /// from the Mac at run time, never bundled: the logo is whatever the
    /// vendor currently ships.
    var iconBundleIds: [String] {
        switch self {
        case .claudeCode: return ["com.anthropic.claudefordesktop", "com.anthropic.claude"]
        // ChatGPT desktop's bundle id is `com.openai.codex`.
        case .codex: return ["com.openai.codex", "com.openai.chat"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92"]
        // A CLI with no app bundle to look up.
        case .openCode: return []
        }
    }

    var appIcon: NSImage? {
        AppIconCache.shared.icon(forAnyOf: iconBundleIds)
    }

    /// Last-resort glyph when the vendor's app is not installed.
    var symbol: String {
        switch self {
        case .claudeCode: return "asterisk"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .openCode: return "curlybraces"
        }
    }

    /// Anthropic's mark ships in the bundle, because Claude Code is a CLI and
    /// usually has no app whose icon could be borrowed.
    var bundledMark: String? { self == .claudeCode ? "ClaudeMark" : nil }
}

/// What the closed notch shows while an agent works: that agent's logo on one
/// side of the camera and one reading on the other.
///
/// Nil whenever no session is working or waiting, so an idle Mac keeps the
/// blank notch.
struct AgentStrip: Equatable {
    var agent: DevReadyAlert.KnownAgent?
    /// Blocked on you. The logo holds still and the strip gains an amber dot;
    /// a pulse would say "busy", which is the opposite.
    var isWaiting: Bool
    /// Working or waiting sessions in all, so a second agent is not invisible.
    var activeCount: Int
    var reading: Reading?

    /// What sits on the camera's other side.
    enum ReadingKind: String, CaseIterable, Identifiable {
        /// The plan window closest to running out, across every agent.
        case tightestLimit
        /// The shown agent's own tightest window.
        case agentLimit
        /// How many agents are working or waiting.
        case activeCount
        /// Logo only.
        case none

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tightestLimit: return "Closest plan limit"
            case .agentLimit: return "This agent's plan limit"
            case .activeCount: return "Number of active agents"
            case .none: return "Nothing"
            }
        }
    }

    enum Reading: Equatable {
        case limit(UsageWindow)
        case count(Int)
    }

    /// One plan window, reduced to what the strip draws.
    struct UsageWindow: Equatable {
        var agent: DevReadyAlert.KnownAgent
        var percent: Int
        /// Older than `UsageFreshness.staleAfter`: drawn grey, so a number
        /// that may have moved on does not pass for a live one.
        var isStale: Bool
    }

    /// Picks the session to show and builds its reading.
    ///
    /// A session waiting on you wins over one that is working: the strip is
    /// the only trace of the question once its peek has been dismissed. Ties
    /// go to the most recent activity. A session whose process is known to be
    /// dead never counts.
    static func resolve(sessions: [AgentSession],
                        claude: ClaudeQuota?,
                        codex: CodexQuota?,
                        cursor: CursorQuota?,
                        readingKind: ReadingKind,
                        now: Date = Date()) -> AgentStrip? {
        let active = sessions.filter { session in
            guard session.isAlive != false else { return false }
            switch session.state {
            case .working, .waiting: return true
            case .idle, .completed: return false
            }
        }
        guard let lead = active.max(by: { a, b in
            if a.isWaiting != b.isWaiting { return !a.isWaiting }
            return a.lastActivity < b.lastActivity
        }) else { return nil }

        let windows = usageWindows(claude: claude, codex: codex, cursor: cursor, now: now)
        let reading: Reading?
        switch readingKind {
        case .tightestLimit:
            reading = tightest(windows, preferring: lead.knownAgent).map(Reading.limit)
        case .agentLimit:
            reading = lead.knownAgent
                .flatMap { agent in tightest(windows.filter { $0.agent == agent }, preferring: agent) }
                .map(Reading.limit)
        case .activeCount:
            reading = .count(active.count)
        case .none:
            reading = nil
        }
        return AgentStrip(agent: lead.knownAgent, isWaiting: lead.isWaiting,
                          activeCount: active.count, reading: reading)
    }

    /// Every plan window that still describes the present.
    ///
    /// A window whose reset has already passed is left out: its percentage
    /// belongs to the window that just ended, and showing "93%" for an
    /// allowance that has refilled is worse than showing nothing.
    static func usageWindows(claude: ClaudeQuota?, codex: CodexQuota?, cursor: CursorQuota?,
                             now: Date = Date()) -> [UsageWindow] {
        var windows: [UsageWindow] = []
        func add(_ agent: DevReadyAlert.KnownAgent, _ percent: Int?, resetsAt: Date?, updatedAt: Date?) {
            guard let percent else { return }
            if let resetsAt, resetsAt <= now { return }
            windows.append(UsageWindow(agent: agent, percent: min(100, max(0, percent)),
                                       isStale: UsageFreshness.isStale(updatedAt, now: now)))
        }
        if let claude {
            add(.claudeCode, claude.sessionPercent, resetsAt: claude.sessionResetsAt, updatedAt: claude.updatedAt)
            add(.claudeCode, claude.weeklyPercent, resetsAt: claude.weeklyResetsAt, updatedAt: claude.updatedAt)
            for window in claude.modelWindows {
                add(.claudeCode, window.percent, resetsAt: window.resetsAt, updatedAt: claude.updatedAt)
            }
        }
        if let codex {
            add(.codex, codex.usedPercent, resetsAt: codex.resetsAt, updatedAt: codex.updatedAt)
            add(.codex, codex.weeklyPercent, resetsAt: codex.weeklyResetsAt, updatedAt: codex.updatedAt)
        }
        if let cursor, !cursor.isUnlimited {
            // Auto and API are separate pools with their own ceilings; either
            // can run out while the blended total still looks comfortable.
            for percent in [cursor.percentUsed, cursor.autoPercentUsed, cursor.apiPercentUsed] {
                add(.cursor, percent, resetsAt: cursor.cycleEnd, updatedAt: cursor.updatedAt)
            }
        }
        return windows
    }

    /// The highest current reading. A fresh reading beats any stale one, so a
    /// cached number cannot crowd out what is known now; on a tie the agent
    /// being shown wins, so the two sides of the camera agree.
    static func tightest(_ windows: [UsageWindow],
                         preferring agent: DevReadyAlert.KnownAgent?) -> UsageWindow? {
        windows.max { a, b in
            if a.isStale != b.isStale { return a.isStale }
            if a.percent != b.percent { return a.percent < b.percent }
            return a.agent != agent && b.agent == agent
        }
    }
}
