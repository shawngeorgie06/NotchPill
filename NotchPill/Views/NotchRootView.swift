import SwiftUI

/// The overlay's SwiftUI surface. A black notch-shaped background grows from the
/// physical notch into a pill on hover; content crossfades between states rather
/// than popping.
struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var timer: TimerStore
    let metrics: NotchMetrics
    let actions: NotchActions
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collapsedChips: [CollapsedChip] {
        NotchContentSnapshot.collapsedChips(state: state, shelf: shelf, timer: timer, settings: settings)
    }

    private var expandedActivities: [ExpandedActivity] {
        NotchContentSnapshot.expandedActivities(state: state, shelf: shelf, timer: timer, settings: settings)
    }

    private var contentLayout: NotchContentLayoutMetrics {
        if !state.devReadyAlerts.isEmpty {
            return NotchContentLayout.devReadyLayout(metrics: metrics, alerts: state.devReadyAlerts)
        }
        if state.isExpanded {
            return NotchContentLayout.expandedLayout(metrics: metrics, activities: expandedActivities)
        }
        return NotchContentLayout.collapsedLayout(metrics: metrics, chips: collapsedChips)
    }

    private var frameSize: CGSize { contentLayout.size }

    private var expandedDesignSize: CGSize {
        NotchContentLayout.expandedDesignContentSize(metrics: metrics, activities: expandedActivities)
    }

    private var readabilityScale: CGFloat { contentLayout.readability }
    private var textScale: CGFloat { contentLayout.textScale }

    private var settingsFingerprint: String {
        [
            settings.showCollapsedActivity, settings.showCollapsedMedia, settings.showCollapsedAppSwitch,
            settings.showCalendar, settings.showFileShelf, settings.showCollapsedTimer,
            settings.showCollapsedSystemStats, settings.showCollapsedBattery, settings.showCollapsedClock,
            settings.showExpandedMedia, settings.showExpandedActiveApp, settings.showExpandedVolume,
            settings.showExpandedClock, settings.showExpandedCalendar, settings.showExpandedTimer,
            settings.showExpandedSystemStats, settings.showExpandedBattery, settings.showExpandedShelf
        ].map { $0 ? "1" : "0" }.joined()
    }

    private var expandAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.11, dampingFraction: 0.92)
    }
    private var contentAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.1)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if state.isExpanded || !state.devReadyAlerts.isEmpty {
                expandedBackground
            } else {
                PillSurface(bottomRadius: collapsedBottomRadius)
                    .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            }
        }
        .overlay(alignment: .top) {
            if !state.devReadyAlerts.isEmpty {
                devReadyContent(alerts: state.devReadyAlerts)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if state.isExpanded {
                expandedContent
                    .transition(.opacity)
            } else if !collapsedChips.isEmpty {
                collapsedContent
                    .transition(.opacity)
            }
        }
        .overlay {
            if let level = state.volumeLevel {
                VolumeHUD(level: level)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
        .animation(expandAnimation, value: state.isExpanded)
        .animation(expandAnimation, value: frameSize.width)
        .animation(expandAnimation, value: frameSize.height)
        .animation(expandAnimation, value: collapsedChips.map(\.id))
        .animation(expandAnimation, value: expandedActivities.map(\.id))
        .animation(expandAnimation, value: readabilityScale)
        .animation(expandAnimation, value: textScale)
        .animation(expandAnimation, value: settingsFingerprint)
        .animation(contentAnimation, value: state.activity)
        .animation(contentAnimation, value: state.volumeLevel)
        .animation(expandAnimation, value: state.devReadyAlerts.map(\.id))
    }

    private var collapsedBottomRadius: CGFloat {
        collapsedChips.isEmpty ? max(8, metrics.notchHeight / 2) : 12
    }

    /// Expanded pill: black surface in the notch column + rounded body below; ears stay clear for tabs.
    private var expandedBackground: some View {
        let earWidth = max(0, (frameSize.width - metrics.notchWidth) / 2)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: earWidth, height: metrics.notchHeight)
                Color.black.frame(width: metrics.notchWidth, height: metrics.notchHeight)
                Color.clear.frame(width: earWidth, height: metrics.notchHeight)
            }
            PillSurface(bottomRadius: 16)
                .frame(width: frameSize.width, height: max(0, frameSize.height - metrics.notchHeight))
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            ExpandedView(
                state: state,
                shelf: shelf,
                timer: timer,
                actions: actions,
                activities: expandedActivities,
                readability: readabilityScale,
                textScale: textScale
            )
                .padding(.top, metrics.topGap + 4)
                .frame(width: expandedDesignSize.width, height: expandedDesignSize.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .frame(width: frameSize.width, height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            CollapsedIndicatorsRow(chips: collapsedChips, readability: readabilityScale, textScale: textScale)
                .padding(.top, 6)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private func devReadyContent(alerts: [DevReadyAlert]) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            DevReadyPeekListView(
                alerts: alerts,
                actions: actions,
                maxScrollHeight: alerts.count > 1
                    ? NotchContentLayout.devReadyListHeight(rowCount: alerts.count)
                    : nil
            )
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width, height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }
}

/// Expanded pill: live status cards sized to how many are visible.
struct ExpandedView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var timer: TimerStore
    let actions: NotchActions
    let activities: [ExpandedActivity]
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0

    var body: some View {
        Group {
            if activities.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.inset.filled")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.white.opacity(0.2))
                    Text("No cards enabled")
                        .font(.system(size: 13 * textScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cardRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.16), value: state.nowPlaying)
        .animation(.easeOut(duration: 0.14), value: state.appSwitchHint)
        .animation(.easeOut(duration: 0.14), value: state.frontmostApp)
        .animation(.easeOut(duration: 0.12), value: state.systemVolume)
        .animation(.easeOut(duration: 0.14), value: activities.map(\.id))
    }

    private var cardRow: some View {
        HStack(spacing: 10 * readability) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                ExpandedActivityCard(
                    activity: activity,
                    appIcon: state.frontmostAppIcon,
                    actions: actions,
                    onCancelTimer: { timer.cancel() },
                    readability: readability,
                    textScale: textScale,
                    expandToFill: activities.count <= 2 || readability > 1.1
                )
                if index < activities.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1)
                        .padding(.vertical, 2 * readability)
                }
            }
        }
    }
}
