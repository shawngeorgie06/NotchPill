import SwiftUI

/// The overlay's SwiftUI surface. A black notch-shaped background grows from the
/// physical notch into a pill on hover; content crossfades between states rather
/// than popping.
struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    let metrics: NotchMetrics
    let actions: NotchActions
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var collapsedChips: [CollapsedChip] {
        guard settings.showCollapsedActivity else { return [] }
        return CollapsedChipBuilder.chips(
            nowPlaying: state.nowPlaying,
            nextEvent: state.nextEvent,
            shelfCount: shelf.items.count,
            appSwitchHint: state.appSwitchHint,
            showMedia: settings.showCollapsedMedia,
            showCalendar: settings.showCalendar,
            showShelf: settings.showFileShelf,
            showAppSwitch: settings.showCollapsedAppSwitch
        )
    }

    private var frameSize: CGSize {
        if state.isExpanded { return metrics.expandedSize }
        if collapsedChips.isEmpty { return metrics.collapsedSize }
        return metrics.collapsedPreviewSize(chipCount: collapsedChips.count)
    }

    private var expandAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.26, dampingFraction: 0.86)
    }
    private var contentAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.28)
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomRadius: state.isExpanded ? 24 : collapsedBottomRadius)
                .fill(Color.black)
                .frame(width: frameSize.width, height: frameSize.height)
                .overlay(alignment: .top) {
                    if state.isExpanded {
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expandAnimation, value: state.isExpanded)
        .animation(expandAnimation, value: collapsedChips.map(\.id))
        .animation(contentAnimation, value: state.activity)
        .animation(contentAnimation, value: state.volumeLevel)
    }

    private var collapsedBottomRadius: CGFloat {
        collapsedChips.isEmpty ? max(6, metrics.notchHeight / 2) : 14
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight + metrics.topGap)
            ExpandedView(state: state, actions: actions)
                .frame(width: metrics.designContentSize.width,
                       height: metrics.designContentSize.height)
                .scaleEffect(metrics.scale, anchor: .top)
                .frame(width: metrics.expandedWidth, height: metrics.expandedHeight)
        }
        .frame(width: metrics.expandedSize.width, height: metrics.expandedSize.height, alignment: .top)
    }

    private var collapsedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            CollapsedIndicatorsRow(chips: collapsedChips)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }
}

/// Expanded pill: live status cards (media, app, volume, clock).
struct ExpandedView: View {
    @ObservedObject var state: NotchState
    let actions: NotchActions
    @ObservedObject private var settings = AppSettings.shared

    private var activities: [ExpandedActivity] {
        ExpandedActivityBuilder.activities(
            nowPlaying: state.nowPlaying,
            appSwitchHint: state.appSwitchHint,
            frontmostApp: state.frontmostApp,
            systemVolume: state.systemVolume,
            showMedia: settings.showExpandedMedia,
            showActiveApp: settings.showExpandedActiveApp,
            showVolume: settings.showExpandedVolume,
            showClock: settings.showExpandedClock
        )
    }

    var body: some View {
        Group {
            if activities.isEmpty {
                Text("No cards enabled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                cardRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.25), value: state.nowPlaying)
        .animation(.easeInOut(duration: 0.2), value: state.appSwitchHint)
        .animation(.easeInOut(duration: 0.2), value: state.frontmostApp)
        .animation(.easeInOut(duration: 0.15), value: state.systemVolume)
    }

    private var cardRow: some View {
        HStack(spacing: 10) {
            ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                ExpandedActivityCard(
                    activity: activity,
                    appIcon: state.frontmostAppIcon,
                    actions: actions,
                    prefersWide: {
                        if case .media = activity { return true }
                        return false
                    }()
                )
                if index < activities.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}
