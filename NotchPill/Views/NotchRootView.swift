import SwiftUI

/// The overlay's SwiftUI surface. A black notch-shaped background grows from the
/// physical notch into a pill on hover; content crossfades between states rather
/// than popping.
struct NotchRootView: View {
    @ObservedObject var state: NotchState
    @ObservedObject var shelf: ShelfStore
    @ObservedObject var tokens: TokenUsageStore = .shared
    /// Observed for its side effect on the deck: `expandedActivities` reads
    /// `ClipboardStore.shared`, and without a dependency here a new copy
    /// never redraws the card.
    @ObservedObject var clipboard: ClipboardStore = .shared
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

    private var selectedMedia: NowPlaying? {
        // Peeks and reply/update overlays borrow the same root surface. Keep
        // their background black even when media remains the selected deck page.
        let activities = expandedActivities
        return MediaBackdropSelection.resolve(
            isExpanded: state.isExpanded,
            isCollapsing: state.isCollapsing,
            hasDevReadyAlerts: !state.renderedDevReadyAlerts.isEmpty,
            hasReplyCompose: state.replyCompose != nil,
            hasUpdateProgress: state.updateProgress != nil,
            activities: activities,
            selectedPage: state.resolvedExpandedDeckPage(for: activities.map(\.kind))
        )
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
                metrics: metrics, activities: expandedActivities)
        }
        return NotchContentLayout.collapsedLayout(metrics: metrics, chips: collapsedChips)
    }

    private var frameSize: CGSize { contentLayout.size }

    private var surfaceTop: CGFloat {
        metrics.notchHeight + NotchContentLayout.surfaceTopInset(metrics: metrics)
    }

    private var surfaceContentHeight: CGFloat {
        NotchContentLayout.surfaceContentHeight(metrics: metrics, surfaceSize: frameSize)
    }

    /// The background and every expanded content mask use this same progress.
    private var surfaceProgress: CGFloat {
        if !state.renderedDevReadyAlerts.isEmpty { return state.devReadyPresentation }
        return (state.isExpanded || state.isCollapsing) ? state.expansionProgress : 1
    }

    private var peekReplacementAnimation: Animation? {
        state.renderedDevReadyAlerts.isEmpty ? nil
            : .timingCurve(0.32, 0.72, 0.15, 1, duration: state.devReadyMotionDuration)
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
        // The host window is positioned immediately; only the visible surface
        // moves, so it can grow cleanly from the physical notch without
        // fighting an AppKit frame animation. A spring, so a hover that
        // reverses mid-flight carries its velocity instead of restarting.
        NotchMotion.surface(reduceMotion: reduceMotion)
    }
    /// In-place value changes: activity, volume, brightness, mic mute.
    ///
    /// This was a flat `.easeOut(duration: 0.1)`. At that length with no spring
    /// a value does not appear to move, it appears to be swapped, and every
    /// state change in the panel read the same dead way. `settle` gives the
    /// change somewhere to arrive.
    private var contentAnimation: Animation {
        NotchMotion.settle(reduceMotion: reduceMotion)
    }

    /// How the collapsed chips cross-fade against the expanded card.
    ///
    /// Only the chips, and the chip pill handing over to the expanded surface,
    /// use this: the card's own opacity is a function of
    /// surface progress (`SurfaceReveal`), and `HoverTransactions` keeps this
    /// curve off anything that progress drives.
    private var contentFadeAnimation: Animation {
        Self.chipCrossfade(opening: state.isExpanded, reduceMotion: reduceMotion)
    }

    /// Opening, the chips leave over exactly the window in which the card
    /// arrives. Closing, the surface spring wins (see `HoverTransactions`)
    /// and the chips only return when the collapse finalises, so this branch
    /// is reached only by a leave that lands before the opening's first frame.
    static func chipCrossfade(opening: Bool, reduceMotion: Bool) -> Animation {
        if reduceMotion { return .linear(duration: 0.01) }
        return opening
            ? NotchMotion.chipsYield(reduceMotion: false)
            : .easeIn(duration: NotchState.hoverAnimationDuration * 0.4)
    }

    /// Collapse finalisation happens after the hover transaction has ended.
    /// Give only the returning chips an insertion fade; removal still inherits
    /// the opening handoff, and neither the host nor the surface gets a new curve.
    static func chipTransition(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(insertion: .opacity.animation(NotchMotion.chipsReturn(reduceMotion: reduceMotion)),
                    removal: .opacity)
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
                    .mask(growingSurfaceMask(progress: surfaceProgress))
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if let compose = state.replyCompose {
                replyComposeContent(compose)
                    .mask(growingSurfaceMask(progress: surfaceProgress))
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
                // The surface, its mask and the content's opacity all read the
                // same animated expansionProgress, so content appears once the
                // shape has made room, leaves ahead of the shrinking edge, and
                // a reversal retraces the curve with no delay to restart.
                expandedContent
                    .mask(growingSurfaceMask(progress: state.expansionProgress))
                    .modifier(SurfaceReveal(progress: state.expansionProgress))
                    .transition(.identity)
            } else if !collapsedChips.isEmpty {
                collapsedContent
                    .mask(compactContentMask)
                    .transition(Self.chipTransition(reduceMotion: reduceMotion))
            }
        }
        // Without the cross-fade the collapsed chips were removed instantly,
        // leaving a gap of empty pill before the card arrived. It wraps the
        // surface as well as the overlay, so the surface curve is layered
        // inside it: collapse changes both values at once, and the innermost
        // animation is the one SwiftUI uses.
        .modifier(HoverTransactions(progress: state.expansionProgress,
                                    isExpanded: state.isExpanded,
                                    surface: expandAnimation,
                                    crossfade: contentFadeAnimation))
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
            Color.clear.frame(height: surfaceTop)
            UpdateProgressView(progress: progress)
                .frame(width: frameSize.width,
                       height: surfaceContentHeight,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private func replyComposeContent(_ compose: ReplyComposeState) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: surfaceTop)
            ReplyComposeView(state: state, compose: compose, actions: actions)
                .frame(width: frameSize.width,
                       height: surfaceContentHeight,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    /// Expanded pill: a single, softly shouldered surface growing from the
    /// physical notch; the top corners stay clear for browser tabs.
    /// The peek surface's silhouette at its current progress, as a mask.
    ///
    /// Deliberately the same geometry `expandedBackground` draws — if the two
    /// drifted, the text would be clipped to a shape that is not the pill.
    private var growingPeekMask: some View {
        growingSurfaceMask(progress: surfaceProgress)
    }

    /// A final canvas with growth owned entirely by the shape. Shrinking its
    /// frame as well would apply progress twice and misalign the content mask.
    private func growingSurfaceMask(progress: CGFloat) -> some View {
        ExpandedNotchShape(notchWidth: metrics.notchWidth,
                          notchHeight: metrics.notchHeight,
                          progress: progress,
                          hasPhysicalNotch: metrics.hasPhysicalNotch,
                          wrapsHardwareNotch: true)
            .fill(Color.black)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
            // A replacement peek can have a new final canvas with progress
            // already at one. Its mask must follow the background's size curve.
            .animation(peekReplacementAnimation, value: frameSize)
    }

    /// Preserve the compact row's existing clipping and chip handoff. Its
    /// shallow canvas is independent of expanded content's shoulder clearance.
    private var compactContentMask: some View {
        let floating = !metrics.hasPhysicalNotch
        let inset = floating ? ExpandedNotchShape.floatingGap : 0
        return NotchShape(bottomRadius: 22, topRadius: floating ? 22 : 0)
            .fill(Color.black)
            .frame(width: frameSize.width, height: max(0, frameSize.height - inset))
            .padding(.top, inset)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }

    private var expandedBackground: some View {
        ExpandedPillSurface(notchWidth: metrics.notchWidth,
                            notchHeight: metrics.notchHeight,
                            progress: surfaceProgress,
                            hasPhysicalNotch: metrics.hasPhysicalNotch,
                          wrapsHardwareNotch: true) {
            // The surface draws its rim over this, so the artwork never
            // hides it and it is not stroked a second time here.
            ZStack {
                if let selectedMedia {
                    MediaBackdrop(nowPlaying: selectedMedia,
                                  size: frameSize)
                        .transition(.opacity)
                }
            }
            .animation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.20),
                       value: selectedMedia?.trackKey)
        }
            .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
            // Growing from the notch is already smooth, because `progress`
            // animates from 0. A peek *replacing* another one is not: dictate
            // twice and the second caption's size arrives with progress already
            // at 1, so the surface jumps straight to the new width. Scoped to
            // while a peek is on screen so the hover curve, which drives its own
            // progress, is left exactly as it was.
            .animation(peekReplacementAnimation, value: frameSize)
    }

    private var expandedContent: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: surfaceTop)
            ExpandedView(
                state: state,
                shelf: shelf,
                timer: timer,
                actions: actions,
                activities: expandedActivities,
                readability: readabilityScale,
                textScale: textScale
            )
                .frame(width: frameSize.width, height: surfaceContentHeight,
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
            Color.clear.frame(height: surfaceTop)
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
                .frame(width: frameSize.width, height: surfaceContentHeight,
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
/// One artwork wash for the entire expanded silhouette, including the space
/// above the media controls. Painting this inside the card leaves a black band
/// between the menu bar and the card's content origin.
struct MediaBackdrop: View {
    let nowPlaying: NowPlaying
    let size: CGSize

    var body: some View {
        ZStack {
            Color.black
            if let artwork = nowPlaying.artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
                    .blur(radius: NotchSpace.section)
                    .clipped()
                    .opacity(NotchOpacity.glow)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.48)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .allowsHitTesting(false)
    }
}

/// Chooses whether artwork may paint behind the expanded surface. Alerts and
/// reply/update overlays own the surface even while a media page is selected.
enum MediaBackdropSelection {
    static func resolve(isExpanded: Bool,
                        isCollapsing: Bool,
                        hasDevReadyAlerts: Bool,
                        hasReplyCompose: Bool,
                        hasUpdateProgress: Bool,
                        activities: [ExpandedActivity],
                        selectedPage: Int) -> NowPlaying? {
        guard (isExpanded || isCollapsing),
              !hasDevReadyAlerts,
              !hasReplyCompose,
              !hasUpdateProgress,
              activities.indices.contains(selectedPage),
              case .media(let nowPlaying) = activities[selectedPage] else { return nil }
        return nowPlaying
    }
}
