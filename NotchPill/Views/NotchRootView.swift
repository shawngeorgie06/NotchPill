import SwiftUI

/// The overlay's SwiftUI surface. A black notch-shaped background grows from the
/// physical notch into a pill on hover; content crossfades between states rather
/// than popping.
struct NotchRootView: View {
    @ObservedObject var state: NotchState
    let metrics: NotchMetrics
    let actions: NotchActions

    var body: some View {
        let size = state.isExpanded ? metrics.expandedSize : metrics.collapsedSize

        ZStack(alignment: .top) {
            NotchShape(bottomRadius: state.isExpanded ? 24 : max(6, metrics.notchHeight / 2))
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    if state.isExpanded {
                        ExpandedView(state: state, actions: actions)
                            .frame(width: size.width, height: size.height, alignment: .top)
                            .padding(.top, metrics.notchHeight)
                            .transition(.opacity)
                    }
                }

            if !state.isExpanded {
                CollapsedIndicator(activity: state.activity)
                    .id(state.activity.transitionKey)
                    .transition(.opacity)
                    .opacity(state.activity == .idle ? 0 : 1)
                    .offset(y: metrics.notchHeight + 3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Expand/collapse settles well within the 300ms budget.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: state.isExpanded)
        // Content changes crossfade rather than pop.
        .animation(.easeInOut(duration: 0.28), value: state.activity)
    }
}

/// The expanded pill body: now-playing + controls, battery, next event. Tiles
/// with no reliable data (e.g. AirDrop) are omitted rather than faked.
struct ExpandedView: View {
    @ObservedObject var state: NotchState
    let actions: NotchActions

    var body: some View {
        HStack(spacing: 16) {
            NowPlayingTile(nowPlaying: state.nowPlaying, actions: actions)
                .frame(maxWidth: .infinity)

            Divider().overlay(Color.white.opacity(0.12))

            if let battery = state.battery {
                BatteryTile(battery: battery)
                    .frame(width: 70)
                    .transition(.opacity)
            }

            if let event = state.nextEvent {
                Divider().overlay(Color.white.opacity(0.12))
                CalendarTile(event: event)
                    .frame(width: 150)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
        .padding(.top, 8)
        // Any tile-data swap crossfades too.
        .animation(.easeInOut(duration: 0.25), value: state.nowPlaying)
        .animation(.easeInOut(duration: 0.25), value: state.battery)
        .animation(.easeInOut(duration: 0.25), value: state.nextEvent)
    }
}
