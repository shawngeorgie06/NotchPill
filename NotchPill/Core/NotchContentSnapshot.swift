import Foundation

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
            showMedia: settings.showCollapsedMedia,
            showCalendar: settings.showCalendar,
            showShelf: settings.showFileShelf,
            showAppSwitch: settings.showCollapsedAppSwitch,
            showTimer: settings.showCollapsedTimer,
            showSystemStats: settings.showCollapsedSystemStats,
            showBattery: settings.showCollapsedBattery,
            showAgents: settings.showCollapsedAgents,
            showClock: settings.showCollapsedClock
        )
    }

    static func expandedActivities(
        state: NotchState,
        shelf: ShelfStore,
        timer: TimerStore,
        settings: AppSettings
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
            openCodeUsage: state.openCodeUsage,
            codexQuota: state.codexQuota,
            claudeQuota: state.claudeQuota,
            cursorQuota: state.cursorQuota,
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
            showCI: settings.showExpandedCI,
            showRecentAlerts: settings.showExpandedRecentActivity,
            shelfItems: shelf.items.map { ShelfCardItem(id: $0.id, name: $0.name, url: $0.url) },
            shelfReceipt: shelf.receipt,
            shelfError: shelf.lastError,
            shelfDropTargeted: shelf.isDropTargeted
        ), pinnedKind: settings.pinnedActivityKind)
        // Smaller pill, fewer cards. The builder already returns them in
        // priority order, so this drops the least important tail rather than
        // shrinking everything past the point of being readable.
        let limit = NotchContentLayout.visibleCardLimit(
            forUserScale: CGFloat(settings.notchScale))
        let visible = Array(all.prefix(limit))
        logShelfDiagnostics(all: all, visible: visible, shelf: shelf, settings: settings)
        return visible
    }

    /// Diagnostic only, and only when asked for: `NOTCHPILL_LOG_SHELF=1`.
    /// Answers the three questions a missing card raises at once — is the
    /// setting on, does the shelf have anything in it, and did the card survive
    /// the visible-card trim. Logged only when the answer changes.
    nonisolated(unsafe) private static var lastShelfShape: String?

    private static func logShelfDiagnostics(all: [ExpandedActivity],
                                            visible: [ExpandedActivity],
                                            shelf: ShelfStore,
                                            settings: AppSettings) {
        guard LogStore.tracesShelf else { return }
        let shape = "showExpandedShelf=\(settings.showExpandedShelf)"
            + " items=\(shelf.items.count)"
            + " targeted=\(shelf.isDropTargeted)"
            + " built=\(all.contains { $0.kind == "shelf" })"
            + " visible=\(visible.contains { $0.kind == "shelf" })"
            + " limit=\(visible.count)/\(all.count)"
            + " deck=[\(visible.map(\.kind).joined(separator: ","))]"
        guard shape != lastShelfShape else { return }
        lastShelfShape = shape
        LogStore.shelf(shape)
    }
}
