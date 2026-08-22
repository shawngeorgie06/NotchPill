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
        HStack(spacing: 10) {
            Image(systemName: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.white.opacity(0.18))
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * CGFloat(level) / 100)
                }
            }
            .frame(height: 6)

            Text("\(level)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background {
            Capsule(style: .continuous)
                .fill(Color.black)
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(NotchDesign.pillStroke, lineWidth: 0.5)
                }
        }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        .offset(y: 52)
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
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background { SystemHUDBackground() }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
        .offset(y: 52)
    }
}

private struct SystemLevelHUD: View {
    let icon: String
    let label: String
    let level: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22)
            Text(label)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(.white).frame(width: geo.size.width * CGFloat(level) / 100)
                }
            }
            .frame(height: 6)
            Text("\(level)")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 30, alignment: .trailing)
                .monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background { SystemHUDBackground() }
        .shadow(color: .black.opacity(0.45), radius: 10, y: 5)
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
                        .foregroundStyle(.white.opacity(0.55))
                    if queuedCount > 0 {
                        Text("· \(queuedCount) more \(queuedCount == 1 ? "activity" : "activities")")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.38))
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
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                            } else if alert.canJumpToSource {
                                Text("Tap to open")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.38))
                            } else {
                                // Only ever shown on rows that pin, so the
                                // affordance and its state occupy one slot.
                                // Pinned reads brighter because a peek that has
                                // stopped fading needs to say so — otherwise it
                                // looks like the overlay is stuck.
                                Text(isPinned ? "Pinned · tap to dismiss" : "Tap to keep open")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.white.opacity(isPinned ? 0.62 : 0.38))
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

            if canReply {
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
            } else if let question = alert.questionText {
                Text(question)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
            if canAnswer {
                Group {
                    if alert.permissionRequest?.isPlan == true {
                        planReviewButtons
                    } else {
                        answerButtons(alert.answers)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
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
        showCI: Bool = false,
        showRecentAlerts: Bool = false,
        shelfItems: [ShelfCardItem] = [],
        shelfReceipt: ShelfFilingReceipt? = nil,
        shelfError: String? = nil,
        shelfDropTargeted: Bool = false
    ) -> [ExpandedActivity] {
        var items: [ExpandedActivity] = []
        // Live agents lead: they are the only card that answers "what is
        // running right now", and they are the reason to look at all.
        if showAgents, !agentSessions.isEmpty { items.append(.agents(agentSessions)) }
        if showAgents, let openCodeUsage { items.append(.openCodeUsage(openCodeUsage)) }
        if showAgents, let codexQuota { items.append(.codexQuota(codexQuota)) }
        // Gated on its own setting, not `showAgents`: this one costs a
        // Keychain prompt, so it appears only when explicitly asked for.
        if let claudeQuota { items.append(.claudeQuota(claudeQuota)) }
        if let cursorQuota { items.append(.cursorQuota(cursorQuota)) }
        // Right after the agents: both answer "is the thing I started done yet?"
        if showCI, !ciRuns.isEmpty { items.append(.ci(ciRuns)) }
        if showRecentAlerts, !recentAlerts.isEmpty { items.append(.recentAlerts(recentAlerts)) }
        if showMedia, let np = nowPlaying, !np.isEmpty { items.append(.media(np)) }
        // Directly after media, not down with battery and the clock. The deck
        // is trimmed to `visibleCardLimit` (5 at default scale), and from the
        // tail the shelf never survived it — a file dropped seconds ago would
        // land, persist, and render nothing, which reads as a broken drop.
        // It only appears when it has something to say, so the cost to the
        // cards below it is zero the rest of the time.
        // `shelfDropTargeted` is what makes the feature findable: with an empty
        // shelf there is otherwise no card, so a drag over the notch had
        // nothing to aim at and no feedback that a drop would land.
        if showShelf, !shelfItems.isEmpty || shelfReceipt != nil || shelfError != nil
            || shelfDropTargeted {
            items.append(.shelf(items: shelfItems, receipt: shelfReceipt, error: shelfError,
                                isDropTargeted: shelfDropTargeted))
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
        return items
    }
}

struct ExpandedActivityCard: View {
    let activity: ExpandedActivity
    let appIcon: NSImage?
    let actions: NotchActions
    var onCancelTimer: () -> Void = {}
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0
    var expandToFill: Bool = false
    @State private var hoveredShelfItem: UUID?
    @ObservedObject private var destinations = DestinationStore.shared

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight)
    }

    /// The width every card's header icon is laid out in.
    ///
    /// SF Symbols differ enormously in intrinsic width —
    /// `chevron.left.forwardslash.chevron.right` on the Codex card is roughly
    /// three times `asterisk` on Claude's — so a header sized to its own icon
    /// started its title at a different x on every page. Paging left and right
    /// slid the heading back and forth underneath a pill that was otherwise
    /// holding perfectly still. A fixed slot costs a few points and buys a
    /// column.
    private var headerIconWidth: CGFloat { s(13) }

    /// And the height, so the first line of body copy also shares a baseline
    /// from card to card. The agents card carries a 13pt status dot where the
    /// others carry a 9pt glyph; left to themselves those two headers are
    /// different heights, and everything below them inherits the difference.
    private var headerHeight: CGFloat { s(14) }

    /// Every card's first line. `trailing` is whatever that particular card
    /// puts on the right — a count, a hint — and stays out of the aligned
    /// leading run.
    private func cardHeader<Icon: View, Trailing: View>(
        @ViewBuilder icon: () -> Icon,
        title: String,
        titleFont: Font? = nil,
        tracking: CGFloat = 0,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack(spacing: s(4)) {
            icon().frame(width: headerIconWidth)
            Text(title)
                .font(titleFont ?? font(size: 10, weight: .semibold))
                .tracking(tracking)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            trailing()
        }
        .foregroundStyle(.white.opacity(0.45))
        .frame(height: headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The common case: an SF Symbol and a title.
    private func cardHeader(symbol: String, title: String) -> some View {
        cardHeader(icon: {
            Image(systemName: symbol).font(.system(size: s(9)))
        }, title: title)
    }

    var body: some View {
        Group {
            switch activity {
            case .media(let np):
                mediaCard(np)
                    .modifier(MediaTransportSwipe(actions: actions))
                    .accessibilityHint("Swipe left for next track or right for previous track")
            case .appSwitch(let name):
                appCard(title: "Switched to", name: name)
            case .activeApp(let name):
                appCard(title: "Active", name: name)
            case .volume(let level):
                volumeCard(level)
            case .clock:
                LiveClockView(style: .expanded, textScale: textScale, readability: readability)
            case .calendar(let event):
                calendarCard(event)
            case .timer(let timer):
                timerCard(timer)
            case .systemStats(let stats):
                systemStatsCard(stats)
            case .battery(let status):
                batteryCard(status)
            case .shelf(let items, let receipt, let error, let targeted):
                shelfCard(items: items, receipt: receipt, error: error, isDropTargeted: targeted)
            case .agents(let sessions):
                agentsCard(sessions)
            case .openCodeUsage(let usage):
                openCodeUsageCard(usage)
            case .codexQuota(let quota):
                codexQuotaCard(quota)
            case .claudeQuota(let quota):
                claudeQuotaCard(quota)
            case .cursorQuota(let quota):
                cursorQuotaCard(quota)
            case .ci(let runs):
                ciCard(runs)
            case .recentAlerts(let alerts):
                recentAlertsCard(alerts)
            }
        }
        .frame(
            minWidth: expandToFill ? nil : s(76),
            maxWidth: expandToFill ? .infinity : nil,
            alignment: .leading
        )
        .layoutPriority(expandToFill ? 1 : 0)
    }

    /// The agent-sessions card joins live transcript state with recent terminal
    /// events, so a finished or blocked conversation does not masquerade as a
    /// running process or disappear the instant it goes quiet.
    private func agentsCard(_ sessions: [AgentSession]) -> some View {
        let waiting = sessions.filter(\.isWaiting).count
        let working = sessions.filter {
            if case .working = $0.state { return true }
            return false
        }.count
        let idle = sessions.filter {
            if case .idle = $0.state { return true }
            return false
        }.count
        let completed = sessions.filter(\.isCompleted).count
        let summary = [
            waiting == 0 ? nil : "\(waiting) needs you",
            working == 0 ? nil : "\(working) working",
            idle == 0 ? nil : "\(idle) idle",
            completed == 0 ? nil : "\(completed) completed"
        ].compactMap { $0 }.joined(separator: " · ")
        let headerColor: Color = waiting > 0 ? .orange
            : (working > 0 ? .green : .white.opacity(0.35))
        return VStack(alignment: .leading, spacing: s(4)) {
            cardHeader(icon: {
                ZStack {
                    Circle()
                        .fill(headerColor.opacity(0.16))
                        .frame(width: s(13), height: s(13))
                    Circle()
                        .fill(headerColor)
                        .frame(width: s(5), height: s(5))
                }
            }, title: "AGENT SESSIONS",
               titleFont: font(size: 9, weight: .bold),
               tracking: 0.7 * textScale) {
                Text(summary.isEmpty ? "\(sessions.count) recent" : summary)
                    .font(font(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.38))
                Spacer(minLength: s(2))
                Text("tap to jump")
                    .font(font(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
            }

            // Scrolls rather than truncating. The header counts every session,
            // so silently showing three of four made the card contradict
            // itself — and there was no way to reach the rest.
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: s(4)) {
                    ForEach(sessions) { session in
                        agentRow(session)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A local total, intentionally not an account quota or reset estimate.
    private func openCodeUsageCard(_ usage: OpenCodeUsage) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "curlybraces", title: "OpenCode · today")

            Text(usage.tokenLabel)
                .font(font(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
            Text(usage.costLabel + " local session cost")
                .font(font(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func codexQuotaCard(_ quota: CodexQuota) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "chevron.left.forwardslash.chevron.right", title: "Codex · current window")
            HStack(spacing: s(5)) {
                Text(quota.usageLabel)
                    .font(font(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: true, vertical: false)
                if let credits = quota.creditsLabel {
                    Text("· " + credits)
                        .font(font(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            Text([quota.resetLabel, quota.updatedLabel].compactMap { $0 }.joined(separator: " · "))
                .font(font(size: 10))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// Claude's two limits side by side. Showing only the session window hides
    /// the weekly one you actually run into on a heavy week; showing only the
    /// weekly hides the one that stops you mid-afternoon.
    private func claudeQuotaCard(_ quota: ClaudeQuota) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "asterisk", title: "Claude · limits")

            // Each window carries its own reset. Naming only the nearer one
            // hid the session reset whenever the weekly figure happened to be
            // a few points higher — and the session window is the one that
            // stops you this afternoon.
            HStack(spacing: s(8)) {
                quotaMeter(label: "session", percent: quota.sessionPercent,
                           footnote: ClaudeQuota.resetClock(for: quota.sessionResetsAt))
                quotaMeter(label: "week", percent: quota.weeklyPercent,
                           footnote: ClaudeQuota.resetClock(for: quota.weeklyResetsAt))
                // A third column for a per-model window (Opus, Fable, …) was
                // built here and taken out again: the usage endpoint does not
                // carry one. `seven_day_opus` and friends exist as keys but are
                // flags rather than objects, and the only three entries with a
                // utilization figure are `five_hour`, `seven_day` and
                // `extra_usage`. `ClaudeQuota.modelWindows` still parses any
                // real per-model window and the fetcher logs what it finds, so
                // this becomes a two-line change if that ever lands — but a
                // control that can never show anything is worse than no
                // control.
            }

            if let extra = quota.extraSpendLabel {
                Text("extra " + extra)
                    .font(font(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cursor's included usage for the billing cycle.
    ///
    /// One meter, not two: Cursor meters a single pool per cycle rather than
    /// Claude's session/week pair. The raw counts sit under the bar because the
    /// percentage alone cannot distinguish "100% of 500" from "100% of 9201".
    private func cursorQuotaCard(_ quota: CursorQuota) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "cursorarrow", title: "Cursor · limits")

            if quota.isUnlimited {
                Text("unlimited")
                    .font(font(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
            } else if let auto = quota.autoPercentUsed, let api = quota.apiPercentUsed,
                      auto > 0 || api > 0 {
                // Two pools, shown apart. They diverge, and a single averaged
                // number would hide whichever one is closer to biting.
                //
                // Only while the split says something, though. Cursor reports
                // these as whole numbers, so early in a cycle both read 0 while
                // the pool itself is genuinely used — the card showed "0% / 0%"
                // above "38 of 2000", which is two empty bars contradicting the
                // line under them. When neither pool has moved, the total is
                // the accurate answer rather than the less detailed one.
                HStack(spacing: s(8)) {
                    quotaMeter(label: "auto", percent: auto)
                    quotaMeter(label: "API", percent: api)
                }
            } else {
                quotaMeter(label: quota.usageLabel, percent: quota.percentUsed)
            }

            Text([quota.isUnlimited ? nil : quota.usageLabel,
                  quota.bonusLabel,
                  CursorQuota.cycleLabel(for: quota.cycleEnd),
                  quota.membershipLabel,
                  quota.onDemandEnabled ? "on-demand on" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(font(size: 10))
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A number and a bar. The bar exists because "51%" and "13%" read as
    /// equally unremarkable in text, and the whole point of the card is to
    /// notice when one of them is not.
    private func quotaMeter(label: String, percent: Int,
                            footnote: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: s(2)) {
            Text("\(percent)%")
                .font(font(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule()
                        .fill(quotaColor(percent))
                        .frame(width: max(2, geo.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: s(4))
            Text(footnote.map { "\(label) · \($0)" } ?? label)
                .font(font(size: 9))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func quotaColor(_ percent: Int) -> Color {
        // Amber before it bites, red once it is about to. A single colour meant
        // the card looked identical at 5% and 95%.
        if percent >= 90 { return NotchDesign.devReadyAmber.opacity(0.95) }
        if percent >= 70 { return NotchDesign.devReadyAmber.opacity(0.75) }
        return NotchDesign.devReadyGreen.opacity(0.8)
    }

    /// GitHub Actions for the repos you have agents working in.
    private func ciCard(_ runs: [CIRun]) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "checkmark.seal", title: "CI")

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: s(3)) {
                    ForEach(runs) { run in
                        Button { actions.openURL(run.id) } label: {
                            HStack(spacing: s(5)) {
                                Circle()
                                    .fill(color(for: run.state))
                                    .frame(width: s(5), height: s(5))
                                // Repo first. The card follows whichever repos
                                // your agents are in, so "Release — passed" on
                                // its own says nothing about *whose* release —
                                // someone watching a build in one project saw
                                // another project's green tick and believed it.
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(run.repoName)
                                        .font(font(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                                    Text(run.workflow)
                                        .font(font(size: 9, weight: .medium))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                }
                                Spacer(minLength: s(4))
                                Text(run.statusLabel)
                                    .font(font(size: 10, weight: .medium))
                                    .foregroundStyle(color(for: run.state).opacity(0.85))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func recentAlertsCard(_ alerts: [DevReadyAlert]) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            HStack(spacing: s(4)) {
                Image(systemName: "bell.badge")
                    .font(.system(size: s(9)))
                Text("Notifications")
                    .font(font(size: 10, weight: .semibold))
                if alerts.count > 3 {
                    Text("\(alerts.count)")
                        .font(font(size: 9, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, s(4))
                        .padding(.vertical, s(1))
                        .background(.white.opacity(0.12), in: Capsule())
                }
                Spacer(minLength: 0)
                Button("Clear") { actions.clearRecentActivity() }
                    .font(font(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .buttonStyle(.plain)
            }
            .foregroundStyle(.white.opacity(0.45))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: s(3)) {
                    ForEach(alerts) { alert in
                        Button { actions.focusAlert(alert) } label: {
                            HStack(alignment: .top, spacing: s(6)) {
                                VStack(alignment: .leading, spacing: s(1)) {
                                    Text(alert.displayTitle)
                                        .font(font(size: 11, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.92))
                                        .lineLimit(1)
                        if let subtitle = alert.displaySubtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(font(size: 9, weight: .medium))
                                .foregroundStyle(.white.opacity(0.48))
                                .lineLimit(1)
                        }
                                }
                                Text(alert.shortAgeText())
                                    .font(font(size: 9, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.38))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: s(66))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Red is reserved for a failure — the only state that wants you to stop
    /// what you are doing.
    private func color(for state: CIRun.State) -> Color {
        switch state {
        case .failed: return .red
        case .running: return .yellow
        case .passed: return .green
        case .other: return .white.opacity(0.4)
        }
    }

    private func agentRow(_ session: AgentSession) -> some View {
        Button {
            actions.focusAgentSession(session)
        } label: {
            VStack(alignment: .leading, spacing: s(3)) {
                HStack(spacing: s(5)) {
                    Circle()
                        .fill(color(for: session.state))
                        .frame(width: s(5), height: s(5))
                    if let symbol = session.vendorSymbol {
                        Image(systemName: symbol)
                            .font(font(size: 9, weight: .semibold))
                            // Dimmer than the name: it answers "which tool",
                            // which you only ask once per row, and it must not
                            // compete with the task line for attention.
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: s(9))
                            .accessibilityLabel(session.agentName)
                    }
                    Text(session.displayName)
                        .font(font(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: true, vertical: false)
                    if let context = session.displayContext, !context.isEmpty {
                        Text(context)
                            .font(.system(size: 9 * textScale, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.43))
                            .lineLimit(1)
                    }
                    Spacer(minLength: s(4))
                    Text(session.statusLabel)
                        .font(font(size: 8, weight: .bold))
                        .foregroundStyle(color(for: session.state).opacity(0.95))
                        .padding(.horizontal, s(5))
                        .padding(.vertical, s(2))
                        .background(color(for: session.state).opacity(0.14), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)
                }
                agentActivityLine(session)
                agentMetricsLine(session)
            }
            .padding(.horizontal, s(7))
            .padding(.vertical, s(5))
            .background(color(for: session.state).opacity(session.isWaiting ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: s(7), style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: s(7), style: .continuous)
                    .stroke(color(for: session.state).opacity(session.isWaiting ? 0.48 : 0.16), lineWidth: 0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The model, trailing the activity line.
    ///
    /// It started on the title line and was invisible there. That line already
    /// carries the name, the project and the status pill inside a 210pt card,
    /// so the model — added last and deliberately lowest priority — was
    /// squeezed to nothing before it ever drew. Down here it trails a line
    /// whose content is usually short, and it is pushed to the edge so it
    /// never competes with the tool detail for the middle of the row.
    /// Effort is drawn brighter than the model beside it. It is the part that
    /// changes between two otherwise identical sessions, and the part you can
    /// act on — an agent grinding on `high` is the one worth interrupting.
    @ViewBuilder
    private func agentModelTag(_ session: AgentSession) -> some View {
        if session.modelBaseLabel != nil || session.effortLabel != nil {
            HStack(spacing: s(3)) {
                if let base = session.modelBaseLabel {
                    Text(base)
                        .font(.system(size: 8 * textScale, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let effort = session.effortLabel {
                    Text(effort)
                        .font(.system(size: 8 * textScale, weight: .semibold))
                        .foregroundStyle(color(for: session.state).opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(session.modelLabel.map { "Model \($0)" } ?? "")
        }
    }

    /// The row says what the session is *for*, never what it is typing.
    ///
    /// This line used to render the live tool call — "$ Bash xcodebuild test".
    /// Two problems. It is the most volatile thing on the card, so the row
    /// rewrote itself several times a second and the eye could not rest on it;
    /// and a command line is not ours to publish. Whatever a user types after
    /// `Bash` lands in the notch verbatim, in front of whoever is looking at
    /// the screen — an API key passed inline, a token in a curl, a private
    /// path. The task line answers the question the card is actually for
    /// ("what is this session doing?") and stays still while it does.
    @ViewBuilder
    private func agentActivityLine(_ session: AgentSession) -> some View {
        if let task = session.task {
            HStack(spacing: s(5)) {
                Text("›")
                    .font(font(size: 12, weight: .bold))
                    .foregroundStyle(color(for: session.state).opacity(0.9))
                Text("\(session.taskLeadIn) · \(task)")
                    .font(font(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                Spacer(minLength: s(4))
                agentModelTag(session)
            }
        } else {
            HStack(spacing: s(5)) {
                Text(session.isWaiting ? "Needs your attention" : "Monitoring this session")
                    .font(font(size: 9, weight: .medium))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
                    .padding(.leading, s(12))
                Spacer(minLength: s(4))
                agentModelTag(session)
            }
        }
    }

    /// Runtime and context size, under the activity line.
    ///
    /// Context is the number that decides a session's fate — a run near the
    /// window is about to compact and lose the thread — and neither figure was
    /// anywhere on the card before. Rendered only when there is something to
    /// say, so short-lived rows do not grow an empty line.
    @ViewBuilder
    private func agentMetricsLine(_ session: AgentSession) -> some View {
        let parts = [session.runtimeLabel, session.contextLabel].compactMap { $0 }
        if !parts.isEmpty || session.permissionLabel != nil {
            HStack(spacing: s(4)) {
                if !parts.isEmpty {
                    Text(parts.joined(separator: " · "))
                        .font(.system(size: 8.5 * textScale, weight: .medium,
                                      design: .monospaced))
                        // A session near its window is the one about to compact
                        // and lose the thread, so at that point the figure stops
                        // being trivia and is drawn like it matters.
                        .foregroundStyle(session.isContextTight
                            ? Color.orange.opacity(0.9)
                            : .white.opacity(0.38))
                        .lineLimit(1)
                }
                agentPermissionBadge(session)
            }
            .padding(.leading, s(12))
        }
    }

    /// Whether the agent will stop and ask — the one thing on the row that
    /// says if it is safe to walk away from.
    ///
    /// Only drawn when the answer is surprising. `default` is the mode where
    /// the agent asks, which is what everyone already assumes, so a badge there
    /// would be noise on every row and teach the eye to skip the badge
    /// entirely. `bypass` and `auto-edit` are warned about; `plan` is the
    /// cautious end of the scale and is drawn calmly.
    @ViewBuilder
    private func agentPermissionBadge(_ session: AgentSession) -> some View {
        if let label = session.permissionLabel {
            let tint = session.isUnsupervised ? Color.orange : Color.cyan
            Text(label)
                .font(.system(size: 8 * textScale, weight: .semibold))
                .foregroundStyle(tint.opacity(0.95))
                .padding(.horizontal, s(4))
                .padding(.vertical, s(1))
                .background(tint.opacity(0.16),
                            in: Capsule())
                .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(session.isUnsupervised
                    ? "Runs without asking: \(label)"
                    : "Permission mode \(label)")
        }
    }

    /// Waiting is the only state worth interrupting for, so it is the only one
    /// that gets a warm colour; working is calm and idle recedes.
    private func color(for state: AgentSession.State) -> Color {
        switch state {
        case .waiting: return .orange
        case .working: return .green
        case .idle: return .white.opacity(0.35)
        case .completed: return .white.opacity(0.28)
        }
    }

    private func mediaCard(_ np: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            HStack(spacing: s(8)) {
                mediaArtwork(np)
                VStack(alignment: .leading, spacing: s(1)) {
                    Text(np.title)
                        .font(font(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(expandToFill ? 2 : 1)
                    Text(np.artist)
                        .font(font(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                // The text column absorbs every spare point, so the controls
                // sit at the trailing edge at a fixed distance from it. Without
                // this the arrows were positioned by whatever the title happened
                // to measure, and moved for every song.
                .frame(maxWidth: .infinity, alignment: .leading)
                EqualizerSlot(isPlaying: np.isPlaying, scale: readability)
                HStack(spacing: s(2)) {
                    mediaArrowButton("chevron.left", label: "Previous track", action: actions.previous)
                    mediaArrowButton("chevron.right", label: "Next track", action: actions.next)
                }
            }
            HStack(spacing: s(18)) {
                transportButton("backward.fill", action: actions.previous)
                transportButton(np.isPlaying ? "pause.fill" : "play.fill", size: 22,
                                morphing: true, action: actions.togglePlayPause)
                transportButton("forward.fill", action: actions.next)
            }
            if np.hasProgress {
                MediaProgressView(nowPlaying: np, style: .expanded, readability: readability, textScale: textScale)
            }
        }
    }

    private func mediaArtwork(_ np: NowPlaying) -> some View {
        Group {
            if let image = np.artwork {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(image))
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.white.opacity(0.45))
                        .font(.system(size: s(12)))
                }
            }
        }
        .frame(width: s(32), height: s(32))
        .clipShape(RoundedRectangle(cornerRadius: s(6), style: .continuous))
    }

    /// Explicit chevrons make track navigation discoverable in the compact
    /// deck. Their visual weight stays light, but the full 32pt square reacts
    /// so the control is practical at the top edge of the display.
    private func mediaArrowButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: s(11), weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: s(32), height: s(32))
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
    }

    private func appCard(title: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: s(4)) {
            Text(title)
                .font(font(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: s(6)) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: s(19), height: s(19))
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: s(18)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(name)
                    .font(font(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(expandToFill ? 3 : 2)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func volumeCard(_ level: Int) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Label("System Volume", systemImage: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("\(level)%")
                .font(font(size: 20, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(.white)
                        .frame(width: geo.size.width * CGFloat(level) / 100)
                }
            }
            .frame(height: s(4))
        }
        .frame(minWidth: s(72), alignment: .leading)
    }

    private func calendarCard(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: s(4)) {
            Label("Next event", systemImage: "calendar")
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.orange.opacity(0.85))
            Text(event.title)
                .font(font(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(expandToFill ? 3 : 2)
            Text(relativeStart(for: event.start))
                .font(font(size: 11))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(minWidth: s(110), alignment: .leading)
    }

    private func timerCard(_ timer: ActiveTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: s(6)) {
                Label(timer.isFocusSession ? "Focus session" : timer.label,
                      systemImage: timer.isFocusSession ? "moon.stars.fill" : "timer")
                    .font(font(size: 11, weight: .medium))
                    .foregroundStyle(timer.isFocusSession ? NotchDesign.accent : .white.opacity(0.45))
                Text(StatusFormatting.countdown(timer.remaining(at: context.date)))
                    .font(font(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Button(timer.isFocusSession ? "End focus" : "Cancel", action: onCancelTimer)
                    .font(font(size: 11, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(minWidth: s(88), alignment: .leading)
        }
    }

    private func systemStatsCard(_ stats: SystemStats) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Label("System", systemImage: "gauge.with.dots.needle.67percent")
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            statLine(title: "CPU", value: stats.cpuPercent)
            statLine(title: "RAM", value: stats.memoryPercent)
        }
        .frame(minWidth: s(88), alignment: .leading)
    }

    private func statLine(title: String, value: Int) -> some View {
        HStack {
            Text(title)
                .font(font(size: 11))
                .foregroundStyle(.white.opacity(0.45))
            Spacer()
            Text("\(value)%")
                .font(font(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
    }

    private func batteryCard(_ status: BatteryStatus) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Label(status.isCharging ? "Charging" : "Battery", systemImage: batterySymbol(for: status))
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text("\(status.level)%")
                .font(font(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
        }
        .frame(minWidth: s(72), alignment: .leading)
    }

    @ViewBuilder
    private func shelfCard(items: [ShelfCardItem], receipt: ShelfFilingReceipt?,
                           error: String?, isDropTargeted: Bool) -> some View {
        VStack(alignment: .leading, spacing: s(4)) {
            // The toast takes over the header rather than the chip row: filing
            // one of several files must not hide the rest for ten seconds, and
            // swapping the header keeps the card's height constant.
            HStack(spacing: s(5)) {
                if let error {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(font(size: 11))
                        .foregroundStyle(.orange.opacity(0.85))
                    Text(error)
                        .font(font(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                } else if let receipt {
                    Image(systemName: "checkmark.circle.fill")
                        .font(font(size: 11))
                        .foregroundStyle(.green.opacity(0.8))
                    Text("Moved to \(receipt.destinationName)")
                        .font(font(size: 11))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Undo") { actions.undoShelfFiling() }
                        .font(font(size: 11, weight: .medium))
                        .foregroundStyle(NotchDesign.accent)
                        .buttonStyle(.plain)
                    if !destinations.pinned.contains(receipt.token.to.deletingLastPathComponent()) {
                        Button("Pin") { destinations.pin(receipt.token.to.deletingLastPathComponent()) }
                            .font(font(size: 11, weight: .medium))
                            .foregroundStyle(NotchDesign.accent)
                            .buttonStyle(.plain)
                    }
                } else {
                    Label("Shelf", systemImage: "tray.full")
                        .font(font(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                    Spacer(minLength: 0)
                    if !items.isEmpty {
                        ShareLink(items: items.map(\.url)) {
                            Image(systemName: "square.and.arrow.up").font(font(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.55))
                        Button { items.forEach { actions.removeShelfItem($0.id) } } label: {
                            Image(systemName: "xmark.circle.fill").font(font(size: 10))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(0.35))
                    }
                }
            }

            // Files already on the shelf always win the space. The drop zone
            // only stands in when there is nothing else to show — a targeting
            // flag that failed to clear must never be able to hide the chips,
            // which are the only route to the destination menu.
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(6)) {
                        ForEach(items) { item in shelfChip(item) }
                    }
                }
                .frame(height: s(46))
                .overlay(
                    RoundedRectangle(cornerRadius: s(8), style: .continuous)
                        .strokeBorder(NotchDesign.accent,
                                      lineWidth: isDropTargeted ? 1.4 : 0)
                )
            } else if isDropTargeted {
                RoundedRectangle(cornerRadius: s(8), style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.4, dash: [4, 3]))
                    .foregroundStyle(NotchDesign.accent)
                    .background(
                        RoundedRectangle(cornerRadius: s(8), style: .continuous)
                            .fill(NotchDesign.accent.opacity(0.15))
                    )
                    .overlay(
                        Label("Drop to add", systemImage: "arrow.down.doc")
                            .font(font(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                    )
                    .frame(height: s(46))
            }
        }
        .frame(minWidth: s(108), alignment: .leading)
    }

    private func shelfChip(_ item: ShelfCardItem) -> some View {
        // A Button, not `.onTapGesture`: `.onDrag` installs its own gesture on
        // the same view and swallows taps often enough that clicking a chip did
        // nothing at all. A button's click goes through AppKit and is not in
        // competition with the drag.
        Button {
            presentDestinationMenu(for: item)
        } label: {
            VStack(spacing: s(2)) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                    .resizable()
                    .frame(width: s(22), height: s(22))
                Text(item.name)
                    .font(font(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: s(40))
            }
            .frame(width: s(52), height: s(42))
            .background(
                RoundedRectangle(cornerRadius: s(6), style: .continuous)
                    .fill(Color.white.opacity(hoveredShelfItem == item.id ? 0.14 : 0.06))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Always visible, never hover-only: this badge is the only thing that
        // says a chip can be filed at all, and a control you have to discover
        // by hovering is a control most people never find.
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "folder.fill")
                .font(font(size: 8))
                .foregroundStyle(.white.opacity(0.9))
                .padding(s(2))
                .background(Circle().fill(NotchDesign.accent))
                .offset(x: s(3), y: s(3))
                .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if hoveredShelfItem == item.id {
                Button { actions.removeShelfItem(item.id) } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(font(size: 10))
                        .foregroundStyle(.white, .black)
                }
                .buttonStyle(.plain)
                .offset(x: s(4), y: -s(4))
            }
        }
        .onHover { hoveredShelfItem = $0 ? item.id : nil }
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Move to…") { presentDestinationMenu(for: item) }
            ShareLink("Share / AirDrop…", item: item.url)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Remove", role: .destructive) { actions.removeShelfItem(item.id) }
        }
        .help("Click to move \(item.name) to a folder")
    }

    /// `NSMenu.popUp` runs a modal event loop, so the hold is raised for the
    /// whole time it is on screen and dropped once a choice is made.
    private func presentDestinationMenu(for item: ShelfCardItem) {
        let entries = destinations.destinations()
        LogStore.shelf("chip tapped: \(item.name) — \(entries.count) destinations")
        actions.holdNotchOpen(true)
        ShelfDestinationMenu.shared.present(destinations: entries) { folder in
            LogStore.shelf("picked \(folder.lastPathComponent) for \(item.name)")
            actions.fileShelfItem(item.id, folder)
        }
        actions.holdNotchOpen(false)
    }

    private func batterySymbol(for status: BatteryStatus) -> String {
        switch status.level {
        case 0...10: return status.isCharging ? "battery.0.bolt" : "battery.0"
        case 11...35: return status.isCharging ? "battery.25.bolt" : "battery.25"
        case 36...65: return status.isCharging ? "battery.50.bolt" : "battery.50"
        case 66...90: return status.isCharging ? "battery.75.bolt" : "battery.75"
        default: return status.isCharging ? "battery.100.bolt" : "battery.100"
        }
    }

    private func relativeStart(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// `morphing` is for play/pause only. SF Symbols can cross-dissolve one
    /// glyph into the other in place, which is what a pause should look like —
    /// a button changing its mind, not the card rearranging itself.
    private func transportButton(_ symbol: String, size: CGFloat = 18,
                                 morphing: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: s(size), weight: .medium))
                .foregroundStyle(.white)
                .modifier(SymbolMorph(enabled: morphing, symbol: symbol))
                .frame(width: s(28), height: s(28))
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
    }
}

private struct SymbolMorph: ViewModifier {
    let enabled: Bool
    let symbol: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.18), value: symbol)
        } else {
            content
        }
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
        EqualizerBars(scale: scale)
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

private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
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
        showMedia: Bool,
        showCalendar: Bool,
        showShelf: Bool,
        showAppSwitch: Bool,
        showTimer: Bool,
        showSystemStats: Bool,
        showBattery: Bool,
        showAgents: Bool = true,
        showClock: Bool
    ) -> [CollapsedChip] {
        var chips: [CollapsedChip] = []
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

/// Row of compact chips inside the collapsed pill (media + calendar + shelf, etc.).
struct CollapsedIndicatorsRow: View {
    let chips: [CollapsedChip]
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 8 * readability) {
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
        Rectangle()
            .fill(Color.white.opacity(0.14))
            .frame(width: 1, height: 14 * readability)
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
                        .font(.system(size: textSize(9), weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.55))
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
                .foregroundStyle(.orange)
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
                .foregroundStyle(.yellow.opacity(0.85))
        case .systemStats:
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: s(10)))
                .foregroundStyle(.white.opacity(0.7))
        case .battery(let status):
            Image(systemName: status.isCharging ? "battery.100.bolt" : "battery.100")
                .font(.system(size: s(10)))
                .foregroundStyle(status.level <= 20 ? .red : .green)
        case .agent:
            Image(systemName: "circle.fill")
                .font(.system(size: s(7)))
                .foregroundStyle(NotchDesign.devReadyGreen)
        case .clock:
            EmptyView()
        }
    }

    private var label: String {
        switch chip {
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
                    .foregroundStyle(.white.opacity(0.45))
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
    var scale: CGFloat = 1.0
    @State private var animating = false
    var body: some View {
        HStack(spacing: 2 * scale) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.green)
                    .frame(width: 2 * scale, height: animating ? 10 * scale : 4 * scale)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.12),
                               value: animating)
            }
        }
        .frame(height: 10 * scale)
        .onAppear { animating = true }
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
