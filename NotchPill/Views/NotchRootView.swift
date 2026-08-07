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
        if state.updateProgress != nil {
            return NotchContentLayout.updateLayout(metrics: metrics)
        }
        if let compose = state.replyCompose {
            return NotchContentLayout.replyComposeLayout(
                metrics: metrics,
                hasQuestion: compose.contextText != nil
            )
        }
        let renderedAlerts = state.renderedDevReadyAlerts
        if !renderedAlerts.isEmpty {
            if renderedAlerts.contains(where: { $0.kind == .waiting }) {
                return NotchContentLayout.waitingLayout(metrics: metrics, alerts: renderedAlerts)
            }
            return NotchContentLayout.devReadyLayout(metrics: metrics, alerts: renderedAlerts)
        }
        if state.isExpanded || state.isCollapsing {
            return NotchContentLayout.expandedDeckLayout(
                metrics: metrics, activities: expandedActivities,
                page: state.resolvedExpandedDeckPage(for: expandedActivities.map(\.kind)))
        }
        return NotchContentLayout.collapsedLayout(metrics: metrics, chips: collapsedChips)
    }

    private var frameSize: CGSize { contentLayout.size }

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
        // The host window is positioned immediately; only the visible surface
        // moves. This longer curve can therefore grow cleanly from the physical
        // notch without fighting an AppKit frame animation.
        reduceMotion ? .linear(duration: 0.01) : .timingCurve(0.22, 0.8, 0.2, 1, duration: NotchState.hoverAnimationDuration)
    }
    private var contentAnimation: Animation {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.1)
    }

    /// How the expanded card's copy fades against the surface growing behind
    /// it. Deliberately asymmetric.
    ///
    /// Opening, it waits: for the first third of the growth the pill is still
    /// close to notch width, and copy drawn into it can only be clipped or
    /// squeezed. Letting the surface open the room first, then filling it,
    /// reads as one movement rather than two racing.
    ///
    /// Closing, it leaves ahead of the surface, and faster — text that stays
    /// crisp while its container shrinks underneath is the same clipping seen
    /// backwards, and it is the more noticeable of the two.
    private var contentFadeAnimation: Animation {
        if reduceMotion { return .linear(duration: 0.01) }
        let full = NotchState.hoverAnimationDuration
        return state.isExpanded
            ? .easeOut(duration: full * 0.6).delay(full * 0.34)
            : .easeIn(duration: full * 0.4)
    }

    var body: some View {
        ZStack(alignment: .top) {
            if state.isExpanded || state.isCollapsing || !state.renderedDevReadyAlerts.isEmpty || state.updateProgress != nil || state.replyCompose != nil {
                expandedBackground
            } else if !collapsedChips.isEmpty {
                // The physical notch itself is already black. Only draw the
                // compact island that grows from its lower edge.
                ExpandedPillSurface(
                    notchWidth: metrics.notchWidth,
                    notchHeight: metrics.notchHeight,
                    progress: 1,
                    hasPhysicalNotch: metrics.hasPhysicalNotch
                )
                .frame(width: frameSize.width, height: frameSize.height)
            }
        }
        .overlay(alignment: .top) {
            if let progress = state.updateProgress {
                updateProgressContent(progress)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if let compose = state.replyCompose {
                replyComposeContent(compose)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if !state.renderedDevReadyAlerts.isEmpty {
                devReadyContent(alerts: state.renderedDevReadyAlerts)
                    // Clip the text to the surface that is growing behind it.
                    //
                    // The content is an overlay laid out at the *final* size, so
                    // a caption's full width was drawn on frame one and the pill
                    // spent the animation catching up to text that was already
                    // there. That is the pop: nothing about the fade fixes it,
                    // because the text was never the wrong opacity — it was the
                    // wrong size. Masked, the words are revealed by the pill as
                    // it opens and covered as it closes.
                    .mask(growingPeekMask)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if state.isExpanded || state.isCollapsing {
                // Tied to the surface rather than to `isExpanded`. The
                // transition below never had an animation in scope for that
                // flag, so the whole card was inserted at full opacity on the
                // frame hover began — one frame *before* the pill started
                // growing. You saw the content first and the container catching
                // up to it, which is the "pop" on open; on close the reverse,
                // full-size copy held sharp inside a shrinking surface until it
                // was cut off.
                expandedContent
                    .opacity(Double(state.expansionProgress))
                    .animation(contentFadeAnimation, value: state.expansionProgress)
                    .transition(.identity)
            } else if !collapsedChips.isEmpty {
                collapsedContent
                    .transition(.opacity)
            }
        }
        // Scoped to the overlay, not the outer layout — the note above about a
        // sideways pop still stands, and this must not reach the frame.
        //
        // Without it the collapsed chips were *also* removed instantly, so
        // pairing them with a card that now fades in left a gap of empty pill
        // between the two. With it they fade out on the same curve the card
        // fades in on, and the swap becomes a crossfade.
        .animation(contentFadeAnimation, value: state.isExpanded)
        .overlay {
            VStack(spacing: 8) {
                if settings.showVolumeHUD, let level = state.volumeLevel {
                    VolumeHUD(level: level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if settings.showBrightnessHUD, let level = state.brightnessLevel {
                    BrightnessHUD(level: level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if settings.showMicrophoneHUD, let muted = state.microphoneMuted {
                    MicrophoneHUD(isMuted: muted)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(true)
        // The island itself owns the hover transition through
        // `expansionProgress`. Animating the surrounding layout at the same
        // time lets SwiftUI interpolate a second width/position, which reads
        // as a brief sideways pop after an otherwise smooth expansion.
        .animation(expandAnimation, value: state.expansionProgress)
        .animation(contentAnimation, value: state.activity)
        .animation(contentAnimation, value: state.volumeLevel)
        .animation(contentAnimation, value: state.brightnessLevel)
        .animation(contentAnimation, value: state.microphoneMuted)
        .animation(.easeOut(duration: 0.12), value: state.updateProgress?.fraction)
    }

    private func updateProgressContent(_ progress: UpdateProgress) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            UpdateProgressView(progress: progress)
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width,
                       height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private func replyComposeContent(_ compose: ReplyComposeState) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            ReplyComposeView(state: state, compose: compose, actions: actions)
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width,
                       height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private var collapsedBottomRadius: CGFloat {
        collapsedChips.isEmpty ? max(8, metrics.notchHeight / 2) : 12
    }

    /// Expanded pill: a single, softly shouldered surface growing from the
    /// physical notch; the top corners stay clear for browser tabs.
    /// The peek surface's silhouette at its current progress, as a mask.
    ///
    /// Deliberately the same geometry `expandedBackground` draws — if the two
    /// drifted, the text would be clipped to a shape that is not the pill.
    private var growingPeekMask: some View {
        let progress = state.devReadyPresentation
        let width = metrics.notchWidth + (frameSize.width - metrics.notchWidth) * progress
        let height = metrics.notchHeight + (frameSize.height - metrics.notchHeight) * progress
        let floating = !metrics.hasPhysicalNotch
        let inset = floating ? 4 * progress : 0
        return NotchShape(bottomRadius: 22, topRadius: floating ? 22 : 0)
            .fill(Color.black)
            .frame(width: width, height: max(0, height - inset))
            .padding(.top, inset)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private var expandedBackground: some View {
        // Match the intended island silhouette: a single compact black surface
        // that begins as the notch and grows outward from its centre.
        let progress: CGFloat
        if !state.renderedDevReadyAlerts.isEmpty {
            progress = state.devReadyPresentation
        } else {
            progress = (state.isExpanded || state.isCollapsing) ? state.expansionProgress : 1
        }
        let width = metrics.notchWidth + (frameSize.width - metrics.notchWidth) * progress
        let height = metrics.notchHeight + (frameSize.height - metrics.notchHeight) * progress
        // With no cutout above it, the surface needs its own top: rounded
        // corners, and a few points of daylight under the menu bar so it reads
        // as an island rather than as something that failed to dock.
        let floating = !metrics.hasPhysicalNotch
        let inset = floating ? 4 * progress : 0
        return PillSurface(bottomRadius: 22, topRadius: floating ? 22 : 0)
            .frame(width: width, height: max(0, height - inset))
            .padding(.top, inset)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
            // Growing from the notch is already smooth, because `progress`
            // animates from 0. A peek *replacing* another one is not: dictate
            // twice and the second caption's size arrives with progress already
            // at 1, so the surface jumps straight to the new width. Scoped to
            // while a peek is on screen so the hover curve, which drives its own
            // progress, is left exactly as it was.
            .animation(state.renderedDevReadyAlerts.isEmpty
                       ? nil
                       : .timingCurve(0.32, 0.72, 0.15, 1,
                                      duration: state.devReadyMotionDuration),
                       value: frameSize)
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
                .frame(width: frameSize.width, height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
        .opacity(contentReveal)
        .scaleEffect(0.96 + contentReveal * 0.04, anchor: .top)
    }

    /// Hold the content until the surface is wide enough to contain it. The
    /// visual order is therefore notch → surface → cards, rather than all three
    /// appearing at once.
    private var contentReveal: CGFloat {
        min(1, max(0, (state.expansionProgress - 0.5) / 0.5))
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
                // The scroller must be given the same waiting allowance the window
                // frame was sized with, or a "waiting for A + finished for B" pair
                // squeezes the tall waiting row into a flat 42pt/row scroller while
                // the window itself grows — you'd have to scroll the notch overlay
                // to reach the answer buttons.
                maxScrollHeight: alerts.count > 1
                    ? NotchContentLayout.devReadyListHeight(rowCount: alerts.count)
                        + NotchContentLayout.waitingExtraHeight(alerts: alerts)
                    : nil,
                pinnedIDs: state.pinnedPeekIDs,
                // The same measurement the window was sized with. Handing the
                // row anything else is how a title ends up with a line limit
                // computed for a width it is not being drawn at.
                titleLines: NotchContentLayout
                    .peekTitleLayout(metrics: metrics, alerts: alerts).lines
            )
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width, height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
        .opacity(state.devReadyPresentation)
        .offset(y: (1 - state.devReadyPresentation) * -8)
        .scaleEffect(0.96 + state.devReadyPresentation * 0.04, anchor: .top)
    }
}

/// In-notch reply composer: a focused text field targeting the finished agent.
struct ReplyComposeView: View {
    @ObservedObject var state: NotchState
    let compose: ReplyComposeState
    let actions: NotchActions
    @FocusState private var fieldFocused: Bool

    private var targetLabel: String {
        let a = compose.targetAlert
        let terminal = a.source ?? "Terminal"
        return "→ \(a.title) · \(terminal)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchDesign.accent)
                Text(targetLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    // Close the composer and dismiss this agent's peek entirely.
                    state.cancelReply()
                    actions.dismissDevReady(compose.targetAlert.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            // The question, verbatim, above the field. The whole point of
            // answering from the notch is not having to switch back to the
            // terminal — which you'd have to do just to re-read what was asked.
            if let context = compose.contextText {
                Text(context)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(compose.mode == .planRevision ? "What should change?" : (compose.targetAlert.submitsOnDelivery
                       ? (compose.targetAlert.replyContextText != nil ? "Your answer…" : "Reply…")
                       : "Reply… (press ⏎ there to send)"),
                      text: Binding(
                get: { state.replyCompose?.draft ?? "" },
                set: { state.updateReplyDraft($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .focused($fieldFocused)
            .onSubmit {
                let draft = state.replyCompose?.draft ?? ""
                if compose.mode == .planRevision {
                    actions.submitPlanRevision(compose.targetAlert, draft)
                } else {
                    actions.sendReply(compose.targetAlert, draft)
                }
            }
            .onExitCommand { state.cancelReply() }   // Esc
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            if let err = compose.errorText {
                Text(err)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text(compose.mode == .planRevision ? "Enter to request revision · ✕ to close" : "Enter to send · ✕ to close")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fieldFocused = true }
    }
}

/// Live in-app update: title, a filling progress bar, and a status line.
struct UpdateProgressView: View {
    let progress: UpdateProgress

    private var isFailed: Bool { progress.phase == .failed }
    private var barFraction: CGFloat {
        // The download is the measurable bulk; later phases are quick, so show a
        // full bar for them (the label communicates the phase).
        progress.phase == .downloading ? CGFloat(progress.fraction) : 1
    }
    private var accent: Color { isFailed ? .orange : NotchDesign.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accent)
                Text(progress.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(accent)
                        .frame(width: max(6, geo.size.width * barFraction))
                }
            }
            .frame(height: 7)
            Text(progress.statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Expanded pill: live status cards sized to how many are visible.
struct ExpandedView: View {
    @ObservedObject var settings = AppSettings.shared
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
                activityDeck
            }
        }
        .padding(.horizontal, 9)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.16), value: state.nowPlaying)
        .animation(.easeOut(duration: 0.14), value: state.appSwitchHint)
        .animation(.easeOut(duration: 0.14), value: state.frontmostApp)
        .animation(.easeOut(duration: 0.12), value: state.systemVolume)
        .animation(.easeOut(duration: 0.14), value: activities.map(\.id))
        .onChange(of: activityKinds) { _, kinds in
            state.reconcileExpandedDeck(kinds: kinds)
        }
    }

    /// One readable card at a time. The old row made every card narrower as
    /// new signals appeared; this deck makes new signals discoverable without
    /// changing the island's silhouette or shrinking their text.
    private var activityDeck: some View {
        VStack(spacing: 5 * readability) {
            ZStack {
                if activities.indices.contains(clampedPage) {
                    ExpandedActivityCard(
                        activity: activities[clampedPage],
                        appIcon: state.frontmostAppIcon,
                        actions: actions,
                        onCancelTimer: { timer.cancel() },
                        readability: readability,
                        textScale: textScale,
                        expandToFill: true
                    )
                    .id(activities[clampedPage].id)
                    .transition(pageTransition)
                    .padding(.horizontal, 3)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24)
                    .onEnded { value in
                        if value.translation.width < -24 { selectNextPage() }
                        if value.translation.width > 24 { selectPreviousPage() }
                    }
            )
            .animation(.easeOut(duration: 0.16), value: clampedPage)

            if activities.count > 1 {
                HStack(spacing: 7) {
                    Label(activityLabel(activities[clampedPage]), systemImage: activityIcon(activities[clampedPage]))
                        .font(.system(size: 9 * textScale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)

                    Spacer(minLength: 0)

                    // No chevrons. They were the last of the arrows: two tap
                    // targets restating what the dots already show and the
                    // swipe already does, spending 52pt of a strip that is
                    // narrow to begin with. The dots stay tappable, so nothing
                    // that could be reached by an arrow became unreachable.
                    HStack(spacing: 4) {
                        ForEach(Array(activities.indices), id: \.self) { index in
                            Button { state.selectExpandedDeckPage(index, kinds: activityKinds) } label: {
                                Capsule()
                                    .fill(index == clampedPage ? Color.white.opacity(0.9) : .white.opacity(0.22))
                                    .frame(width: index == clampedPage ? 12 : 4, height: 4)
                                    .frame(width: 16, height: 22)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show \(activityLabel(activities[index]))")
                        }
                    }

                }
                .font(.system(size: 9 * textScale, weight: .semibold))
            }
        }
    }

    private var clampedPage: Int {
        state.resolvedExpandedDeckPage(for: activityKinds)
    }

    private var activityKinds: [String] { activities.map(\.kind) }

    private var pageTransition: AnyTransition {
        let entering: Edge = state.expandedDeckDirection >= 0 ? .trailing : .leading
        let leaving: Edge = state.expandedDeckDirection >= 0 ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    private func selectPreviousPage() {
        state.moveExpandedDeckPage(by: -1, kinds: activityKinds)
    }

    private func selectNextPage() {
        state.moveExpandedDeckPage(by: 1, kinds: activityKinds)
    }

    private func activityLabel(_ activity: ExpandedActivity) -> String {
        switch activity.kind {
        // Two deliberate departures from `kindLabel`: on the card footer these
        // read better as what you are looking *at* than as the settings row's
        // name for the toggle.
        case "codexQuota": return "Codex usage"
        case "recentAlerts": return "Recent notifications"
        // Everything else takes the model's own label.
        //
        // The default used to be `kind.capitalized`, and `kind` is camelCase —
        // so `claudeQuota` rendered as "Claudequota". Swift's `capitalized`
        // uppercases the first letter of each *word* and lowercases the rest,
        // and a camelCase identifier is one word to it. Same bug on
        // `cursorQuota`, `activeApp`, `systemStats`, and `ci` ("Ci"). Deriving
        // display text from an identifier was the mistake; `kindLabel` exists
        // for exactly this and is written by hand.
        default: return activity.kindLabel
        }
    }

    private func activityIcon(_ activity: ExpandedActivity) -> String {
        switch activity.kind {
        case "agents": return "terminal"
        case "codexQuota": return "chevron.left.forwardslash.chevron.right"
        case "openCodeUsage": return "curlybraces"
        case "ci": return "checkmark.seal"
        case "recentAlerts": return "bell"
        case "media": return "music.note"
        case "calendar": return "calendar"
        case "timer": return "timer"
        case "battery": return "battery.100"
        case "systemStats": return "gauge.with.dots.needle.50percent"
        default: return "circle.grid.2x2"
        }
    }
}
