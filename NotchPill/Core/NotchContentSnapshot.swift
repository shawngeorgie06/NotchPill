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
            showMedia: settings.showCollapsedMedia,
            showCalendar: settings.showCalendar,
            showShelf: settings.showFileShelf,
            showAppSwitch: settings.showCollapsedAppSwitch,
            showTimer: settings.showCollapsedTimer,
            showSystemStats: settings.showCollapsedSystemStats,
            showBattery: settings.showCollapsedBattery,
            showClock: settings.showCollapsedClock
        )
    }

    static func expandedActivities(
        state: NotchState,
        shelf: ShelfStore,
        timer: TimerStore,
        settings: AppSettings
    ) -> [ExpandedActivity] {
        ExpandedActivityBuilder.activities(
            nowPlaying: state.nowPlaying,
            nextEvent: state.nextEvent,
            appSwitchHint: state.appSwitchHint,
            frontmostApp: state.frontmostApp,
            systemVolume: state.systemVolume,
            timer: timer.active,
            systemStats: state.systemStats,
            battery: state.battery,
            shelfCount: shelf.items.count,
            shelfNames: shelf.items.prefix(3).map(\.name),
            showMedia: settings.showExpandedMedia,
            showActiveApp: settings.showExpandedActiveApp,
            showVolume: settings.showExpandedVolume,
            showClock: settings.showExpandedClock,
            showCalendar: settings.showExpandedCalendar,
            showTimer: settings.showExpandedTimer,
            showSystemStats: settings.showExpandedSystemStats,
            showBattery: settings.showExpandedBattery,
            showShelf: settings.showExpandedShelf
        )
    }
}
