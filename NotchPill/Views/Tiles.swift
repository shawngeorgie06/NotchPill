import SwiftUI

/// Compact media row for the top of the expanded pill.
struct ExpandedMediaRow: View {
    let nowPlaying: NowPlaying?
    let actions: NotchActions

    var body: some View {
        HStack(spacing: 10) {
            artwork
            VStack(alignment: .leading, spacing: 1) {
                Text(nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying?.artist ?? "—")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            controls
        }
        .modifier(MediaTransportSwipe(actions: actions))
        .accessibilityHint("Swipe left for next track or right for previous track")
    }

    private var artwork: some View {
        Group {
            if let image = nowPlaying?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                        .font(.system(size: 14))
                }
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 14) {
            transportButton("backward.fill", action: actions.previous)
            transportButton(nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 22, action: actions.togglePlayPause)
            transportButton("forward.fill", action: actions.next)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat = 18, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Now Playing (legacy full tile — kept for reference/tests)

struct NowPlayingTile: View {
    let nowPlaying: NowPlaying?
    let actions: NotchActions

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying?.artist ?? "—")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                controls
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var artwork: some View {
        Group {
            if let image = nowPlaying?.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(size: 18))
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 18) {
            transportButton("backward.fill", action: actions.previous)
            transportButton(nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 24, action: actions.togglePlayPause)
            transportButton("forward.fill", action: actions.next)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat = 20, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Calendar

struct CalendarPlaceholderTile: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Calendar", systemImage: "calendar")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange.opacity(0.7))
            Text("No upcoming events")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

struct CalendarTile: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(relativeStart, systemImage: "calendar")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Text(event.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(timeString)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private var relativeStart: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "in " + formatter.localizedString(for: event.start, relativeTo: Date())
            .replacingOccurrences(of: "in ", with: "")
    }

    private var timeString: String {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df.string(from: event.start)
    }
}

// MARK: - Volume HUD

/// Brief overlay shown when volume is adjusted via keyboard shortcuts.
struct VolumeHUD: View {
    let level: Int

    var body: some View {
        SystemLevelHUD(icon: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       label: "Volume", level: level)
    }
}

/// Brief overlay shown when the built-in display brightness changes.
struct BrightnessHUD: View {
    let level: Int

    var body: some View {
        SystemLevelHUD(icon: "sun.max.fill", label: "Brightness", level: level)
    }
}

/// Brief overlay shown when the default input device reports a mute change.
struct MicrophoneHUD: View {
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22)
            Text(isMuted ? "Microphone muted" : "Microphone on")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background { SystemHUDBackground() }
        .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
        .offset(y: 52)
    }
}

private struct SystemLevelHUD: View {
    let icon: String
    let label: String
    let level: Int

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 18)
                Text(label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                Spacer(minLength: 0)
                Text("\(level)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(NotchOpacity.highlight))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: geo.size.width * CGFloat(min(max(level, 0), 100)) / 100)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background { SystemHUDBackground() }
        .shadow(color: .black.opacity(0.32), radius: 8, y: 4)
        .offset(y: 52)
    }
}

private struct SystemHUDBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(Color.black)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(NotchDesign.pillStroke, lineWidth: 0.5)
            }
    }
}

// MARK: - Dev ready peek

/// One or more agent-ready rows when tasks finish around the same time.
struct DevReadyPeekListView: View {
    let alerts: [DevReadyAlert]
    let actions: NotchActions
    /// When set, the row list scrolls inside this height (used for multiple agents).
    var maxScrollHeight: CGFloat?
    var pinnedIDs: Set<String> = []
    /// Measured line counts, keyed by alert id — see `peekTitleLayout`.
    var titleLines: [String: Int] = [:]

    private var orderedAlerts: [DevReadyAlert] { DevReadyAlert.focusOrdered(alerts) }
    private var focusedAlert: DevReadyAlert? { orderedAlerts.first }
    private var queuedCount: Int { max(0, orderedAlerts.count - 1) }

    var body: some View {
        VStack(spacing: 0) {
            // The layout reserves this header only for a multi-item burst. A
            // single row is already visually focused, and adding chrome above
            // it would make its fixed-height peek clip.
            if alerts.count > 1, let focusedAlert {
                HStack(spacing: 6) {
                    Image(systemName: focusedAlert.kind == .waiting
                          ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(accent(for: focusedAlert))
                    Text(focusedAlert.kind == .waiting ? "Needs you" : "In focus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    if queuedCount > 0 {
                        Text("· \(queuedCount) more \(queuedCount == 1 ? "activity" : "activities")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }

            if let maxScrollHeight, alerts.count > 1 {
                ScrollView(.vertical, showsIndicators: true) {
                    alertRows
                }
                .frame(height: maxScrollHeight)
            } else {
                alertRows
            }
        }
    }

    private var alertRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(orderedAlerts.enumerated()), id: \.element.id) { index, alert in
                DevReadyPeekRow(alert: alert, actions: actions, isFocused: index == 0,
                                isPinned: pinnedIDs.contains(alert.id),
                                titleLineLimit: titleLines[alert.id])
                if index < orderedAlerts.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                }
            }
        }
    }

    private func accent(for alert: DevReadyAlert) -> Color {
        alert.kind == .waiting ? NotchDesign.devReadyAmber : NotchDesign.devReadyGreen
    }
}

/// Single dev-ready row — tap to jump to the source app and dismiss that agent.
struct DevReadyPeekRow: View {
    let alert: DevReadyAlert
    let actions: NotchActions
    var isFocused = false
    var isPinned = false
    /// Measured at the width this peek is actually being drawn at. Falls back
    /// to the alert's baked estimate only for previews and history rows.
    var titleLineLimit: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dismissOffset: CGFloat = 0

    /// Reply/answer affordances. The rule lives on the alert so the height
    /// budget in `NotchContentLayout` reads the same one.
    private var canAnswer: Bool {
        alert.canAnswerFromNotch(replyEnabled: AppSettings.shared.agentReplyEnabled)
    }

    /// Separate from `canAnswer`: the quick-answer capsules need the agent's
    /// keymap to match, the composer only needs a terminal to paste into.
    private var canReply: Bool {
        alert.canReplyFromNotch(replyEnabled: AppSettings.shared.agentReplyEnabled)
    }

    /// Fetch's "Other…" row already opens the composer. The ↰ control next to
    /// dismiss would be a second, unlabeled path to the same place.
    private var showsFetchOther: Bool {
        guard let parsed = alert.parsedQuestion, parsed.hasOther,
              !parsed.options.isEmpty else { return false }
        return canReply
    }

    private var accentColor: Color {
        alert.kind == .waiting ? NotchDesign.devReadyAmber : NotchDesign.devReadyGreen
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            tapRow
            if alert.kind == .waiting {
                waitingAnswerRow
            }
        }
    }

    private var tapRow: some View {
        HStack(spacing: 6) {
            Button(action: handleTap) {
                HStack(spacing: 10) {
                    // State is conveyed by one quiet dot only. The older
                    // expanding halo and tinted row made a finished ping feel
                    // visually heavier than the actual information warranted.
                    Circle()
                        .fill(accentColor)
                        .frame(width: 8, height: 8)
                    .frame(width: 20)

                    sourceIcon

                    VStack(alignment: .leading, spacing: 3) {
                        Text(alert.displayTitle)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            // The same number the layout budgeted height for.
                            // Raising one without the other either clips the
                            // text or leaves a gap under it.
                            .lineLimit(renderedTitleLines)
                            // Only where the title is allowed to wrap. A
                            // one-line agent label still truncates as it always
                            // has — shrinking those would make every long peek
                            // title a different size than its neighbours for no
                            // gain, since they are labels rather than content.
                            .minimumScaleFactor(renderedTitleLines > 1
                                                ? NotchContentLayout.titleMinimumScale : 1)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 5) {
                            // Lead with the app you would switch back to. A
                            // Claude Code agent hosted in Cursor used to badge
                            // itself "claude-code" then "cursor", which reads
                            // as two agents rather than one doing the work.
                            let identity = alert.displayIdentity
                            agentBadge(identity.lead, prominent: true)
                            if let secondary = identity.secondary, !secondary.isEmpty {
                                agentBadge(secondary, prominent: false)
                            }
                            if let subtitle = alert.displaySubtitle, !subtitle.isEmpty {
                                Text(subtitle)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                                    .lineLimit(1)
                            } else if alert.canJumpToSource {
                                Text("Tap to open")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                            } else {
                                // Only ever shown on rows that pin, so the
                                // affordance and its state occupy one slot.
                                // Pinned reads brighter because a peek that has
                                // stopped fading needs to say so — otherwise it
                                // looks like the overlay is stuck.
                                Text(isPinned ? "Pinned · tap to dismiss" : "Tap to keep open")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(isPinned ? NotchOpacity.secondary : NotchOpacity.tertiary))
                            }
                        }
                    }

                    Spacer(minLength: 0)
                    // No chevron. It promised a destination on every row, but a
                    // peek from the transcript watcher carries no bundle id and
                    // opens nothing when tapped — and the rows that *do* open
                    // something already say "Tap to open". Dropping it also
                    // hands its width back to the title, which is tight at the
                    // 380pt the peek is clamped to.
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(DevReadyRowButtonStyle())
            // Finished notifications are informational, so a decisive left
            // swipe can clear one without switching focus to its source app.
            // Waiting rows intentionally ignore this gesture: an approval must
            // always require the explicit × or Esc dismissal path.
            .offset(x: dismissOffset)
            // Spelled out in CGFloat rather than left to inference: the
            // literals here are ambiguous enough that some Swift versions
            // reject the expression outright.
            .opacity(Double(1 - min(abs(dismissOffset) / CGFloat(180), CGFloat(0.45))))
            .simultaneousGesture(dismissGesture)
            .accessibilityHint(accessibilityHint)

            if canReply && !showsFetchOther {
                Button {
                    actions.beginReply(alert)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Reply in the notch")
                .padding(.trailing, 8)
            }

            // Explicit dismiss on every row. Tapping the row also clears a peek,
            // but it focuses the source app on the way out — so without this the
            // only way to get rid of a peek is to be taken somewhere you didn't
            // ask to go. Waiting peeks need it most (they never fade), but a
            // finished one you've already read shouldn't have to be waited out
            // either. `devReadyLayout` budgets the width it costs.
            Button {
                actions.dismissPeek(alert.id)
            } label: {
                // 28pt to match the reply button beside it. At 24 this was under
                // the usual 28pt minimum *and* the smallest target on the row,
                // while sitting closest to the pill's edge — the combination is
                // why dismissing felt unreliable.
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss · Esc dismisses all")
            .accessibilityLabel("Dismiss")
            .padding(.trailing, 8)
        }
    }

    private var dismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard alert.kind == .finished,
                      abs(value.translation.width) > abs(value.translation.height) else { return }
                // Only move left, matching the action; a right drag leaves the
                // row in place instead of implying a second, hidden action.
                dismissOffset = max(-150, min(0, value.translation.width))
            }
            .onEnded { value in
                guard alert.kind == .finished else { return }
                if DevReadyDismissSwipe.isDismissal(translation: value.translation) {
                    actions.dismissPeek(alert.id)
                } else {
                    withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.24, dampingFraction: 0.82)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    /// `.waiting`-only: the agent's question, always visible, plus quick-answer
    /// buttons (Yes/No/1/2/3) gated on `canAnswer` — the message must never be
    /// hidden just because reply/answer isn't available, but we never blind-fire
    /// a keystroke into an untargetable terminal.
    @ViewBuilder
    private var waitingAnswerRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let request = alert.permissionRequest {
                permissionBody(request)
            } else if let parsed = alert.parsedQuestion, !parsed.options.isEmpty {
                Text(parsed.headline)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let question = alert.questionText {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            if canAnswer {
                Group {
                    if let parsed = alert.parsedQuestion, !parsed.options.isEmpty {
                        fetchQuestionOptions(parsed)
                    } else if alert.permissionRequest?.isPlan == true {
                        planReviewButtons
                    } else {
                        answerButtons(alert.answers)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            } else if canReply, let parsed = alert.parsedQuestion, !parsed.options.isEmpty {
                fetchOtherReplyButton
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
        }
    }

    private func fetchQuestionOptions(_ parsed: ParsedQuestion) -> some View {
        VStack(spacing: 5) {
            ForEach(parsed.options) { option in
                fetchOptionRow(option)
            }
            if parsed.hasOther && canReply {
                fetchOtherReplyButton
            }
        }
    }

    private func fetchOptionRow(_ option: QuestionOptionChoice) -> some View {
        Button {
            if option.opensPlanRevision {
                actions.beginPlanRevision(alert)
            } else {
                actions.answer(alert, option.answer)
            }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if option.isRecommended {
                            Text("(Recommended)")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(NotchDesign.devReadyAmber)
                        }
                    }
                    if let desc = option.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(option.keycap)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.label)
    }

    private var fetchOtherReplyButton: some View {
        Button {
            actions.beginReply(alert)
        } label: {
            HStack {
                Text("Other…")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                Text("o")
                    .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.03))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Reply in the notch")
    }

    private var planReviewButtons: some View {
        HStack(spacing: NotchContentLayout.answerButtonSpacing) {
            answerButton(label: "Approve", accessibilityLabel: "Approve plan") {
                actions.answer(alert, AgentAnswer(label: "Approve", keystroke: "allow"))
            }
            answerButton(label: "Revise", accessibilityLabel: "Request plan revisions") {
                actions.beginPlanRevision(alert)
            }
        }
    }

    private func answerButtons(_ answers: [AgentAnswer]) -> some View {
        HStack(spacing: NotchContentLayout.answerButtonSpacing) {
            ForEach(answers.indices, id: \.self) { i in
                let answer = answers[i]
                answerButton(label: answer.label, accessibilityLabel: answer.accessibilityLabel) {
                    actions.answer(alert, answer)
                }
            }
        }
    }

    private func answerButton(label: String, accessibilityLabel: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .frame(minWidth: NotchContentLayout.answerButtonHeight,
                       minHeight: NotchContentLayout.answerButtonHeight)
                .background(Capsule().fill(Color.white.opacity(0.14)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
    }

    /// What the agent is asking to do, drawn as the thing you would decide on:
    /// the file and its change, or the command itself.
    ///
    /// The peek is a few hundred points wide with no room to scroll, so the diff
    /// is capped. A truncated diff is honest about being one — the count line
    /// says how much changed in total, so a large edit reads as large rather
    /// than as the three lines that happened to fit.
    @ViewBuilder
    private func permissionBody(_ request: PermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(request.summary)
                    .font(.system(size: 11, weight: .medium,
                                  design: request.isCommand ? .monospaced : .default))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(request.commandPreviewLineLimit)
                    .truncationMode(request.isCommand ? .tail : .head)
                    .fixedSize(horizontal: false, vertical: true)
                if let count = request.changeCount {
                    Text(count)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            if request.isPlan {
                ForEach(request.planPreview) { line in
                    Text(line.text)
                        .font(.system(size: line.style == .heading ? 11 : 10,
                                      weight: line.style == .heading ? .semibold : .regular,
                                      design: line.style == .numbered ? .monospaced : .default))
                        .foregroundStyle(line.style == .heading ? .white.opacity(0.9) : .white.opacity(0.72))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ForEach(Array(request.previewLines.enumerated()), id: \.offset) { _, line in
                Text(line.text.isEmpty ? " " : line.text)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(color(for: line.kind))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .background(background(for: line.kind))
            }
        }
        .padding(.horizontal, 12)
    }

    private func color(for kind: PermissionRequest.DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color(red: 0.55, green: 0.9, blue: 0.6)
        case .removed: return Color(red: 1.0, green: 0.55, blue: 0.55)
        case .context: return .white.opacity(0.4)
        }
    }

    private func background(for kind: PermissionRequest.DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color.green.opacity(0.14)
        case .removed: return Color.red.opacity(0.14)
        case .context: return .clear
        }
    }

    /// Claude's mark, shipped as a vector asset: Claude Code is a CLI, so on a
    /// machine without the desktop app there is no bundle whose icon we could
    /// look up — and falling through to the terminal's icon is exactly the
    /// ambiguity this is meant to remove.
    private struct ClaudeMark: View {
        var body: some View {
            Image("ClaudeMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }

    /// Prefers the agent's own identity over the terminal it happens to run in:
    /// the row already badges the terminal by name, so the icon is better spent
    /// saying *which agent* is asking. Falls back to the host app's icon for
    /// anything unrecognised (Cursor, a CI hook, a bare script).
    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = alert.agentAppIcon ?? (alert.displayAgent == nil ? alert.appIcon : nil) {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else if alert.displayAgent == .claudeCode {
            ClaudeMark()
                .frame(width: 22, height: 22)
        } else if let icon = alert.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(accentColor)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private func agentBadge(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(prominent ? .white.opacity(0.72) : .white.opacity(0.55))
            // A badge must never wrap. "claude-code" split across two lines makes
            // the row taller than the height budgeted for it, and a single-alert
            // peek isn't in a ScrollView — the overflow clips against the window.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Color.white.opacity(0.08),
                in: Capsule()
            )
    }

    /// Must describe what a tap actually does on *this* row — VoiceOver
    /// promising "open" on a caption that only pins would be a lie.
    private var renderedTitleLines: Int {
        max(1, titleLineLimit ?? alert.titleLines ?? 1)
    }

    private var accessibilityHint: String {
        guard alert.canJumpToSource else {
            return isPinned
                ? "Double tap to dismiss this notification"
                : "Double tap to keep this notification open"
        }
        return alert.kind == .finished
            ? "Swipe left to dismiss, or double tap to open"
            : "Double tap to open"
    }

    private func handleTap() {
        // A row that can jump keeps jumping — that is the point of tapping it.
        // A row that cannot (a dictation caption, a transcript-watcher ping)
        // used to focus nothing and then dismiss itself, so clicking the text
        // you were trying to keep reading was the fastest way to lose it.
        // Those rows pin instead.
        guard alert.canJumpToSource else {
            actions.togglePeekPin(alert)
            return
        }
        actions.focusAlert(alert)
        actions.dismissDevReady(alert.id)
    }
}

private struct DevReadyRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0))
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Expanded live-activity cards

/// Builds the status cards shown when the pill is expanded.
enum ExpandedActivityBuilder {
    static func prioritizing(_ activities: [ExpandedActivity], pinnedKind: String) -> [ExpandedActivity] {
        guard !pinnedKind.isEmpty,
              let index = activities.firstIndex(where: { $0.kind == pinnedKind }) else { return activities }
        var ordered = activities
        let pinned = ordered.remove(at: index)
        ordered.insert(pinned, at: 0)
        return ordered
    }

    static func activities(
        nowPlaying: NowPlaying?,
        nextEvent: CalendarEvent?,
        appSwitchHint: String?,
        frontmostApp: String?,
        systemVolume: Int?,
        timer: ActiveTimer?,
        systemStats: SystemStats?,
        battery: BatteryStatus?,
        agentSessions: [AgentSession] = [],
        devCommands: [DevCommand] = [],
        openCodeUsage: OpenCodeUsage? = nil,
        codexQuota: CodexQuota? = nil,
        claudeQuota: ClaudeQuota? = nil,
        cursorQuota: CursorQuota? = nil,
        ciRuns: [CIRun] = [],
        recentAlerts: [DevReadyAlert] = [],
        showMedia: Bool,
        showActiveApp: Bool,
        showVolume: Bool,
        showClock: Bool,
        showCalendar: Bool,
        showTimer: Bool,
        showSystemStats: Bool,
        showBattery: Bool,
        showShelf: Bool,
        showAgents: Bool = false,
        showCommands: Bool = true,
        showCI: Bool = false,
        showRecentAlerts: Bool = false,
        shelfItems: [ShelfCardItem] = [],
        shelfReceipt: ShelfFilingReceipt? = nil,
        shelfError: String? = nil,
        shelfDropTargeted: Bool = false,
        clipboard: [ClipboardEntry] = [],
        clipboardSearching: Bool = false,
        terminal: TerminalSnapshot? = nil,
        cardOrder: [String] = ExpandedActivity.allKinds.map(\.kind)
    ) -> [ExpandedActivity] {
        var items: [ExpandedActivity] = []
        // Live agents lead: they are the only card that answers "what is
        // running right now", and they are the reason to look at all.
        // This page is sessions only — media, quota and CI keep their own
        // swipe pages rather than sharing the agents strip.
        if showAgents, !agentSessions.isEmpty {
            items.append(.agents(AgentHomeTray(agentSessions)))
        }
        if showCommands, !devCommands.isEmpty {
            items.append(.commands(devCommands))
        }
        if showAgents, let openCodeUsage { items.append(.openCodeUsage(openCodeUsage)) }
        if showAgents, let codexQuota { items.append(.codexQuota(codexQuota)) }
        // Gated on its own setting, not `showAgents`: this one costs a
        // Keychain prompt, so it appears only when explicitly asked for.
        if let claudeQuota { items.append(.claudeQuota(claudeQuota)) }
        if let cursorQuota { items.append(.cursorQuota(cursorQuota)) }
        if showCI, !ciRuns.isEmpty { items.append(.ci(ciRuns)) }
        if showRecentAlerts, !recentAlerts.isEmpty { items.append(.recentAlerts(recentAlerts)) }
        if showMedia, let np = nowPlaying, !np.isEmpty { items.append(.media(np)) }
        // Directly after media, not down with battery and the clock.
        // It only appears when it has something to say, so the cost to the
        // cards below it is zero the rest of the time.
        // `shelfDropTargeted` is what makes the feature findable: with an empty
        // shelf there is otherwise no card, so a drag over the notch had
        // nothing to aim at and no feedback that a drop would land.
        if showShelf, !shelfItems.isEmpty || shelfReceipt != nil || shelfError != nil
            || shelfDropTargeted {
            let card = ExpandedActivity.shelf(items: shelfItems, receipt: shelfReceipt,
                                              error: shelfError,
                                              isDropTargeted: shelfDropTargeted)
            // A transient drop or undo should be immediately visible. A shelf
            // that merely holds files keeps its useful spot near the agents.
            if shelfDropTargeted || shelfReceipt != nil || shelfError != nil {
                items.insert(card, at: 0)
            } else {
                // Files on the shelf are files the user cannot otherwise see.
                // Keep the shelf close to live agents after an undo expires,
                // while agents retain the first position.
                let afterAgents = items.first?.kind == "agents" ? 1 : 0
                items.insert(card, at: afterAgents)
            }
        }

        // Keep clipboard history near the shelf where files are managed.
        // An open search field keeps the card even when nothing matches: a
        // card that vanishes mid-word takes the keyboard focus with it, and
        // there is then no way to correct the typo that emptied it.
        if !clipboard.isEmpty || clipboardSearching {
            let after = items.lastIndex { $0.kind == "shelf" }.map { $0 + 1 }
                ?? (items.first?.kind == "agents" ? 1 : 0)
            items.insert(.clipboard(clipboard, searching: clipboardSearching),
                         at: min(after, items.count))
        }
        // A focused terminal goes to the front so its keyboard target stays
        // easy to find while typing.
        if let terminal {
            items.insert(.terminal(terminal), at: terminal.isFocused ? 0 : min(1, items.count))
        }
        if showActiveApp {
            if let hint = appSwitchHint {
                items.append(.appSwitch(hint))
            } else if let app = frontmostApp {
                items.append(.activeApp(name: app))
            }
        }
        if showCalendar, let event = nextEvent { items.append(.calendar(event)) }
        if showTimer, let timer, timer.isActive { items.append(.timer(timer)) }
        if showVolume, let volume = systemVolume { items.append(.volume(volume)) }
        if showSystemStats, let stats = systemStats { items.append(.systemStats(stats)) }
        if showBattery, let battery { items.append(.battery(battery)) }
        if showClock { items.append(.clock) }
        return applyUserOrder(to: items, order: cardOrder)
    }

    /// Reorders the built deck to the user's arrangement.
    ///
    /// The build order above is a default, not a policy. Shelf and clipboard
    /// cards have useful starting positions while the user can still reorder
    /// the complete deck.
    ///
    /// A shelf that is being dropped onto, or is holding an undo, still jumps
    /// the queue. That is a transient state that must stay visible regardless
    /// of the user's saved arrangement.
    private static func applyUserOrder(to items: [ExpandedActivity],
                                      order: [String]) -> [ExpandedActivity] {
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        var sorted = items.enumerated().sorted { lhs, rhs in
            let l = rank[lhs.element.kind] ?? order.count
            let r = rank[rhs.element.kind] ?? order.count
            // Ties keep their build order: two cards of one kind never happen
            // today, but a stable sort means that stays a non-event if they do.
            return l == r ? lhs.offset < rhs.offset : l < r
        }.map(\.element)

        if let urgent = sorted.firstIndex(where: {
            if case .shelf(_, let receipt, let error, let targeted) = $0 {
                return targeted || receipt != nil || error != nil
            }
            return false
        }), urgent != 0 {
            let card = sorted.remove(at: urgent)
            sorted.insert(card, at: 0)
        }
        // Keep a running or failed command near the front for quick access,
        // even when the saved order places its card near the end.
        if let commandIndex = sorted.firstIndex(where: {
            guard case .commands(let commands) = $0 else { return false }
            return commands.contains { $0.state.isActive || $0.state == .failed }
        }), commandIndex > 1 {
            let card = sorted.remove(at: commandIndex)
            sorted.insert(card, at: sorted.first?.kind == "shelf" ? 1 : 0)
        }
        return sorted
    }
}

/// The equalizer, in a slot that exists whether or not it is animating.
///
/// It used to be inserted and removed with playback (`if np.isPlaying`), so
/// pausing took ten points out of the middle of the row and everything to its
/// right slid across to close the gap. Reserving the width means pause only
/// fades the bars out — nothing moves.
struct EqualizerSlot: View {
    let isPlaying: Bool
    var scale: CGFloat = 1.0

    /// Three 2pt bars with 2pt gaps, at the caller's scale.
    static func width(scale: CGFloat) -> CGFloat { 10 * scale }

    var body: some View {
        EqualizerBars(isPlaying: isPlaying, scale: scale)
            .opacity(isPlaying ? 1 : 0)
            .animation(.easeInOut(duration: 0.18), value: isPlaying)
            .frame(width: Self.width(scale: scale))
    }
}

/// A media-only gesture recogniser. It deliberately ignores short or vertical
/// drags, so inspecting the expanded pill never produces accidental playback
/// changes and no gesture leaks out to the rest of the notch.
enum MediaSwipeDirection: Equatable {
    case previous
    case next

    static func from(translation: CGSize, minimumDistance: CGFloat = 36) -> Self? {
        guard abs(translation.width) >= minimumDistance,
              abs(translation.width) > abs(translation.height) else { return nil }
        return translation.width < 0 ? .next : .previous
    }
}

/// A conservative gesture classifier for transient, already-finished peeks.
/// It is separate from media transport because only one direction is useful:
/// moving the notification left takes it away, like the system's own banners.
enum DevReadyDismissSwipe {
    static func isDismissal(translation: CGSize, minimumDistance: CGFloat = 52) -> Bool {
        translation.width <= -minimumDistance && abs(translation.width) > abs(translation.height)
    }
}

private struct MediaTransportSwipe: ViewModifier {
    let actions: NotchActions

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12).onEnded { value in
                switch MediaSwipeDirection.from(translation: value.translation) {
                case .previous: actions.previous()
                case .next: actions.next()
                case nil: break
                }
            }
        )
    }
}


// MARK: - Collapsed live-activity chips

/// Builds the set of compact chips to show while collapsed.
enum CollapsedChipBuilder {
    static func chips(
        nowPlaying: NowPlaying?,
        nextEvent: CalendarEvent?,
        shelfCount: Int,
        appSwitchHint: String?,
        timer: ActiveTimer?,
        systemStats: SystemStats?,
        battery: BatteryStatus?,
        agentSessions: [AgentSession] = [],
        devCommands: [DevCommand] = [],
        showMedia: Bool,
        showCalendar: Bool,
        showShelf: Bool,
        showAppSwitch: Bool,
        showTimer: Bool,
        showSystemStats: Bool,
        showBattery: Bool,
        showAgents: Bool = true,
        showCommands: Bool = true,
        showClock: Bool
    ) -> [CollapsedChip] {
        var chips: [CollapsedChip] = []
        // Attention prompts and live work take the compact slot even when an
        // older failure is retained in the expanded card for review.
        if showCommands, let command = devCommands.first(where: { $0.state == .waiting })
            ?? devCommands.first(where: { $0.state == .running })
            ?? devCommands.first(where: { $0.state == .failed }) {
            chips.append(.command(title: command.displayTitle, state: command.state))
        }
        if showAppSwitch, let app = appSwitchHint { chips.append(.appSwitch(app)) }
        if showMedia, let np = nowPlaying, !np.isEmpty { chips.append(.media(np)) }
        if showTimer, let timer, timer.isActive { chips.append(.timer(timer)) }
        if showCalendar, let event = nextEvent { chips.append(.calendar(event)) }
        if showShelf, shelfCount > 0 { chips.append(.shelf(count: shelfCount)) }
        if showSystemStats, let stats = systemStats { chips.append(.systemStats(stats)) }
        if showBattery, let battery { chips.append(.battery(battery)) }
        if showAgents, let agent = agentSessions.first(where: {
            if case .idle = $0.state { return false }
            return true
        }) {
            chips.append(.agent(name: agent.displayName, state: agent.statusLabel, count: agentSessions.count))
        }
        if showClock { chips.append(.clock) }
        return chips
    }
}

/// Compact glance: content carries the hierarchy, with quiet separators
/// between signals rather than a row of full-height columns.
struct CollapsedIndicatorsRow: View {
    let chips: [CollapsedChip]
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: NotchSpace.snug * readability) {
            if chips.count <= 2 { Spacer(minLength: 0) }
            ForEach(chips) { chip in
                CollapsedChipView(chip: chip, readability: readability, textScale: textScale)
                if chip.id != chips.last?.id {
                    divider
                }
            }
            if chips.count <= 2 { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 10 * readability)
        .padding(.bottom, 5 * readability)
    }

    private var divider: some View {
        Circle()
            .fill(Color.white.opacity(NotchOpacity.rim))
            .frame(width: 2 * readability, height: 2 * readability)
    }
}

struct CollapsedChipView: View {
    let chip: CollapsedChip
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func textSize(_ base: CGFloat) -> CGFloat { base * textScale }

    var body: some View {
        if case .clock = chip {
            LiveClockView(style: .collapsed, textScale: textScale, readability: readability)
        } else {
            chipContent
        }
    }

    private var chipContent: some View {
        VStack(alignment: .leading, spacing: s(3)) {
            HStack(spacing: s(6)) {
                leading
                mediaLabels
                if case .media(let np) = chip {
                    EqualizerSlot(isPlaying: np.isPlaying, scale: readability)
                }
            }
            if case .media(let np) = chip, np.hasProgress {
                MediaProgressView(nowPlaying: np, style: .collapsed, readability: readability, textScale: textScale)
            }
        }
    }

    @ViewBuilder private var mediaLabels: some View {
        if case .media(let np) = chip {
            VStack(alignment: .leading, spacing: s(1)) {
                Text(np.title)
                    .font(.system(size: textSize(11), weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                if !np.artist.isEmpty {
                    Text(np.artist)
                        .font(.system(size: textSize(NotchType.caption), weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                }
            }
        } else {
            labelView
        }
    }

    @ViewBuilder private var labelView: some View {
        if case .timer(let timer) = chip {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(StatusFormatting.countdown(timer.remaining(at: context.date)))
                    .font(.system(size: textSize(11), weight: .medium))
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        } else {
            Text(label)
                .font(.system(size: textSize(11), weight: .medium))
                .lineLimit(chipsAllowTwoLines ? 2 : 1)
                .foregroundStyle(.white)
        }
    }

    private var chipsAllowTwoLines: Bool {
        textScale >= 1.35
    }

    @ViewBuilder private var leading: some View {
        switch chip {
        case .media(let np):
            Group {
                if let image = np.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .id(ObjectIdentifier(image))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: s(4), style: .continuous)
                            .fill(.white.opacity(0.08))
                        Image(systemName: np.isPlaying ? "play.fill" : "pause.fill")
                            .font(.system(size: s(8), weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
            .frame(width: s(20), height: s(20))
            .clipShape(RoundedRectangle(cornerRadius: s(4), style: .continuous))
        case .calendar:
            Image(systemName: "calendar")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
        case .shelf:
            Image(systemName: "tray.full")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(0.7))
        case .appSwitch:
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(0.7))
        case .timer:
            Image(systemName: "timer")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
        case .systemStats:
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(0.7))
        case .battery(let status):
            Image(systemName: status.isCharging ? "battery.100.bolt" : "battery.100")
                .font(.system(size: s(10)))
                .foregroundStyle(status.level <= 20 ? .red : .white.opacity(NotchOpacity.secondary))
        case .agent(_, let state, _):
            Image(systemName: "circle.fill")
                .font(.system(size: s(7)))
                .foregroundStyle(state.hasPrefix("waiting") ? NotchDesign.devReadyAmber
                                 : state.hasPrefix("working") ? NotchDesign.accent
                                 : .white.opacity(NotchOpacity.secondary))
        case .command(_, let state):
            Image(systemName: state == .waiting ? "hand.raised.fill"
                  : state == .running ? "hammer.fill"
                  : state == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: s(10)))
                .foregroundStyle(state == .failed ? .red
                                 : state == .waiting ? NotchDesign.devReadyAmber
                                 : state == .running ? NotchDesign.accent
                                 : NotchDesign.devReadyGreen)
        case .clock:
            EmptyView()
        }
    }

    private var label: String {
        switch chip {
        case .command(let title, let state):
            return "\(title) · \(state.label)"
        case .media(let np): return np.title
        case .calendar(let event): return event.title
        case .shelf(let count): return count == 1 ? "1 file" : "\(count) files"
        case .appSwitch(let name): return name
        case .timer: return ""
        case .systemStats(let stats): return "CPU \(stats.cpuPercent)% · RAM \(stats.memoryPercent)%"
        case .battery(let status): return "\(status.level)%"
        case .agent(let name, let state, let count):
            return count > 1 ? "\(name) · \(state) · \(count) agents" : "\(name) · \(state)"
        case .clock: return ""
        }
    }
}

/// Legacy single-chip indicator (kept for transition helpers).
struct CollapsedIndicator: View {
    let activity: NotchActivity

    var body: some View {
        if let chip = chip(from: activity) {
            CollapsedChipView(chip: chip)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.black))
        }
    }

    private func chip(from activity: NotchActivity) -> CollapsedChip? {
        switch activity {
        case .idle: return nil
        case .media(let np): return .media(np)
        case .appSwitch(let name): return .appSwitch(name)
        }
    }
}

/// Playback progress bar with live interpolation between metadata updates.
struct MediaProgressView: View {
    enum Style { case collapsed, expanded }

    let nowPlaying: NowPlaying
    var style: Style = .expanded
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func textSize(_ base: CGFloat) -> CGFloat { base * textScale }

    /// Matched to the tick so the bar glides between samples instead of
    /// stepping four times a second.
    ///
    /// It also absorbs the jump at a pause. While playing, the position is
    /// *interpolated* forward from the last reading; pausing stops the
    /// interpolation and falls back to the reading itself, which is a moment
    /// behind — so the bar snapped backwards at the exact instant the user was
    /// looking at it. The same easing that smooths playback now eases that
    /// correction instead of showing it.
    private static let progressMotion: Animation = .linear(duration: 0.25)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let elapsed = nowPlaying.interpolatedElapsed(at: context.date) ?? 0
            let duration = nowPlaying.duration ?? 0
            let fraction = duration > 0 ? min(max(elapsed / duration, 0), 1) : 0
            switch style {
            case .collapsed:
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.14))
                        Capsule()
                            .fill(.white.opacity(0.75))
                            .frame(width: geo.size.width * fraction)
                    }
                }
                .frame(width: s(88), height: s(2.5))
                .animation(Self.progressMotion, value: fraction)
            case .expanded:
                VStack(spacing: s(4)) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.15))
                            Capsule()
                                .fill(.white.opacity(0.85))
                                .frame(width: geo.size.width * fraction)
                        }
                    }
                    .frame(height: s(4))
                    .animation(Self.progressMotion, value: fraction)
                    HStack {
                        Text(formatTime(elapsed))
                        Spacer()
                        Text(formatTime(duration))
                    }
                    .font(.system(size: textSize(10), weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .monospacedDigit()
                }
            }
        }
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

/// Tiny animated equalizer to signal live playback.
struct EqualizerBars: View {
    let isPlaying: Bool
    var scale: CGFloat = 1.0
    @State private var animating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.white.opacity(NotchOpacity.secondary))
                    .frame(width: 2 * scale, height: animating ? 10 * scale : 4 * scale)
                    .animation(animating
                               ? .easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.12)
                               : .easeOut(duration: 0.16),
                               value: animating)
            }
        }
        .frame(height: 10 * scale)
        .onAppear { animating = isPlaying && !reduceMotion }
        .onChange(of: isPlaying) { _, playing in
            animating = playing && !reduceMotion
        }
        .onChange(of: reduceMotion) { _, reduced in
            animating = isPlaying && !reduced
        }
        .onDisappear { animating = false }
    }
}

enum StatusFormatting {
    static func countdown(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let total = Int(interval.rounded(.up))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
