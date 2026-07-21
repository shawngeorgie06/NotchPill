import SwiftUI

/// The overlay's SwiftUI surface. A black notch-shaped background grows from the
/// physical notch into a pill on hover; content crossfades between states rather
/// than popping.
struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    let metrics: NotchMetrics
    let actions: NotchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// When the user prefers reduced motion, swap springs/crossfades for a very
    /// short, near-instant opacity change (SwiftUI still needs a value to key on).
    private var expandAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.26, dampingFraction: 0.86)
    }
    private var contentAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.28)
    }

    var body: some View {
        let size = state.isExpanded ? metrics.expandedSize : metrics.collapsedSize

        ZStack(alignment: .top) {
            NotchShape(bottomRadius: state.isExpanded ? 24 : max(6, metrics.notchHeight / 2))
                .fill(Color.black)
                .frame(width: size.width, height: size.height)
                .overlay(alignment: .top) {
                    if state.isExpanded {
                        VStack(spacing: 0) {
                            // Physical notch area, unscaled.
                            Color.clear.frame(height: metrics.notchHeight)
                            // Content is laid out at its full design size, then the
                            // whole pill is shrunk uniformly by `metrics.scale`.
                            ExpandedView(state: state, shelf: shelf, actions: actions)
                                .frame(width: metrics.designContentSize.width,
                                       height: metrics.designContentSize.height)
                                .scaleEffect(metrics.scale, anchor: .top)
                                .frame(width: metrics.expandedWidth, height: metrics.expandedHeight)
                        }
                        .frame(width: size.width, height: size.height, alignment: .top)
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
        .animation(expandAnimation, value: state.isExpanded)
        // Content changes crossfade rather than pop.
        .animation(contentAnimation, value: state.activity)
    }
}

/// The expanded pill body: now-playing + controls, battery, next event. Tiles
/// with no reliable data (e.g. AirDrop) are omitted rather than faked.
struct ExpandedView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    let actions: NotchActions
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 14) {
            NowPlayingTile(nowPlaying: state.nowPlaying, actions: actions)
                .frame(maxWidth: .infinity)

            if settings.showBattery, let battery = state.battery {
                Divider().overlay(Color.white.opacity(0.12))
                BatteryTile(battery: battery)
                    .frame(width: 64)
                    .transition(.opacity)
            }

            if settings.showCalendar, let event = state.nextEvent {
                Divider().overlay(Color.white.opacity(0.12))
                CalendarTile(event: event)
                    .frame(width: 138)
                    .transition(.opacity)
            }

            if settings.showFileShelf {
                Divider().overlay(Color.white.opacity(0.12))
                ShelfTile(shelf: shelf)
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
        .animation(.easeInOut(duration: 0.2), value: shelf.items)
        .animation(.easeInOut(duration: 0.15), value: shelf.isDropTargeted)
    }
}
