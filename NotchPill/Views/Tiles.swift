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
        shelfDropTargeted: Bool = false,
        clipboard: [ClipboardEntry] = [],
        clipboardSearching: Bool = false,
        terminal: TerminalSnapshot? = nil,
        cardOrder: [String] = ExpandedActivity.allKinds.map(\.kind)
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
            let card = ExpandedActivity.shelf(items: shelfItems, receipt: shelfReceipt,
                                              error: shelfError,
                                              isDropTargeted: shelfDropTargeted)
            // Position is not a nicety here — the deck is trimmed to
            // `visibleCardLimit`, which is three at a 75% pill. A machine
            // showing agents plus two usage cards fills that before the shelf
            // is reached, so a dropped file landed, persisted, and rendered
            // nothing at all. Sitting mid-order is enough for a shelf that
            // merely holds files; it is not enough while someone is actively
            // dropping onto it or waiting on an undo, and those must survive
            // any limit down to one.
            if shelfDropTargeted || shelfReceipt != nil || shelfError != nil {
                items.insert(card, at: 0)
            } else {
                // Files on the shelf are files the user cannot otherwise see.
                // Behind the usage cards this card was trimmed away on any
                // ordinary deck, so a dropped file became invisible again the
                // moment its undo expired — parked somewhere with no way back
                // to it. Live agents still lead; nothing else outranks knowing
                // you are holding something.
                let afterAgents = items.first?.kind == "agents" ? 1 : 0
                items.insert(card, at: afterAgents)
            }
        }

        // Directly behind the shelf, for the same reason the shelf sits high:
        // an opt-in card at the tail is trimmed away on any deck carrying
        // agents and a usage card, so turning the setting on appeared to do
        // nothing at all.
        // An open search field keeps the card even when nothing matches: a
        // card that vanishes mid-word takes the keyboard focus with it, and
        // there is then no way to correct the typo that emptied it.
        if !clipboard.isEmpty || clipboardSearching {
            let after = items.lastIndex { $0.kind == "shelf" }.map { $0 + 1 }
                ?? (items.first?.kind == "agents" ? 1 : 0)
            items.insert(.clipboard(clipboard, searching: clipboardSearching),
                         at: min(after, items.count))
        }
        // Same reasoning as the shelf and the clipboard, only more so: a card
        // holding keyboard focus must never be trimmed out from under the
        // person typing into it, so a focused terminal goes to the very front.
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
    /// The build order above is a default, not a policy. Everything it does to
    /// hoist a card -- the shelf sitting behind the agents, the clipboard
    /// behind the shelf -- exists because the deck is trimmed to
    /// `visibleCardLimit` and a card at the tail is simply never drawn. Once
    /// the order is the user's, those become the starting arrangement rather
    /// than something to work around.
    ///
    /// A shelf that is being dropped onto, or is holding an undo, still jumps
    /// the queue. That is not ordering, it is a transient state that must
    /// survive any limit down to one card, and no arrangement should be able to
    /// hide a file the user is dropping right now.
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
        return sorted
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
    @State private var hoveredClipboardClear = false
    @State private var hoveredClipboardSearch = false
    @State private var hoveredClipboardPin: UUID?
    @FocusState private var clipboardSearchFocused: Bool
    @ObservedObject private var audioOutput = AudioOutputStore.shared
    @State private var hoveredOutputPicker = false
    @State private var hoveredLowPower = false
    /// Nil when the setting is off, which is also how the token lines are
    /// suppressed — the card asks for nothing it was not given.
    var tokenUsage: TokenUsageSummary?
    var tokenPeriod: TokenUsagePeriod = .today
    @ObservedObject private var destinations = DestinationStore.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight)
    }
    private func textSize(_ base: CGFloat) -> CGFloat { base * textScale }

    /// The width every card's header icon is laid out in.
    ///
    /// SF Symbols differ enormously in intrinsic width —
    /// `chevron.left.forwardslash.chevron.right` on the Codex card is roughly
    /// three times `asterisk` on Claude's — so a header sized to its own icon
    /// started its title at a different x on every page. Paging left and right
    /// slid the heading back and forth underneath a pill that was otherwise
    /// holding perfectly still. A fixed slot costs a few points and buys a
    /// column.
    private var headerIconWidth: CGFloat { s(NotchSpace.mark) }

    /// And the height, so the first line of body copy also shares a baseline
    /// from card to card. It is the glyph well's height: the well is the
    /// tallest thing on the line, and every card's first body line hangs the
    /// same distance below it.
    private var headerHeight: CGFloat { s(NotchSpace.mark) }

    /// The grey of a header that has no state to report. The same grey an
    /// idle session's band wears, so "no colour" means the same thing on
    /// every card.
    private var neutralTint: Color { .white.opacity(NotchOpacity.tertiary) }

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
        HStack(spacing: s(NotchSpace.snug)) {
            icon().frame(width: headerIconWidth)
            Text(title)
                .font(titleFont ?? font(size: NotchType.body, weight: .semibold))
                .tracking(tracking)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            trailing()
        }
        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
        .frame(height: headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The common case: a glyph in a tinted well, and a title.
    ///
    /// The well is where a card's state colour lives — the same rule the
    /// session tiles follow. A quota card is tinted by how close its fullest
    /// pool is to biting; a CI card by its worst run; a card with nothing to
    /// report gets the neutral grey. Before this the header was a 9pt glyph
    /// at 45% white, and fourteen cards opened with the same dim smudge.
    private func cardHeader<Trailing: View>(
        symbol: String, title: String, tint: Color? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        cardHeader(icon: { glyphWell(symbol, tint: tint ?? neutralTint) },
                   title: title, trailing: trailing)
    }

    /// A white glyph on a small tinted square: the mark every card opens with,
    /// and the leading object on a list row. The tint is nearly opaque so it
    /// reads as a colour, not a wash.
    private func glyphWell(_ symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(font(size: NotchType.caption, weight: .bold))
            .foregroundStyle(.white.opacity(NotchOpacity.primary))
            .frame(width: s(NotchSpace.mark), height: s(NotchSpace.mark))
            .background(
                RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                    .fill(tint.opacity(NotchOpacity.band))
            )
    }

    /// A pool and how full it is, as an object: the figure, a bar in the
    /// pool's colour, and the pool's name, on a quiet rounded surface.
    ///
    /// Claude, Cursor and Codex each drew this differently — two had bars,
    /// one had a sentence — and read as three unrelated cards. One meter,
    /// three cards.
    private func meterTile(percent: Int, label: String, footnote: String? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
        return VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            Text("\(percent)%")
                .font(font(size: NotchType.display, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .contentTransition(.numericText())
            meterBar(percent: percent, tint: quotaColor(percent))
            Text(footnote.map { "\(label) · \($0)" } ?? label)
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, s(NotchSpace.base))
        .padding(.vertical, s(NotchSpace.snug))
        .background(shape.fill(.white.opacity(NotchOpacity.wellFill)))
        .overlay(shape.stroke(.white.opacity(NotchOpacity.hairline), lineWidth: 0.5))
    }

    /// The bar on its own, for cards that lay their own figure beside it.
    private func meterBar(percent: Int, tint: Color) -> some View {
        MeterBar(percent: percent, tint: tint, thickness: s(NotchSpace.bar), reduceMotion: reduceMotion)
    }

    /// A meter's bar. It fills from empty when it first appears and moves,
    /// rather than jumps, when the figure changes — a bar that is simply
    /// already there is a picture of a level; one that fills is a reading.
    private struct MeterBar: View {
        let percent: Int
        let tint: Color
        let thickness: CGFloat
        let reduceMotion: Bool
        @State private var filled = false

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(NotchOpacity.highlight))
                    Capsule()
                        .fill(tint)
                        .frame(width: filled
                               ? max(thickness, geo.size.width * CGFloat(min(100, max(0, percent))) / 100)
                               : thickness)
                }
            }
            .frame(height: thickness)
            .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: percent)
            .onAppear {
                withAnimation(NotchMotion.enter(reduceMotion: reduceMotion)) { filled = true }
            }
        }
    }

    /// Which colour a header well or a bar takes for a pool this full. Green
    /// is "fine", amber is "before it bites", and the amber deepens rather
    /// than turning red: nothing on a usage card is an emergency.
    private func quotaColor(_ percent: Int) -> Color {
        if percent >= 90 { return NotchDesign.devReadyAmber.opacity(0.95) }
        if percent >= 70 { return NotchDesign.devReadyAmber.opacity(0.75) }
        return NotchDesign.devReadyGreen.opacity(0.8)
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
            case .clipboard(let items, let searching):
                clipboardCard(items, searching: searching)
            case .terminal(let snapshot):
                terminalCard(snapshot)
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

    /// The agents page is a shelf, not a list: one row of session tiles that
    /// scrolls sideways, and one well to jump to the session that wants you.
    ///
    /// The list it replaces was legible — one left edge, one metadata line —
    /// and still read as a sheet of type, because nothing on it was an object.
    /// Tiles are objects. The card joins live transcript state with recent
    /// terminal events, so a finished or blocked conversation does not
    /// masquerade as a running process or vanish the instant it goes quiet.
    private func agentsCard(_ sessions: [AgentSession]) -> some View {
        let shelf = AgentShelf(sessions)
        return VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            // Caption and the one action share the header row, so the strip
            // below is tiles edge to edge. There is no tracked "AGENT SESSIONS"
            // here: the deck chrome already names the page.
            HStack(spacing: s(NotchSpace.base)) {
                Text(shelf.caption ?? "")
                    .font(font(size: NotchType.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .lineLimit(1)
                Spacer(minLength: s(NotchSpace.snug))
                if let target = shelf.jumpTarget {
                    agentJumpWell(target)
                }
            }
            .frame(height: s(NotchSpace.well))
            // Sideways, not down. Two tiles fill the panel; the rest are one
            // swipe away instead of stacking the notch taller.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(NotchSpace.snug)) {
                        ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                            agentTile(session)
                                .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
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

    /// Codex meters one window. It used to be the one quota card with no bar —
    /// "52% used" as a sentence — so it never registered as the same kind of
    /// thing as the Claude card beside it.
    private func codexQuotaCard(_ quota: CodexQuota) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "chevron.left.forwardslash.chevron.right", title: "Codex",
                       tint: quotaColor(quota.usedPercent)) {
                Spacer(minLength: s(NotchSpace.snug))
                Text(quota.resetLabel)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
            }
            meterTile(percent: quota.usedPercent, label: "current window",
                      footnote: quota.updatedLabel)
                .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
            if let credits = quota.creditsLabel {
                Text(credits)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
            }
            tokenLines(TokenUsageSummary.codex, tokenUsage, period: tokenPeriod)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }


    /// Claude's two limits side by side. Showing only the session window hides
    /// the weekly one you actually run into on a heavy week; showing only the
    /// weekly hides the one that stops you mid-afternoon.

    /// Tokens used, folded into the card for the tool that used them.
    ///
    /// A tool total with its models beneath: the total answers "how much", the
    /// breakdown answers "by which model", and on a card this size only the
    /// largest two earn a line. Cache reads are not counted — see `TokenTally`.
    @ViewBuilder
    private func tokenLines(_ tool: String, _ usage: TokenUsageSummary?,
                            period: TokenUsagePeriod) -> some View {
        if let usage, usage.total(for: tool) > 0 || usage.cached(for: tool) > 0 {
            VStack(alignment: .leading, spacing: s(1)) {
                HStack(spacing: s(4)) {
                    Text(Self.compactTokens(usage.total(for: tool)))
                        .font(font(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("tokens · \(period.shortLabel)")
                        .font(font(size: 9))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                // Cached context is most of the traffic on a long session and
                // a fraction of the cost. Beside the total it is context;
                // inside it, it would be the only number you ever saw.
                if usage.cached(for: tool) > 0 {
                    Text("+\(Self.compactTokens(usage.cached(for: tool))) cached")
                        .font(font(size: 9))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
                ForEach(usage.models(for: tool).prefix(usage.modelRows(for: tool)), id: \.model) { entry in
                    HStack(spacing: s(4)) {
                        Text(Self.shortModel(entry.model))
                            .font(font(size: 9))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Self.compactTokens(entry.tokens))
                            .font(font(size: 9))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .padding(.top, s(1))
        }
    }

    /// 213_100 -> "213.1K". Two significant places, because the difference
    /// between 1.1M and 1.9M is the whole point of showing it.
    static func compactTokens(_ value: Int) -> String {
        let n = Double(value)
        switch n {
        case 1_000_000_000...: return String(format: "%.1fB", n / 1_000_000_000)
        case 1_000_000...: return String(format: "%.1fM", n / 1_000_000)
        case 1_000...: return String(format: "%.1fK", n / 1_000)
        default: return String(value)
        }
    }

    /// "claude-opus-4-8" -> "opus-4-8". The vendor prefix is already the card.
    static func shortModel(_ raw: String) -> String {
        var name = raw
        for prefix in ["claude-", "anthropic/", "openai/", "gpt-"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count))
            if prefix == "gpt-" { name = "gpt-" + name }
        }
        return name
    }

    private func claudeQuotaCard(_ quota: ClaudeQuota) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            // The header wears the fuller pool's colour: that is the one that
            // stops you, whichever it is.
            cardHeader(symbol: "asterisk", title: "Claude",
                       tint: quotaColor(max(quota.sessionPercent, quota.weeklyPercent)))

            // Each window carries its own reset. Naming only the nearer one
            // hid the session reset whenever the weekly figure happened to be
            // a few points higher — and the session window is the one that
            // stops you this afternoon.
            HStack(spacing: s(NotchSpace.snug)) {
                meterTile(percent: quota.sessionPercent, label: "session",
                          footnote: ClaudeQuota.resetClock(for: quota.sessionResetsAt))
                    .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
                meterTile(percent: quota.weeklyPercent, label: "week",
                          footnote: ClaudeQuota.resetClock(for: quota.weeklyResetsAt))
                    .notchReveal(1, scale: readability, reduceMotion: reduceMotion)
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
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
            }
            tokenLines(TokenUsageSummary.claude, tokenUsage, period: tokenPeriod)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Cursor's included usage for the billing cycle.
    ///
    /// One meter, not two: Cursor meters a single pool per cycle rather than
    /// Claude's session/week pair. The raw counts sit under the bar because the
    /// percentage alone cannot distinguish "100% of 500" from "100% of 9201".
    private func cursorQuotaCard(_ quota: CursorQuota) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "cursorarrow", title: "Cursor",
                       tint: quota.isUnlimited ? neutralTint : quotaColor(
                        max(quota.percentUsed, quota.autoPercentUsed ?? 0, quota.apiPercentUsed ?? 0)))

            if quota.isUnlimited {
                Text("unlimited")
                    .font(font(size: NotchType.display, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
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
                HStack(spacing: s(NotchSpace.snug)) {
                    meterTile(percent: auto, label: "auto")
                        .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
                    meterTile(percent: api, label: "API")
                        .notchReveal(1, scale: readability, reduceMotion: reduceMotion)
                }
            } else {
                meterTile(percent: quota.percentUsed, label: quota.usageLabel)
                    .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
            }

            Text([quota.isUnlimited ? nil : quota.usageLabel,
                  quota.bonusLabel,
                  CursorQuota.cycleLabel(for: quota.cycleEnd),
                  quota.membershipLabel,
                  quota.onDemandEnabled ? "on-demand on" : nil]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// GitHub Actions for the repos you have agents working in.
    /// A live shell.
    ///
    /// The card takes the keyboard only when clicked, and gives it back on
    /// Escape or when the pill loses key. Anything else and the pill would
    /// swallow every keystroke on the machine the moment it opened.
    private func terminalCard(_ snapshot: TerminalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "apple.terminal.fill",
                       title: snapshot.isFocused ? "Terminal — typing" : "Terminal",
                       tint: snapshot.isFocused ? NotchDesign.accent : nil, trailing: {
                Spacer(minLength: s(6))
                if snapshot.exitStatus != nil {
                    Button { TerminalStore.shared.restart() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: s(8), weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Start a new shell")
                }
            })

            ZStack(alignment: .topLeading) {
                TerminalGridView(isFocused: snapshot.isFocused,
                                 fontSize: s(9), lineHeight: s(11))
                    .opacity(snapshot.exitStatus == nil ? 1 : 0.45)
                if let status = snapshot.exitStatus {
                    Text("shell exited (\(status))")
                        .font(.system(size: s(9), design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                }
                TerminalKeyCatcher(
                    isFocused: snapshot.isFocused,
                    onKey: { event in
                        // Escape hands the keyboard back rather than reaching
                        // the shell: without a way out that does not need the
                        // mouse, focus is a trap.
                        if event.keyCode == 53 {
                            closeTerminalFocus()
                            return true
                        }
                        return TerminalStore.shared.handle(event: event)
                    },
                    onFocusChange: { _ in }
                )
                .frame(width: 0, height: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if snapshot.isFocused {
                    closeTerminalFocus()
                } else {
                    TerminalStore.shared.setFocused(true)
                    actions.captureKeyboard(true)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !snapshot.isFocused {
                    Text("click to type")
                        .font(.system(size: s(7)))
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
        }
    }

    private func closeTerminalFocus() {
        TerminalStore.shared.setFocused(false)
        actions.captureKeyboard(false)
    }

    private func clipboardCard(_ items: [ClipboardEntry], searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: s(3)) {
            cardHeader(symbol: "doc.on.clipboard.fill", title: "Clipboard",
                       tint: searching ? NotchDesign.accent : nil, trailing: {
                Spacer(minLength: s(6))
                Button {
                    if searching {
                        ClipboardStore.shared.endSearch()
                        actions.captureKeyboard(false)
                    } else {
                        ClipboardStore.shared.beginSearch()
                        actions.captureKeyboard(true)
                        clipboardSearchFocused = true
                    }
                } label: {
                    Image(systemName: searching ? "xmark" : "magnifyingglass")
                        .font(.system(size: s(8)))
                        .foregroundStyle(.white.opacity(
                            searching || hoveredClipboardSearch ? 0.95 : 0.5))
                        .padding(s(3))
                        .background(
                            Circle().fill(Color.white.opacity(
                                searching || hoveredClipboardSearch ? 0.16 : 0.07))
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredClipboardSearch = $0 }
                .help(searching ? "Close search" : "Search remembered copies")

                if !items.isEmpty {
                    // Pushed to the far edge so it is never next to the first
                    // entry -- this button throws away everything, and a
                    // destructive control should not sit under a wandering
                    // pointer on its way to the list.
                    Button { ClipboardStore.shared.clear() } label: {
                        HStack(spacing: s(3)) {
                            Image(systemName: "trash")
                                .font(.system(size: s(8)))
                            Text("Clear")
                                .font(font(size: 9, weight: .medium))
                        }
                        .foregroundStyle(.white.opacity(hoveredClipboardClear ? 0.95 : 0.5))
                        .padding(.horizontal, s(5))
                        .padding(.vertical, s(2))
                        .background(
                            Capsule().fill(Color.white.opacity(hoveredClipboardClear ? 0.16 : 0.07))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredClipboardClear = $0 }
                    .help("Forget every unpinned copy")
                }
            })

            if searching {
                clipboardSearchField
            }

            if items.isEmpty {
                Text(searching ? "No copy matches that." : "Nothing copied yet.")
                    .font(font(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: s(2)) {
                    ForEach(items) { entry in
                      // The pin is a sibling of the copy button, not a control
                      // inside its label: a button nested in another button's
                      // label swallows its own taps.
                      HStack(alignment: .top, spacing: s(3)) {
                        clipboardPinButton(entry)
                        Button { ClipboardStore.shared.copyBack(entry) } label: {
                            HStack(alignment: .top, spacing: s(5)) {
                                clipboardMark(entry)
                                Text(entry.preview)
                                    .font(font(size: 10))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .lineLimit(entry.displayLines)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(relativeStart(for: entry.copiedAt))
                                    .font(font(size: 8))
                                    .foregroundStyle(.white.opacity(0.4))
                                    .fixedSize()
                            }
                            .padding(.horizontal, s(4))
                            .padding(.vertical, s(2))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: s(4), style: .continuous)
                                    .fill(Color.white.opacity(entry.isPinned ? 0.12 : 0.06))
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Copy again")
                      }
                      .onHover { hoveredClipboardPin = $0 ? entry.id : nil }
                    }
                }
            }
        }
    }

    /// The search field, shown only while the search is open.
    ///
    /// Escape closes it rather than clearing it, because a field you have to
    /// empty by hand before you can get out of it is a trap in a pill this
    /// small; Return does the same, since there is nothing to submit.
    private var clipboardSearchField: some View {
        HStack(spacing: s(4)) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: s(8)))
                .foregroundStyle(.white.opacity(0.4))
            TextField("Search copies", text: Binding(
                get: { ClipboardStore.shared.query },
                set: { ClipboardStore.shared.query = $0 }
            ))
            .textFieldStyle(.plain)
            .font(font(size: 10))
            .foregroundStyle(.white.opacity(0.9))
            .focused($clipboardSearchFocused)
            .onSubmit { closeClipboardSearch() }
            .onExitCommand { closeClipboardSearch() }
        }
        .padding(.horizontal, s(5))
        .padding(.vertical, s(3))
        .background(
            RoundedRectangle(cornerRadius: s(5), style: .continuous)
                .fill(Color.white.opacity(0.08))
        )
        .onAppear { clipboardSearchFocused = true }
    }

    private func closeClipboardSearch() {
        ClipboardStore.shared.endSearch()
        actions.captureKeyboard(false)
    }

    /// The copy as an object where the text allows it: a swatch for a colour,
    /// a link mark for a URL. Plain text gets nothing — a mark on every row
    /// would be a column of decoration, and the point is that these two stand
    /// out from the rest.
    @ViewBuilder
    private func clipboardMark(_ entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .color(let r, let g, let b):
            RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                .fill(Color(red: r, green: g, blue: b))
                .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                    .stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
                .frame(width: s(NotchSpace.mark), height: s(NotchSpace.mark))
                .accessibilityLabel("colour swatch")
        case .url:
            glyphWell("link", tint: NotchDesign.accent)
                .accessibilityLabel("link")
        case .text:
            EmptyView()
        }
    }

    /// Shown filled on a pinned entry, and only on hover otherwise, so an
    /// unpinned list is not a column of grey pins competing with the text.
    private func clipboardPinButton(_ entry: ClipboardEntry) -> some View {
        let atLimit = !entry.isPinned
            && ClipboardStore.shared.pinnedCount >= ClipboardStore.pinCapacity
        return Button { ClipboardStore.shared.togglePin(entry) } label: {
            Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                .font(.system(size: s(8)))
                .rotationEffect(.degrees(45))
                .foregroundStyle(.white.opacity(
                    entry.isPinned ? 0.85 : (hoveredClipboardPin == entry.id ? 0.5 : 0)
                ))
                .frame(width: s(12), height: s(12))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(atLimit)
        .help(entry.isPinned
              ? "Unpin — it goes back to being forgotten in turn"
              : (atLimit
                 ? "\(ClipboardStore.pinCapacity) pins is the limit; unpin one first"
                 : "Pin — kept until you unpin it"))
    }

    /// GitHub Actions for the repos you have agents working in.
    ///
    /// One line per run, led by a well in the run's colour. The two-line row
    /// with a 5pt dot was taller than its budget — the third run was always
    /// half-clipped — and the dot was the only place the state showed until
    /// you read the word at the far end. The well is the state; the line is
    /// "repo · workflow", repo first, because the card follows whichever repos
    /// your agents are in and "Release — passed" on its own says nothing about
    /// *whose* release.
    private func ciCard(_ runs: [CIRun]) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "checkmark.seal.fill", title: "CI",
                       tint: runs.map { color(for: $0.state) }.first ?? neutralTint)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        Button { actions.openURL(run.id) } label: {
                            HStack(spacing: s(NotchSpace.base)) {
                                glyphWell(symbol(for: run.state), tint: color(for: run.state))
                                (Text(run.repoName)
                                    .font(font(size: NotchType.body, weight: .semibold))
                                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                                 + Text("  \(run.workflow)")
                                    .font(font(size: NotchType.caption, weight: .medium))
                                    .foregroundStyle(.white.opacity(NotchOpacity.secondary)))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Spacer(minLength: s(NotchSpace.snug))
                                Text(run.statusLabel)
                                    .font(font(size: NotchType.caption, weight: .semibold))
                                    .foregroundStyle(color(for: run.state))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .frame(height: s(NotchSpace.section))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                        .notchBump(on: run.state, reduceMotion: reduceMotion)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The mark inside a run's well: what happened, not just which colour.
    private func symbol(for state: CIRun.State) -> String {
        switch state {
        case .failed: return "xmark"
        case .running: return "arrow.triangle.2.circlepath"
        case .passed: return "checkmark"
        case .other: return "minus"
        }
    }

    /// What your agents have said recently, one line each, led by a well in
    /// the alert's colour: orange for one that is waiting on you, green for a
    /// finished turn. The two-line rows put "finished" under the title in grey
    /// and the age floating beside it; nothing on the row said which kind of
    /// alert it was until you read it.
    private func recentAlertsCard(_ alerts: [DevReadyAlert]) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "bell.fill", title: "Notifications",
                       tint: alerts.contains { $0.kind == .waiting } ? .orange : neutralTint) {
                if alerts.count > 3 {
                    Text("\(alerts.count)")
                        .font(font(size: NotchType.caption, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, s(NotchSpace.snug))
                        .padding(.vertical, s(NotchSpace.tight))
                        .background(.white.opacity(NotchOpacity.highlight), in: Capsule())
                }
                Spacer(minLength: 0)
                Button("Clear") { actions.clearRecentActivity() }
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .buttonStyle(.plain)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                        alertRow(alert)
                            .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                    }
                }
            }
            .frame(maxHeight: s(NotchSpace.section) * 3 + s(NotchSpace.tight) * 2)
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func alertRow(_ alert: DevReadyAlert) -> some View {
        let waiting = alert.kind == .waiting
        let subtitle = alert.displaySubtitle.flatMap { $0.isEmpty ? nil : "  \($0)" } ?? ""
        return Button { actions.focusAlert(alert) } label: {
            HStack(spacing: s(NotchSpace.base)) {
                glyphWell(waiting ? "hand.raised.fill" : "checkmark",
                          tint: waiting ? .orange : NotchDesign.devReadyGreen)
                (Text(alert.displayTitle)
                    .font(font(size: NotchType.body, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                 + Text(subtitle)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary)))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: s(NotchSpace.snug))
                Text(alert.shortAgeText())
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: s(NotchSpace.section))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

    /// One session as an object: a coloured header band carrying the vendor
    /// mark, over a dark body with the name and the state's age.
    ///
    /// The first cut of this tile was a grey well with a grey glyph and a 5pt
    /// coloured dot, and read as generic dark UI. Droppy's tiles each wear a
    /// saturated band with a white mark on it; that band is most of what makes
    /// them look like objects rather than list rows. Here the band is the
    /// state colour — `color(for:)` unchanged, used at full strength instead
    /// of as a dot — so green is working, orange is blocked on you, and idle
    /// recedes to grey. No vendor branding is invented.
    ///
    /// Runtime, context, model, effort and permission mode are not here. They
    /// were a metadata line under a list row; a tile has no line to put them
    /// on, and the tile is the tap target that opens the session where all of
    /// that is visible anyway. `AgentRowMetadata` still computes them and is
    /// still tested; this view just does not draw it.
    private func agentTile(_ session: AgentSession) -> some View {
        let tint = color(for: session.state)
        let shape = RoundedRectangle(cornerRadius: s(NotchRadius.tile), style: .continuous)
        return Button {
            actions.focusAgentSession(session)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                agentTileBand(session, tint: tint)
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    Text(session.displayName)
                        .font(font(size: NotchType.body, weight: .semibold))
                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // The age the old status capsule carried — "idle 18m" — at
                    // the weight of a fact you consult, not one you read.
                    Text(session.statusLabel)
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .contentTransition(.numericText())
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, s(NotchSpace.base))
                .padding(.top, s(NotchSpace.snug))
                .padding(.bottom, s(NotchSpace.base))
            }
            .frame(width: s(NotchSpace.tile))
            .background(shape.fill(.white.opacity(NotchOpacity.wellFill)))
            .clipShape(shape)
            // A session that wants you gets its band colour on the edge too,
            // so the tile reads as lit rather than merely labelled.
            .overlay(shape.stroke(session.isWaiting ? tint.opacity(0.48) : .white.opacity(NotchOpacity.hairline),
                                  lineWidth: 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(session.displayName), \(session.statusLabel)")
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.statusLabel)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.state)
        // The kind of state, not the state: `.waiting(since:)` carries a
        // timestamp, and a tile must not swell every time the age ticks.
        .notchBump(on: session.state.name, reduceMotion: reduceMotion)
    }

    /// The tile's coloured header: the vendor mark in white on the state
    /// colour, in a well-sized slot so the mark sits at the same place on
    /// every tile, and the model as a badge at the other end.
    ///
    /// The mark says which tool; the badge says which model, which for Cursor
    /// or OpenCode is the thing that actually tells two sessions apart. It is
    /// text, not a glyph: SF Symbols has no mark for Anthropic, OpenAI or
    /// Google, and one invented here would have to be learned. The badge is a
    /// darker patch on the band rather than a second colour, so state still
    /// owns the hue.
    ///
    /// An unknown agent gets an empty slot rather than a stand-in glyph — a
    /// wrong-but-confident mark is worse than none, and the name still shows.
    private func agentTileBand(_ session: AgentSession, tint: Color) -> some View {
        HStack(spacing: 0) {
            agentMark(session)
                .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                .accessibilityLabel(session.agentName)
            Spacer(minLength: s(NotchSpace.snug))
            if let model = session.modelShortLabel {
                Text(model)
                    .font(font(size: NotchType.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, s(NotchSpace.snug))
                    .padding(.vertical, s(NotchSpace.tight))
                    .background(Capsule().fill(.black.opacity(NotchOpacity.badge)))
                    .accessibilityLabel(session.modelLabel ?? model)
            }
        }
        .padding(.horizontal, s(NotchSpace.snug))
        .padding(.vertical, s(NotchSpace.snug))
        .frame(maxWidth: .infinity)
        .background(tint.opacity(NotchOpacity.band))
    }

    /// Which tool a session belongs to, as the thing you would recognise
    /// fastest: the vendor's app icon when the app is installed, Anthropic's
    /// own mark for Claude Code when it is not (it ships in the bundle), and
    /// the SF Symbol only as a last resort. The one honest colour on the band
    /// besides the state's is the vendor's own.
    @ViewBuilder
    private func agentMark(_ session: AgentSession) -> some View {
        if let icon = session.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(s(NotchSpace.tight))
        } else if session.knownAgent == .claudeCode {
            Image("ClaudeMark")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .padding(s(NotchSpace.snug))
        } else if let symbol = session.vendorSymbol {
            Image(systemName: symbol)
                .font(font(size: NotchType.body, weight: .bold))
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
        } else {
            Color.clear
        }
    }

    /// The shelf's one action: jump to the session `AgentShelf` chose.
    ///
    /// One well, not two. Droppy's file shelf has a check and a trash because
    /// files are confirmed or discarded; an agent session has one real action
    /// from here, which is to go to it. The glyph borrows the state colour
    /// only when the target is waiting, so the well itself says "someone
    /// needs you" before you read anything.
    private func agentJumpWell(_ target: AgentSession) -> some View {
        Button {
            actions.focusAgentSession(target)
        } label: {
            Image(systemName: "arrow.up.right")
                .font(font(size: NotchType.caption, weight: .bold))
                .foregroundStyle(target.isWaiting
                    ? color(for: target.state)
                    : .white.opacity(NotchOpacity.secondary))
                .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                .background(Circle().fill(.white.opacity(NotchOpacity.wellFill)))
                .overlay(Circle().stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Jump to \(target.displayName)")
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

    /// The card people see most, and the one place the island gets large,
    /// honest colour for free: the album's. The artwork is drawn at twice a
    /// well, and a blurred copy of it glows behind the card, masked to die
    /// before the edges so it reads as light from the cover rather than a
    /// second surface.
    private func mediaCard(_ np: NowPlaying) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            HStack(spacing: s(NotchSpace.base)) {
                mediaArtwork(np)
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    Text(np.title)
                        .font(font(size: NotchType.display, weight: .semibold))
                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                        .lineLimit(expandToFill ? 2 : 1)
                    Text(np.artist)
                        .font(font(size: NotchType.body, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
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
        .background { mediaGlow(np) }
    }

    /// The artwork's light. Blurred past recognition, at glow opacity, and
    /// masked with an elliptical falloff centred where the cover sits, so
    /// there is no edge to see — which is what lets it live inside the card
    /// without the pill's clip. Bleeds `base` into the insets so the falloff
    /// is not visibly boxed by the content rect.
    @ViewBuilder
    private func mediaGlow(_ np: NowPlaying) -> some View {
        if let image = np.artwork {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .blur(radius: s(NotchSpace.section))
                // A blur paints past its bounds, and the content layer is not
                // clipped to the pill; unclipped, the glow leaked onto the
                // desktop beside the island.
                .clipped()
                .opacity(NotchOpacity.glow)
                .mask(
                    EllipticalGradient(colors: [.white, .clear],
                                       center: UnitPoint(x: 0.22, y: 0.3),
                                       startRadiusFraction: 0, endRadiusFraction: 0.8)
                )
                .padding(-s(NotchSpace.base))
                .allowsHitTesting(false)
                .id(ObjectIdentifier(image))
                .transition(.opacity)
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
                    Rectangle().fill(.white.opacity(NotchOpacity.hairline))
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .font(font(size: NotchType.display))
                }
            }
        }
        .frame(width: s(NotchSpace.well * 2), height: s(NotchSpace.well * 2))
        .clipShape(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous))
        // A cover is a printed object; the hairline is its edge, as on a tile.
        .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
            .stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
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

    /// The app's own icon is the object here — the one card that gets a real
    /// full-colour mark for free — so it is drawn at well size, not 19pt.
    private func appCard(title: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            Text(title)
                .font(font(size: NotchType.caption, weight: .semibold))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .frame(height: headerHeight)
            HStack(spacing: s(NotchSpace.base)) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                } else {
                    glyphWell("app.fill", tint: neutralTint)
                }
                Text(name)
                    .font(font(size: NotchType.title, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                    .lineLimit(expandToFill ? 3 : 2)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    private func volumeCard(_ level: Int) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: level == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                       title: "Volume")
            Text("\(level)%")
                .font(font(size: NotchType.display, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .contentTransition(.numericText())
            meterBar(percent: level, tint: .white.opacity(NotchOpacity.primary))
            outputPickerRow
        }
        .frame(minWidth: s(72), alignment: .leading)
    }

    /// Where the sound is going, and a way to send it somewhere else.
    ///
    /// The devices open in an `NSMenu` rather than growing the card: a list
    /// long enough to hold a Mac's real device count would be taller than the
    /// pill, and the menu is the one thing here that survives the pill
    /// collapsing underneath the pointer.
    @ViewBuilder
    private var outputPickerRow: some View {
        if let current = audioOutput.current {
            Button {
                AudioOutputMenu.shared.present(
                    devices: audioOutput.devices,
                    current: audioOutput.currentID
                ) { AudioOutputStore.shared.select($0) }
            } label: {
                HStack(spacing: s(4)) {
                    Image(systemName: current.symbolName)
                        .font(.system(size: s(9)))
                    Text(current.name)
                        .font(font(size: 10))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: s(7)))
                        .opacity(audioOutput.devices.count > 1 ? 1 : 0)
                }
                .foregroundStyle(.white.opacity(hoveredOutputPicker ? 0.9 : 0.5))
                .padding(.horizontal, s(5))
                .padding(.vertical, s(2))
                .background(
                    Capsule().fill(Color.white.opacity(hoveredOutputPicker ? 0.14 : 0.06))
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(audioOutput.devices.count < 2)
            .onHover { hoveredOutputPicker = $0 }
            .help(audioOutput.devices.count > 1
                  ? "Choose where sound goes"
                  : "The only output this Mac has right now")
        }
    }

    private func calendarCard(_ event: CalendarEvent) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "calendar", title: "Next event", tint: .orange)
            Text(event.title)
                .font(font(size: NotchType.title, weight: .semibold))
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .lineLimit(expandToFill ? 3 : 2)
            Text(relativeStart(for: event.start))
                .font(font(size: NotchType.body, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
        }
        .frame(minWidth: s(110), alignment: .leading)
    }

    private func timerCard(_ timer: ActiveTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                cardHeader(symbol: timer.isFocusSession ? "moon.stars.fill" : "timer",
                           title: timer.isFocusSession ? "Focus session" : timer.label,
                           tint: timer.isFocusSession ? NotchDesign.accent : nil)
                Text(StatusFormatting.countdown(timer.remaining(at: context.date)))
                    .font(font(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                Button(timer.isFocusSession ? "End focus" : "Cancel", action: onCancelTimer)
                    .font(font(size: NotchType.body, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
            }
            .frame(minWidth: s(88), alignment: .leading)
        }
    }

    /// Two meters, tinted by how full each is. Two percentages in a column
    /// read identically at 23% and 93%; a bar does not.
    private func systemStatsCard(_ stats: SystemStats) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: "gauge.with.dots.needle.67percent", title: "System",
                       tint: quotaColor(max(stats.cpuPercent, stats.memoryPercent)))
            statLine(title: "CPU", value: stats.cpuPercent)
            statLine(title: "RAM", value: stats.memoryPercent)
        }
        .frame(minWidth: s(88), alignment: .leading)
    }

    private func statLine(title: String, value: Int) -> some View {
        HStack(spacing: s(NotchSpace.base)) {
            Text(title)
                .font(font(size: NotchType.caption, weight: .semibold))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .frame(width: s(NotchSpace.well + NotchSpace.base), alignment: .leading)
            meterBar(percent: value, tint: quotaColor(value))
            Text("\(value)%")
                .font(font(size: NotchType.body, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .contentTransition(.numericText())
                .frame(width: s(NotchSpace.well + NotchSpace.base), alignment: .trailing)
        }
        .frame(height: s(NotchSpace.mark))
    }

    /// Green while there is plenty, amber as it runs down — the battery's own
    /// colour rule, read off the remaining charge rather than the used share
    /// the quota cards meter.
    private func batteryCard(_ status: BatteryStatus) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            cardHeader(symbol: batterySymbol(for: status),
                       title: status.isCharging ? "Charging" : "Battery",
                       tint: status.isCharging ? NotchDesign.devReadyGreen : quotaColor(100 - status.level))
            Text("\(status.level)%")
                .font(font(size: 22, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .contentTransition(.numericText())
            meterBar(percent: status.level,
                     tint: status.isCharging ? NotchDesign.devReadyGreen : quotaColor(100 - status.level))
            lowPowerRow(status)
        }
        .frame(minWidth: s(72), alignment: .leading)
    }

    /// Low Power Mode, shown and reachable but not switched from here.
    ///
    /// Only root can change it -- `pmset -a lowpowermode` refuses outright --
    /// and the alternatives are an admin password prompt on every toggle or a
    /// privileged helper this app cannot sign for. Opening the pane it lives
    /// in is the honest version: one click instead of five, and no lie about
    /// what the button does.
    private func lowPowerRow(_ status: BatteryStatus) -> some View {
        Button {
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.Battery-Settings.extension")
            else { return }
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: s(4)) {
                Image(systemName: status.isLowPower
                      ? "battery.25percent.bolt.slash" : "leaf")
                    .font(.system(size: s(9)))
                Text(status.isLowPower ? "Low Power on" : "Low Power off")
                    .font(font(size: 10))
                    .lineLimit(1)
            }
            .foregroundStyle(status.isLowPower
                             ? Color.yellow.opacity(hoveredLowPower ? 1 : 0.85)
                             : .white.opacity(hoveredLowPower ? 0.9 : 0.45))
            .padding(.horizontal, s(5))
            .padding(.vertical, s(2))
            .background(
                Capsule().fill(Color.white.opacity(hoveredLowPower ? 0.14 : 0.06))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hoveredLowPower = $0 }
        .help("Open Battery settings — only macOS itself can switch this")
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
                    cardHeader(symbol: "tray.full.fill", title: "Shelf",
                               tint: isDropTargeted ? NotchDesign.accent : nil) {
                        Spacer(minLength: 0)
                        if !items.isEmpty {
                            ShareLink(items: items.map(\.url)) {
                                Image(systemName: "square.and.arrow.up")
                                    .font(font(size: NotchType.body, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                            Button { items.forEach { actions.removeShelfItem($0.id) } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(font(size: NotchType.body, weight: .medium))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        }
                    }
                }
            }

            // Files already on the shelf always win the space. The drop zone
            // only stands in when there is nothing else to show — a targeting
            // flag that failed to clear must never be able to hide the chips,
            // which are the only route to the destination menu.
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(NotchSpace.snug)) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            shelfChip(item)
                                .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                        }
                    }
                    // The folder badge is a 13pt circle centred 3pt past the
                    // chip's corner, so it reaches ~10pt beyond it; without
                    // this the strip clipped it to a blue crescent.
                    .padding(.trailing, s(NotchSpace.base))
                    .padding(.bottom, s(NotchSpace.roomy))
                }
                .frame(height: s(NotchSpace.section) * 2 + s(NotchSpace.roomy), alignment: .top)
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
                    .frame(height: s(NotchSpace.section) * 2 + s(NotchSpace.roomy))
            }
        }
        .frame(minWidth: s(108), alignment: .leading)
    }

    /// The file itself when Quick Look can draw it — the screenshot, the
    /// PDF's first page — and its type icon until then or otherwise. The
    /// thumbnail is asked for at twice the slot so it is sharp on a Retina
    /// notch, and sits on the type icon's footprint so the chip does not
    /// reflow when it arrives.
    @ViewBuilder
    private func shelfPreview(_ item: ShelfCardItem) -> some View {
        if let thumb = thumbnails.thumbnail(for: item.url) {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                    .stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
                .transition(.opacity)
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                .onAppear {
                    thumbnails.request(item.url, size: CGSize(width: s(NotchSpace.well + NotchSpace.roomy),
                                                              height: s(NotchSpace.well)))
                }
        }
    }

    private func shelfChip(_ item: ShelfCardItem) -> some View {
        // A Button, not `.onTapGesture`: `.onDrag` installs its own gesture on
        // the same view and swallows taps often enough that clicking a chip did
        // nothing at all. A button's click goes through AppKit and is not in
        // competition with the drag.
        Button {
            presentDestinationMenu(for: item)
        } label: {
            VStack(spacing: s(NotchSpace.tight)) {
                shelfPreview(item)
                    .frame(width: s(NotchSpace.well + NotchSpace.roomy), height: s(NotchSpace.well))
                Text(item.name)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: s(NotchSpace.well + NotchSpace.section))
            }
            .frame(width: s(NotchSpace.well + NotchSpace.section + NotchSpace.roomy),
                   height: s(NotchSpace.section * 2))
            .background(
                RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .fill(Color.white.opacity(hoveredShelfItem == item.id
                                              ? NotchOpacity.highlight : NotchOpacity.wellFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .stroke(.white.opacity(NotchOpacity.hairline), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Drag a chip straight into Finder, Mail, Messages -- the way a file
        // leaves the shelf without picking a folder first. The click above is
        // AppKit's and does not compete with this.
        .onDrag {
            LogStore.shelf("dragging out \(item.name)")
            ShelfDragHold.shared.begin(hold: actions.holdNotchOpen)
            // A file-URL provider is what Finder and every share target read;
            // `contentsOf:` also gives the drag its real file icon.
            return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        }
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
        .contextMenu {
            Button("Move to…") { presentDestinationMenu(for: item) }
            Button("Share / AirDrop…") { ShelfDestinationMenu.airDrop(item.url) }
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

    /// Charging is a bolt; otherwise the battery at its level. The old
    /// `battery.50.bolt` family does not exist in SF Symbols — only the full
    /// one has a bolt variant — so a charging Mac drew no glyph at all.
    private func batterySymbol(for status: BatteryStatus) -> String {
        if status.isCharging { return "bolt.fill" }
        switch status.level {
        case 0...10: return "battery.0percent"
        case 11...35: return "battery.25percent"
        case 36...65: return "battery.50percent"
        case 66...90: return "battery.75percent"
        default: return "battery.100percent"
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
