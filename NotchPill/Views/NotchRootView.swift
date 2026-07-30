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
                hasQuestion: compose.targetAlert.questionText != nil
            )
        }
        if !state.devReadyAlerts.isEmpty {
            if state.devReadyAlerts.contains(where: { $0.kind == .waiting }) {
                return NotchContentLayout.waitingLayout(metrics: metrics, alerts: state.devReadyAlerts)
            }
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
            if state.isExpanded || !state.devReadyAlerts.isEmpty || state.updateProgress != nil || state.replyCompose != nil {
                expandedBackground
            } else {
                PillSurface(bottomRadius: collapsedBottomRadius)
                    .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            }
        }
        .overlay(alignment: .top) {
            if let progress = state.updateProgress {
                updateProgressContent(progress)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if let compose = state.replyCompose {
                replyComposeContent(compose)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if !state.devReadyAlerts.isEmpty {
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
            VStack(spacing: 8) {
                if let level = state.volumeLevel {
                    VolumeHUD(level: level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if let level = state.brightnessLevel {
                    BrightnessHUD(level: level)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
                if let muted = state.microphoneMuted {
                    MicrophoneHUD(isMuted: muted)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
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
        .animation(contentAnimation, value: state.brightnessLevel)
        .animation(contentAnimation, value: state.microphoneMuted)
        .animation(expandAnimation, value: state.devReadyAlerts.map(\.id))
        .animation(expandAnimation, value: state.replyCompose != nil)
        .animation(expandAnimation, value: state.updateProgress?.phase)
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
                // The scroller must be given the same waiting allowance the window
                // frame was sized with, or a "waiting for A + finished for B" pair
                // squeezes the tall waiting row into a flat 42pt/row scroller while
                // the window itself grows — you'd have to scroll the notch overlay
                // to reach the answer buttons.
                maxScrollHeight: alerts.count > 1
                    ? NotchContentLayout.devReadyListHeight(rowCount: alerts.count)
                        + NotchContentLayout.waitingExtraHeight(alerts: alerts)
                    : nil
            )
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width, height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
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
            if let question = compose.targetAlert.questionText {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TextField(compose.targetAlert.questionText != nil ? "Your answer…" : "Reply…",
                      text: Binding(
                get: { state.replyCompose?.draft ?? "" },
                set: { state.updateReplyDraft($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .focused($fieldFocused)
            .onSubmit { actions.sendReply(compose.targetAlert, state.replyCompose?.draft ?? "") }
            .onExitCommand { state.cancelReply() }   // Esc
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            if let err = compose.errorText {
                Text(err)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("Enter to send · ✕ to close")
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
                cardRow
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
    }

    /// The row, split by the per-card weights.
    ///
    /// `GeometryReader` rather than layout priorities: priorities express "who
    /// wins when space is tight", but the setting is a *share* — 80/20 has to
    /// mean 80/20 whether or not anything is tight. Dividers are subtracted
    /// first so the shares apply to the space the cards actually get.
    private var cardRow: some View {
        let spacing = 7 * readability
        let shares = AppSettings.shares(for: activities.map(\.kind),
                                        weights: settings.cardWeights)
        return GeometryReader { geo in
            let dividers = CGFloat(max(0, activities.count - 1))
            let usable = max(0, geo.size.width - dividers * (1 + spacing * 2))
            HStack(spacing: spacing) {
                ForEach(Array(activities.enumerated()), id: \.element.id) { index, activity in
                    ExpandedActivityCard(
                        activity: activity,
                        appIcon: state.frontmostAppIcon,
                        actions: actions,
                        onCancelTimer: { timer.cancel() },
                        readability: readability,
                        textScale: textScale,
                        expandToFill: true
                    )
                    .frame(width: usable * CGFloat(shares[activity.kind] ?? 0))
                    if index < activities.count - 1 {
                        Rectangle()
                            .fill(Color.white.opacity(0.1))
                            .frame(width: 1)
                            .padding(.vertical, 2 * readability)
                    }
                }
            }
            .frame(width: geo.size.width, alignment: .leading)
        }
    }
}
