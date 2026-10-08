import Foundation

/// Read-only settings let snapshot tests use their own defaults domain.
@MainActor
protocol ExpandedContentSettings: UsageCardSettings {
    var showExpandedMedia: Bool { get }
    var showExpandedActiveApp: Bool { get }
    var showExpandedVolume: Bool { get }
    var showExpandedClock: Bool { get }
    var showExpandedCalendar: Bool { get }
    var showExpandedTimer: Bool { get }
    var showExpandedSystemStats: Bool { get }
    var showExpandedBattery: Bool { get }
    var showExpandedShelf: Bool { get }
    var showExpandedAgents: Bool { get }
    var showExpandedCommands: Bool { get }
    var showExpandedCI: Bool { get }
    var showExpandedRecentActivity: Bool { get }
    var showClipboard: Bool { get }
    var showTerminal: Bool { get }
    var resolvedCardOrder: [String] { get }
    var pinnedActivityKind: String { get }
}

extension AppSettings: ExpandedContentSettings {}

/// Builds visible chip/card lists and sizes from live state + settings.
@MainActor
enum NotchContentSnapshot {
    static func collapsedChips(
        state: NotchState,
        shelf: ShelfStore,
        timer: TimerStore,
        settings: AppSettings
    ) -> [CollapsedChip] {
        guard settings.showCollapsedActivity else { return [] }
        return CollapsedChipBuilder.chips(
            nowPlaying: state.nowPlaying,
            nextEvent: state.nextEvent,
            shelfCount: shelf.items.count,
            appSwitchHint: state.appSwitchHint,
            timer: timer.active,
            systemStats: state.systemStats,
            battery: state.battery,
            agentSessions: state.agentSessions,
            devCommands: state.devCommands,
            showMedia: settings.showCollapsedMedia,
            showCalendar: settings.showCalendar,
            showShelf: settings.showFileShelf,
            showAppSwitch: settings.showCollapsedAppSwitch,
            showTimer: settings.showCollapsedTimer,
            showSystemStats: settings.showCollapsedSystemStats,
            showBattery: settings.showCollapsedBattery,
            showAgents: settings.showCollapsedAgents,
            showCommands: settings.showExpandedCommands,
            showClock: settings.showCollapsedClock
        )
    }

    static func expandedActivities(
        state: NotchState,
        shelf: ShelfStore,
        timer: TimerStore,
        settings: any ExpandedContentSettings
    ) -> [ExpandedActivity] {
        // The live scanner knows which transcripts are still changing; agent
        // alerts know about completed turns and questions that need an answer.
        // The expanded card needs both, otherwise a just-finished conversation
        // vanishes and a pending question is only visible while its peek is up.
        let agentSessions = AgentSession.displaySessions(
            live: state.agentSessions,
            waitingAlerts: state.devReadyAlerts,
            completedAlerts: state.recentDevReadyAlerts)
        let all = ExpandedActivityBuilder.prioritizing(ExpandedActivityBuilder.activities(
            nowPlaying: state.nowPlaying,
            nextEvent: state.nextEvent,
            appSwitchHint: state.appSwitchHint,
            frontmostApp: state.frontmostApp,
            systemVolume: state.systemVolume,
            timer: timer.active,
            systemStats: state.systemStats,
            battery: state.battery,
            agentSessions: agentSessions,
            devCommands: state.devCommands,
            openCodeUsage: state.openCodeUsage,
            codexQuota: state.codexQuota,
            claudeQuota: settings.showClaudeUsage ? state.claudeQuota : nil,
            cursorQuota: settings.showCursorUsage ? state.cursorQuota : nil,
            ciRuns: state.ciRuns,
            recentAlerts: state.recentDevReadyAlerts,
            showMedia: settings.showExpandedMedia,
            showActiveApp: settings.showExpandedActiveApp,
            showVolume: settings.showExpandedVolume,
            showClock: settings.showExpandedClock,
            showCalendar: settings.showExpandedCalendar,
            showTimer: settings.showExpandedTimer,
            showSystemStats: settings.showExpandedSystemStats,
            showBattery: settings.showExpandedBattery,
            showShelf: settings.showExpandedShelf,
            showAgents: settings.showExpandedAgents,
            showCommands: settings.showExpandedCommands,
            showCI: settings.showExpandedCI,
            showRecentAlerts: settings.showExpandedRecentActivity,
            shelfItems: shelf.items.map { ShelfCardItem(id: $0.id, name: $0.name, url: $0.url) },
            shelfReceipt: shelf.receipt,
            shelfError: shelf.lastError,
            shelfDropTargeted: shelf.isDropTargeted,
            clipboard: settings.showClipboard ? ClipboardStore.shared.visibleEntries : [],
            clipboardSearching: settings.showClipboard && ClipboardStore.shared.isSearching,
            terminal: settings.showTerminal ? TerminalStore.shared.snapshot : nil,
            cardOrder: settings.resolvedCardOrder
        ), pinnedKind: settings.pinnedActivityKind)
        // Every enabled card with data belongs in the deck. Pages share one
        // fixed canvas, and the picker handles long decks without a dot for
        // every card.
        logShelfDiagnostics(all: all, shelf: shelf, settings: settings)
        return all
    }

    /// Diagnostic only, and only when asked for: `NOTCHPILL_LOG_SHELF=1`.
    /// Answers whether the card setting is on, whether there is shelf data,
    /// and whether a shelf page was built. Logged only when the answer changes.
    nonisolated(unsafe) private static var lastShelfShape: String?

    private static func logShelfDiagnostics(all: [ExpandedActivity],
                                            shelf: ShelfStore,
                                            settings: any ExpandedContentSettings) {
        guard LogStore.tracesShelf else { return }
        let shape = "showExpandedShelf=\(settings.showExpandedShelf)"
            + " items=\(shelf.items.count)"
            + " targeted=\(shelf.isDropTargeted)"
            + " built=\(all.contains { $0.kind == "shelf" })"
            + " deck=[\(all.map(\.kind).joined(separator: ","))]"
        guard shape != lastShelfShape else { return }
        lastShelfShape = shape
        LogStore.shelf(shape)
    }
}
