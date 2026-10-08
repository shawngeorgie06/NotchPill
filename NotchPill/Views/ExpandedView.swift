import SwiftUI

struct ExpandedView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var tokens: TokenUsageStore = .shared
    /// Observed for its side effect on the deck: `expandedActivities` reads
    /// `ClipboardStore.shared`, and without a dependency here a new copy
    /// never redraws the card.
    @ObservedObject var clipboard: ClipboardStore = .shared
    @ObservedObject var timer: TimerStore
    let actions: NotchActions
    let activities: [ExpandedActivity]
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0
    /// Optional test/preview control. Nil follows the system accessibility setting.
    var reduceMotionOverride: Bool?
    @State private var pageDragOffset: CGFloat = 0
    @State private var swipeGeneration = 0
    @State private var showingDeckPicker = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    var body: some View {
        Group {
            if activities.isEmpty {
                NotchEmptyState(symbol: "square.grid.2x2", title: "Your island is ready",
                                detail: "Choose which cards appear in Settings.",
                                actionTitle: "Open Settings", action: actions.openSettings,
                                scale: readability, textScale: textScale, reduceMotion: reduceMotion)
            } else {
                activityDeck
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        // Keyed on the track, not the whole value. `NowPlaying` carries
        // `isPlaying`, so animating on it made pause reflow the entire deck —
        // the sideways slide that reads as "skipped to the next song". Play and
        // pause are now a local symbol morph instead; see `mediaCard`.
        .animation(.easeOut(duration: 0.16), value: state.nowPlaying?.trackKey)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: state.appSwitchHint)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: state.frontmostApp)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: state.systemVolume)
        // Keyed on contents, not identity. Identity drives the page slide (see
        // `ExpandedActivity.id`); this only smooths a card growing or shrinking
        // around what changed inside it.
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: activities.map(\.contentKey))
        .onChange(of: activityKinds) { _, kinds in
            swipeGeneration += 1
            pageDragOffset = 0
            state.reconcileExpandedDeck(kinds: kinds)
            if kinds.isEmpty, showingDeckPicker { closeDeckPicker() }
        }
        .onDisappear {
            if showingDeckPicker { closeDeckPicker() }
        }
    }

    /// Keep one full-width stage for every page. Each tray card gets its own
    /// insets, while media paints edge to edge; this lets a neighboring page
    /// follow a drag without changing its size at the end of the swipe.
    private var activityDeck: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottom) {
                if showingDeckPicker {
                    deckPickerOverview(width: geo.size.width, height: geo.size.height)
                } else {
                    pageCard(width: geo.size.width, height: geo.size.height)
                }
                if !showingDeckPicker && NotchContentLayout.showsDeckChrome(for: activities) {
                    deckChrome
                        .padding(.horizontal, NotchSpace.base * readability)
                        .padding(.bottom, NotchSpace.base * readability)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(pageSwipeGesture(width: geo.size.width))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func pageCard(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .top) {
            if pageDragOffset > 0, activities.indices.contains(clampedPage - 1) {
                activityCard(at: clampedPage - 1, width: width, height: height)
                    .offset(x: -width + pageDragOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if pageDragOffset < 0, activities.indices.contains(clampedPage + 1) {
                activityCard(at: clampedPage + 1, width: width, height: height)
                    .offset(x: width + pageDragOffset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if activities.indices.contains(clampedPage) {
                activityCard(at: clampedPage, width: width, height: height)
                    .id(activities[clampedPage].id)
                    .offset(x: pageDragOffset)
                    .transition(pageTransition)
            }
        }
        .frame(width: width, height: height, alignment: .top)
    }

    private func activityCard(at index: Int, width: CGFloat, height: CGFloat) -> some View {
        let isMedia: Bool = {
            if case .media = activities[index] { return true }
            return false
        }()
        let horizontalInset = isMedia ? 0 : NotchSpace.section * readability
        let topInset = isMedia ? 0 : NotchSpace.base * readability
        let bottomInset = isMedia ? 0 : NotchSpace.base * readability
            + NotchContentLayout.deckChromeHeight
        return ExpandedActivityCard(
                activity: activities[index],
                appIcon: state.frontmostAppIcon,
                actions: actions,
                onCancelTimer: { timer.cancel() },
                readability: readability,
                textScale: textScale,
                expandToFill: true,
                reduceMotionOverride: reduceMotionOverride,
                bottomChromeHeight: isMedia
                    ? NotchContentLayout.deckChromeHeight + NotchSpace.base * 2 : 0,
                tokenUsage: settings.showTokenUsage ? tokens.summary : nil,
                tokenPeriod: settings.resolvedTokenPeriod
            )
            .frame(width: max(0, width - horizontalInset * 2),
                   height: max(0, height - topInset - bottomInset), alignment: .top)
            .padding(.horizontal, horizontalInset)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .frame(width: width, height: height, alignment: .top)
            .background {
                // The root paints the selected media page. A page entering
                // during a drag needs its own wash (or black tray) until it
                // becomes selected, so the background follows the card.
                if index != clampedPage {
                    if case .media(let nowPlaying) = activities[index] {
                        MediaBackdrop(nowPlaying: nowPlaying,
                                      size: CGSize(width: width, height: height))
                    } else {
                        Color.black
                    }
                }
            }
    }

    private func pageSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard !showingDeckPicker, !reduceMotion, activities.count > 1,
                      abs(value.translation.width) > abs(value.translation.height) * 1.1 else { return }
                // A new drag takes ownership from any page settle still in
                // flight; its completion must not change the page afterward.
                swipeGeneration += 1
                let distance = value.translation.width
                let hasNeighbor = activities.indices.contains(clampedPage + (distance < 0 ? 1 : -1))
                // A small resistant movement at either end acknowledges the
                // gesture without suggesting that another page exists.
                pageDragOffset = hasNeighbor
                    ? min(width * 0.95, max(-width * 0.95, distance))
                    : min(18, max(-18, distance * 0.15))
            }
            .onEnded { value in
                guard !showingDeckPicker, activities.count > 1,
                      abs(value.translation.width) > abs(value.translation.height) * 1.1 else {
                    withAnimation(NotchMotion.page(reduceMotion: reduceMotion)) { pageDragOffset = 0 }
                    return
                }
                let direction = value.translation.width < 0 ? 1 : -1
                let target = clampedPage + direction
                let projected = value.predictedEndTranslation.width
                let commits = abs(value.translation.width) > width * 0.22 ||
                    abs(projected) > width * 0.42
                guard activities.indices.contains(target), commits else {
                    withAnimation(NotchMotion.page(reduceMotion: reduceMotion)) { pageDragOffset = 0 }
                    return
                }
                if reduceMotion {
                    state.selectExpandedDeckPage(target, kinds: activityKinds)
                    return
                }
                swipeGeneration += 1
                let generation = swipeGeneration
                let targetKind = activities[target].kind
                withAnimation(NotchMotion.page(reduceMotion: false), completionCriteria: .logicallyComplete) {
                    pageDragOffset = CGFloat(-direction) * width
                } completion: {
                    guard swipeGeneration == generation,
                          activities.indices.contains(target),
                          activities[target].kind == targetKind else { return }
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        state.selectExpandedDeckPage(target, kinds: activityKinds)
                        pageDragOffset = 0
                    }
                }
            }
    }

    /// A compact route to the in-canvas overview keeps every page reachable
    /// without adding a control for every card to the footer.
    private var deckChrome: some View {
        let items = NotchDeckPickerItem.items(for: activityKinds)
        let selected = items.first { $0.kind == activities[clampedPage].kind }
        return HStack(spacing: NotchSpace.snug * readability) {
            Button {
                showingDeckPicker = true
                actions.holdNotchOpen(true)
            } label: {
                HStack(spacing: NotchSpace.tight * readability) {
                    if let selected {
                        Image(systemName: selected.symbolName)
                            .font(.system(size: NotchType.caption * textScale, weight: .semibold))
                            .accessibilityHidden(true)
                        Text(selected.title)
                            .font(.system(size: NotchType.caption * textScale, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: NotchType.caption * textScale, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .padding(.horizontal, NotchSpace.base * readability)
                .frame(height: NotchSpace.mark * readability)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 210 * readability, alignment: .leading)
            .accessibilityLabel("Choose card")
            .accessibilityValue(selected?.title ?? "")
            .accessibilityHint("Card \(clampedPage + 1) of \(activities.count). Opens all cards.")

            if let position = NotchDeckPickerItem.positionLabel(page: clampedPage,
                                                                 count: activities.count) {
                Text(position)
                    .font(.system(size: NotchType.mono * textScale, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .padding(.horizontal, NotchSpace.bar * readability)
                    .frame(height: NotchSpace.mark * readability)
                    .background(.white.opacity(0.06), in: Capsule())
                    .accessibilityLabel("Card \(clampedPage + 1) of \(activities.count)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .frame(height: NotchSpace.mark * readability)
        .contentShape(Rectangle())
        .animation(NotchMotion.page(reduceMotion: reduceMotion), value: clampedPage)
    }

    /// Scrollable overview inside the existing deck canvas. The frame is
    /// shared with every card, so opening the picker never changes the notch
    /// size or creates a floating panel that can be clipped by the display.
    private func deckPickerOverview(width: CGFloat, height: CGFloat) -> some View {
        NotchCardPicker(items: NotchDeckPickerItem.items(for: activityKinds),
                        selectedKind: activities.indices.contains(clampedPage) ? activities[clampedPage].kind : nil,
                        scale: readability, textScale: textScale, reduceMotion: reduceMotion,
                        onSelect: { kind in
                            guard let index = activityKinds.firstIndex(of: kind) else { return }
                            withAnimation(NotchMotion.page(reduceMotion: reduceMotion)) {
                                state.selectExpandedDeckPage(index, kinds: activityKinds)
                            }
                            closeDeckPicker()
                        }, onClose: closeDeckPicker)
            .frame(width: width, height: height, alignment: .top)
    }

    private func closeDeckPicker() {
        showingDeckPicker = false
        actions.holdNotchOpen(false)
    }

    private var clampedPage: Int {
        state.resolvedExpandedDeckPage(for: activityKinds)
    }

    private var activityKinds: [String] { activities.map(\.kind) }

    private var pageTransition: AnyTransition {
        let entering: Edge = state.expandedDeckDirection >= 0 ? .trailing : .leading
        let leaving: Edge = state.expandedDeckDirection >= 0 ? .leading : .trailing
        let scale = NotchMotion.pageScale
        return .asymmetric(
            insertion: .move(edge: entering)
                .combined(with: .opacity)
                .combined(with: .scale(scale: scale)),
            removal: .move(edge: leaving)
                .combined(with: .opacity)
                .combined(with: .scale(scale: scale))
        )
    }

}
