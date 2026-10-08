import SwiftUI

struct ExpandedActivityCard: View {
    let activity: ExpandedActivity
    let appIcon: NSImage?
    let actions: NotchActions
    var onCancelTimer: () -> Void = {}
    var readability: CGFloat = 1.0
    var textScale: CGFloat = 1.0
    var expandToFill: Bool = false
    /// Optional test/preview control. Nil follows the system accessibility setting.
    var reduceMotionOverride: Bool?
    /// Height reserved at the bottom when page dots overlay this surface
    /// (media). Zero on tray pages where chrome lives outside the card.
    var bottomChromeHeight: CGFloat = 0
    @State private var hoveredShelfItem: UUID?
    @State private var hoveredClipboardPin: UUID?
    @FocusState private var clipboardSearchFocused: Bool
    @ObservedObject private var audioOutput = AudioOutputStore.shared
    @State private var hoveredOutputPicker = false
    @State private var hoveredLowPower = false
    @State private var unavailableCommandTargets = Set<String>()
    /// Nil when the setting is off, which is also how the token lines are
    /// suppressed — the card asks for nothing it was not given.
    var tokenUsage: TokenUsageSummary?
    var tokenPeriod: TokenUsagePeriod = .today
    @ObservedObject private var destinations = DestinationStore.shared
    @ObservedObject private var thumbnails = ThumbnailStore.shared
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { reduceMotionOverride ?? systemReduceMotion }

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight)
    }
    private func textSize(_ base: CGFloat) -> CGFloat { base * textScale }

    /// The grey of a header that has no state to report. The same grey an
    /// idle session's band wears, so "no colour" means the same thing on
    /// every card.
    private var neutralTint: Color { .white.opacity(NotchOpacity.tertiary) }

    /// Provider name for quota cards. The Fetch tab bar replaced the deck
    /// footer that used to flash "Claude quota" on hover, so each card names
    /// itself when you swipe between Codex, Claude, and Cursor on Usage.
    @ViewBuilder
    private func quotaProviderHeader(
        _ title: String,
        bundleIds: [String] = [],
        symbol: String? = nil,
        mark: String? = nil,
        updatedAt: Date? = nil
    ) -> some View {
        HStack(spacing: s(NotchSpace.snug)) {
            NotchCardHeading(title: title, symbol: symbol ?? "chart.bar",
                             icon: AppIconCache.shared.icon(forAnyOf: bundleIds), asset: mark,
                             scale: readability, textScale: textScale)
            if let updatedAt {
                Spacer(minLength: s(NotchSpace.tight))
                HStack(spacing: s(NotchSpace.tight)) {
                    Text(Date().timeIntervalSince(updatedAt) > 3600 ? "Cached" : "Updated")
                    Text(updatedAt, style: .relative)
                        .monospacedDigit()
                }
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel("Usage last updated \(updatedAt.formatted())")
            }
        }
    }

    /// A white glyph on a small tinted square: the leading object on a list
    /// row. The tint is nearly opaque so it reads as a colour, not a wash.
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

    /// Keep usage tiles quiet: the bar carries the semantic colour while the
    /// number and label sit on a neutral surface.
    private func meterTile(percent: Int, label: String, footnote: String? = nil) -> some View {
        let radius = s(NotchRadius.tile)
        return VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            Text("\(percent)%")
                .font(font(size: NotchType.hero, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            meterBar(percent: percent, tint: quotaColor(percent))
            Text(footnote.map { "\(label) · \($0)" } ?? label)
                .font(font(size: NotchType.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
        }
        // Height comes from the content, never from the card. Stretching to
        // the container tied the tile's height to a number that ANIMATES when
        // you page between cards of different heights — and `.background`
        // follows that animating height while the text stays pinned to
        // topLeading. You saw the label on black with the fill still growing
        // up behind it. A tile that sizes itself has nothing to grow into.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(s(NotchSpace.base))
        .background(NotchPaintedFill(tint: quotaColor(percent), lit: false,
                                     cornerRadius: radius))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// The bar on its own, for cards that lay their own figure beside it.
    private func meterBar(percent: Int, tint: Color) -> some View {
        MeterBar(percent: percent, tint: tint, thickness: s(NotchSpace.bar), reduceMotion: reduceMotion)
    }

    /// A meter's bar. Only the level moves when `percent` changes — the tile's
    /// own `notchReveal` owns arrival. A separate `onAppear` width ramp here
    /// was the Claude/Cursor glitch: two meters in an `HStack` kept resetting
    /// `@State` and replaying the fill while the deck's layout animation was
    /// still resizing their `GeometryReader` columns.
    private struct MeterBar: View {
        let percent: Int
        let tint: Color
        let thickness: CGFloat
        let reduceMotion: Bool

        private var fraction: CGFloat {
            CGFloat(min(100, max(0, percent))) / 100
        }

        var body: some View {
            Capsule()
                .fill(.white.opacity(NotchOpacity.highlight))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(tint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .scaleEffect(x: fraction, y: 1, anchor: .leading)
                }
                .frame(height: thickness)
                .animation(NotchMotion.paint(reduceMotion: reduceMotion), value: percent)
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
                    // Expanded swipes navigate pages. Track changes remain on
                    // the visible transport buttons; compact media keeps its
                    // own track-swipe shortcut.
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
            case .agents(let tray):
                VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
                    NotchCardHeading(title: "Agents", symbol: "terminal", count: tray.sessions.count,
                                     scale: readability, textScale: textScale)
                    agentsCard(tray)
                }
            case .commands(let commands):
                commandsCard(commands)
            case .openCodeUsage(let usage):
                openCodeUsageCard(usage)
            case .codexQuota(let quota):
                usageFit { codexQuotaCard(quota) }
            case .claudeQuota(let quota):
                usageFit { claudeQuotaCard(quota) }
            case .cursorQuota(let quota):
                usageFit { cursorQuotaCard(quota) }
            case .ci(let runs):
                VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
                    NotchCardHeading(title: "Repository checks", symbol: "checkmark.seal", count: runs.count,
                                     scale: readability, textScale: textScale)
                    ciCard(runs)
                }
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
            maxHeight: expandToFill ? .infinity : nil,
            alignment: .topLeading
        )
        .layoutPriority(expandToFill ? 1 : 0)
        .clipped()
    }

    /// Keep every usage detail on the selected canvas. The ideal-height
    /// summary scales as one object only when its content exceeds the body.
    private func usageFit<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        UsageCardFit { content() }
    }

    /// Sessions list in the Fetch glance style: vendor groups, a status light,
    /// what the agent is doing, and an elapsed clock. Tiles used to pack the
    /// same facts into painted cards; the list is the thing you scan.
    private func agentsCard(_ tray: AgentHomeTray) -> some View {
        let groups = Self.sessionGroups(tray.sessions)
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
                ForEach(Array(groups.enumerated()), id: \.element.title) { groupIndex, group in
                    VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                        Text(group.title)
                            .font(font(size: NotchType.caption, weight: .semibold))
                            .monospacedDigit()
                            .tracking(0.6)
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        ForEach(Array(group.sessions.enumerated()), id: \.element.id) { rowIndex, session in
                            agentSessionRow(session)
                                .notchReveal(groupIndex + rowIndex,
                                             scale: readability,
                                             reduceMotion: reduceMotion)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private struct SessionGroup: Equatable {
        let vendorName: String
        let sessions: [AgentSession]
        var title: String {
            let count = sessions.count
            let noun = count == 1 ? "session" : "sessions"
            return "\(vendorName) — \(count) \(noun)"
        }
    }

    private static func sessionGroups(_ sessions: [AgentSession]) -> [SessionGroup] {
        let ordered = sessions.sorted { lhs, rhs in
            if lhs.sessionsGroupOrder != rhs.sessionsGroupOrder {
                return lhs.sessionsGroupOrder < rhs.sessionsGroupOrder
            }
            return lhs.lastActivity > rhs.lastActivity
        }
        var groups: [SessionGroup] = []
        for session in ordered {
            let vendor = session.vendorDisplayName
            if let last = groups.last, last.vendorName == vendor {
                groups[groups.count - 1] = SessionGroup(
                    vendorName: last.vendorName, sessions: last.sessions + [session])
            } else {
                groups.append(SessionGroup(vendorName: vendor,
                                           sessions: [session]))
            }
        }
        return groups
    }

    /// One session as a Fetch-style row: light · identity · activity · clock.
    private func agentSessionRow(_ session: AgentSession) -> some View {
        let light = glanceLight(for: session.state)
        return Button {
            actions.focusAgentSession(session)
        } label: {
            HStack(spacing: s(NotchSpace.snug)) {
                Circle()
                    .fill(light)
                    .frame(width: s(NotchSpace.bar), height: s(NotchSpace.bar))
                    .shadow(color: light.opacity(0.25), radius: reduceMotion ? 0 : 2)
                agentMark(session)
                    .frame(width: s(NotchSpace.section), height: s(NotchSpace.section))
                    .background(
                        RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                            .fill(.black.opacity(NotchOpacity.badge))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    Text(session.displayName)
                        .font(font(size: NotchType.body, weight: .semibold))
                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(session.glanceSecondaryText)
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(session.isWaiting
                            ? NotchDesign.devReadyAmber
                            : .white.opacity(NotchOpacity.secondary))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let elapsed = session.glanceElapsedLabel {
                    Text(elapsed)
                        .font(font(size: NotchType.mono, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .fixedSize(horizontal: true, vertical: false)
                        .contentTransition(.numericText())
                }
            }
            .padding(.horizontal, s(NotchSpace.snug))
            .padding(.vertical, s(NotchSpace.snug))
            .background(
                RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                    .fill(.white.opacity(NotchOpacity.hairline))
            )
            .contentShape(RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous))
        }
        .buttonStyle(NotchObjectButtonStyle(cornerRadius: s(NotchRadius.well),
                                            reduceMotion: reduceMotion))
        .accessibilityLabel("\(session.displayName), \(session.glanceActivityLabel)")
        .animation(NotchMotion.settle(reduceMotion: reduceMotion),
                   value: session.glanceActivityLabel)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.state)
        .notchBump(on: session.state.name, reduceMotion: reduceMotion)
    }

    /// A cool working light leaves amber for attention and red for failure.
    private func glanceLight(for state: AgentSession.State) -> Color {
        switch state {
        case .working: return NotchDesign.accent
        case .waiting: return NotchDesign.devReadyAmber
        case .idle: return NotchDesign.devReadyGreen
        case .completed: return .white.opacity(0.35)
        }
    }

    /// A local total, intentionally not an account quota or reset estimate.
    private func openCodeUsageCard(_ usage: OpenCodeUsage) -> some View {
        let radius = s(NotchRadius.tile)
        return VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            quotaProviderHeader("OpenCode", symbol: "curlybraces")
            Text(usage.tokenLabel)
                .font(font(size: NotchType.hero, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(NotchOpacity.primary))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(usage.costLabel + " local · today")
                .font(font(size: NotchType.caption, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        // Same reason as `meterTile`: content-sized, not card-sized.
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(s(NotchSpace.base))
        .background(NotchPaintedFill(tint: .white.opacity(0.16), lit: false, cornerRadius: radius))
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
    }

    /// Codex meters session and week side by side when the API reports both
    /// windows — the same layout as Claude Code beside it.
    private func codexQuotaCard(_ quota: CodexQuota) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            quotaProviderHeader(
                "Codex",
                bundleIds: ["com.openai.codex", "com.openai.chat"],
                symbol: "chevron.left.forwardslash.chevron.right",
                updatedAt: quota.updatedAt)
            if let weekly = quota.weeklyPercent {
                HStack(spacing: s(NotchSpace.snug)) {
                    meterTile(percent: quota.usedPercent, label: "session",
                              footnote: ClaudeQuota.resetClock(for: quota.resetsAt))
                        .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
                    meterTile(percent: weekly, label: "week",
                              footnote: ClaudeQuota.resetClock(for: quota.weeklyResetsAt))
                        .notchReveal(1, scale: readability, reduceMotion: reduceMotion)
                }
                .geometryGroup()
            } else {
                meterTile(percent: quota.usedPercent, label: quota.resetLabel,
                          footnote: quota.updatedLabel)
                    .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
            }
            if let credits = quota.creditsLabel {
                Text(credits)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
            }
            tokenLines(TokenUsageSummary.codex, tokenUsage, period: tokenPeriod)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                HStack(spacing: s(NotchSpace.snug)) {
                    Text(Self.compactTokens(usage.total(for: tool)))
                        .font(font(size: NotchType.body, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                    Text("tokens · \(period.shortLabel)")
                        .font(font(size: NotchType.caption))
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .lineLimit(1)
                }
                // Cached context is most of the traffic on a long session and
                // a fraction of the cost. Beside the total it is context;
                // inside it, it would be the only number you ever saw.
                if usage.cached(for: tool) > 0 {
                    Text("+\(Self.compactTokens(usage.cached(for: tool))) cached")
                        .font(font(size: NotchType.caption))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .lineLimit(1)
                }
                ForEach(usage.models(for: tool).prefix(usage.modelRows(for: tool)), id: \.model) { entry in
                    HStack(spacing: s(NotchSpace.snug)) {
                        Text(Self.shortModel(entry.model))
                            .font(font(size: NotchType.caption))
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Text(Self.compactTokens(entry.tokens))
                            .font(font(size: NotchType.caption))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }
            .padding(.top, s(NotchSpace.tight))
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
            quotaProviderHeader(
                "Claude Code",
                bundleIds: ["com.anthropic.claudefordesktop", "com.anthropic.claude"],
                symbol: "asterisk",
                mark: "ClaudeMark",
                updatedAt: quota.updatedAt)
            HStack(spacing: s(NotchSpace.snug)) {
                meterTile(percent: quota.sessionPercent, label: "session",
                          footnote: ClaudeQuota.resetClock(for: quota.sessionResetsAt))
                    .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
                meterTile(percent: quota.weeklyPercent, label: "week",
                          footnote: ClaudeQuota.resetClock(for: quota.weeklyResetsAt))
                    .notchReveal(1, scale: readability, reduceMotion: reduceMotion)
            }
            .geometryGroup()
            if let extra = quota.extraSpendLabel {
                Text("extra " + extra)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
            }
            tokenLines(TokenUsageSummary.claude, tokenUsage, period: tokenPeriod)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Cursor's included usage for the billing cycle.
    ///
    /// One meter, not two: Cursor meters a single pool per cycle rather than
    /// Claude's session/week pair. The raw counts sit under the bar because the
    /// percentage alone cannot distinguish "100% of 500" from "100% of 9201".
    private func cursorQuotaCard(_ quota: CursorQuota) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            quotaProviderHeader(
                "Cursor",
                bundleIds: ["com.todesktop.230313mzl4w4u92"],
                symbol: "cursorarrow",
                updatedAt: quota.updatedAt)
            if quota.isUnlimited {
                let radius = s(NotchRadius.tile)
                VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                    Text("unlimited")
                        .font(font(size: NotchType.hero, weight: .semibold))
                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(quota.membershipLabel ?? "Cursor")
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .lineLimit(1)
                }
                // Same reason as `meterTile`: content-sized, not card-sized.
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(s(NotchSpace.base))
                .background(NotchPaintedFill(tint: NotchDesign.devReadyGreen.opacity(0.8),
                                             lit: false, cornerRadius: radius))
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
            } else if let auto = quota.autoPercentUsed, let api = quota.apiPercentUsed,
                      auto > 0 || api > 0 {
                HStack(spacing: s(NotchSpace.snug)) {
                    meterTile(percent: auto, label: "auto")
                        .notchReveal(0, scale: readability, reduceMotion: reduceMotion)
                    meterTile(percent: api, label: "API")
                        .notchReveal(1, scale: readability, reduceMotion: reduceMotion)
                }
                .geometryGroup()
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
                .minimumScaleFactor(0.75)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// A live shell.
    ///
    /// The card takes the keyboard only when clicked, and gives it back on
    /// Escape or when the pill loses key. Anything else and the pill would
    /// swallow every keystroke on the machine the moment it opened.
    private func terminalCard(_ snapshot: TerminalSnapshot) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Terminal", symbol: "terminal",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                if let status = snapshot.exitStatus {
                    Text("Exited \(status)")
                        .font(font(size: NotchType.caption, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    Button { TerminalStore.shared.restart() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(font(size: NotchType.body, weight: .semibold))
                            .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                            .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                            .background(Circle().fill(.white.opacity(NotchOpacity.wellFill)))
                    }
                    .buttonStyle(.plain)
                    .help("Start a new shell")
                } else {
                    Circle()
                        .fill(snapshot.isFocused ? NotchDesign.devReadyGreen
                              : Color.white.opacity(NotchOpacity.tertiary))
                        .frame(width: s(6), height: s(6))
                    Text(snapshot.isFocused ? "Typing · Esc to release" : "Click to type")
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                }
            }

            ZStack(alignment: .topLeading) {
                TerminalGridView(isFocused: snapshot.isFocused,
                                 fontSize: s(9), lineHeight: s(11))
                    .opacity(snapshot.exitStatus == nil ? 1 : 0.45)
                if let status = snapshot.exitStatus {
                    Text("Shell exited (\(status))")
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .padding(.horizontal, s(NotchSpace.snug))
                        .background(Capsule().fill(.black.opacity(0.8)))
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(s(NotchSpace.base))
            .background(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                .fill(.white.opacity(NotchOpacity.wellFill)))
            .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                .stroke(.white.opacity(snapshot.isFocused ? NotchOpacity.rim : NotchOpacity.hairline),
                        lineWidth: 0.5))
            .contentShape(Rectangle())
            .onTapGesture {
                if snapshot.isFocused {
                    closeTerminalFocus()
                } else {
                    TerminalStore.shared.setFocused(true)
                    actions.captureKeyboard(true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func closeTerminalFocus() {
        TerminalStore.shared.setFocused(false)
        actions.captureKeyboard(false)
    }

    private func clipboardCard(_ items: [ClipboardEntry], searching: Bool) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            HStack(spacing: s(NotchSpace.base)) {
                NotchCardHeading(title: "Clipboard", symbol: "doc.on.clipboard", count: items.count,
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
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
                        .font(.system(size: textSize(NotchType.body), weight: .medium))
                        .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                }
                .buttonStyle(NotchChromeButtonStyle(selected: searching, reduceMotion: reduceMotion))
                .accessibilityLabel(searching ? "Close search" : "Search remembered copies")
                .help(searching ? "Close search" : "Search remembered copies")

                if !items.isEmpty {
                    Button { ClipboardStore.shared.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: textSize(NotchType.body), weight: .medium))
                            .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                    }
                    .buttonStyle(NotchChromeButtonStyle(reduceMotion: reduceMotion))
                    .accessibilityLabel("Forget every unpinned copy")
                    .help("Forget every unpinned copy")
                }
            }

            if searching {
                clipboardSearchField
            }

            if items.isEmpty {
                NotchEmptyState(symbol: searching ? "magnifyingglass" : "doc.on.clipboard",
                                title: searching ? "No matching copies" : "Ready when you copy",
                                detail: searching ? "Try another word or return to your copies." : "Copy text anywhere to keep it here.",
                                actionTitle: searching ? "Show all copies" : nil,
                                action: closeClipboardSearch,
                                scale: readability, textScale: textScale, reduceMotion: reduceMotion)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                        ForEach(items) { entry in
                          // The pin is a sibling of the copy button, not a control
                          // inside its label: a button nested in another button's
                          // label swallows its own taps.
                          HStack(alignment: .center, spacing: s(NotchSpace.snug)) {
                            clipboardPinButton(entry)
                            Button { ClipboardStore.shared.copyBack(entry) } label: {
                                HStack(alignment: .top, spacing: s(NotchSpace.snug)) {
                                    clipboardMark(entry)
                                    Text(entry.preview)
                                        .font(font(size: NotchType.body))
                                        .foregroundStyle(.white.opacity(NotchOpacity.primary))
                                        .lineLimit(entry.displayLines)
                                        .multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(relativeStart(for: entry.copiedAt))
                                        .font(font(size: NotchType.caption))
                                        .monospacedDigit()
                                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                                        .fixedSize()
                                }
                                .padding(.horizontal, s(NotchSpace.base))
                                .padding(.vertical, s(NotchSpace.snug))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                                        .fill(Color.white.opacity(entry.isPinned ? NotchOpacity.highlight : NotchOpacity.wellFill))
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(NotchObjectButtonStyle(cornerRadius: s(NotchRadius.card),
                                                                reduceMotion: reduceMotion))
                            .help("Copy again")
                          }
                          .onHover { hoveredClipboardPin = $0 ? entry.id : nil }
                        }
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
        HStack(spacing: s(NotchSpace.snug)) {
            Image(systemName: "magnifyingglass")
                .font(font(size: NotchType.caption))
                .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
            TextField("Search copies", text: Binding(
                get: { ClipboardStore.shared.query },
                set: { ClipboardStore.shared.query = $0 }
            ))
            .textFieldStyle(.plain)
            .font(font(size: NotchType.body))
            .foregroundStyle(.white.opacity(NotchOpacity.primary))
            .focused($clipboardSearchFocused)
            .onSubmit { closeClipboardSearch() }
            .onExitCommand { closeClipboardSearch() }
        }
        .padding(.horizontal, s(NotchSpace.base))
        .padding(.vertical, s(NotchSpace.snug))
        .background(
            RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
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
                .font(.system(size: textSize(NotchType.body)))
                .rotationEffect(.degrees(45))
                .foregroundStyle(.white.opacity(
                    entry.isPinned ? NotchOpacity.primary
                    : (hoveredClipboardPin == entry.id ? NotchOpacity.secondary : 0)
                ))
                .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(atLimit)
        .accessibilityLabel(entry.isPinned ? "Unpin copy" : "Pin copy")
        .help(entry.isPinned
              ? "Unpin — it goes back to being forgotten in turn"
              : (atLimit
                 ? "\(ClipboardStore.pinCapacity) pins is the limit; unpin one first"
                 : "Pin — kept until you unpin it"))
    }

    /// Recent local builds and tests. The header stays neutral; each row's
    /// small status mark carries its own semantic colour.
    private func commandsCard(_ commands: [DevCommand]) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Builds & tests", symbol: "hammer.fill",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Text("\(commands.count) recent")
                    .font(font(size: NotchType.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .fixedSize(horizontal: true, vertical: false)
            }
            if commands.isEmpty {
                NotchEmptyState(symbol: "hammer", title: "Ready for your next build",
                                detail: "Set up the CLI to follow builds and tests here.",
                                actionTitle: "Open Settings", action: actions.openSettings,
                                scale: readability, textScale: textScale, reduceMotion: reduceMotion)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: s(NotchSpace.tight)) {
                        ForEach(commands) { command in
                            commandRow(command)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func commandRow(_ command: DevCommand) -> some View {
        let tint: Color = command.state == .failed ? .red
            : command.state == .passed ? NotchDesign.devReadyGreen
            : command.state == .waiting ? NotchDesign.devReadyAmber : NotchDesign.accent
        let icon = command.state == .failed ? "xmark.circle.fill"
            : command.state == .passed ? "checkmark.circle.fill"
            : command.state == .waiting ? "hand.raised.fill" : "hammer.fill"
        return HStack(spacing: s(NotchSpace.snug)) {
            Image(systemName: icon)
                .font(font(size: NotchType.caption, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: s(NotchSpace.mark))
            VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                Text(command.displayTitle)
                    .font(font(size: NotchType.body, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: s(NotchSpace.tight)) {
                    if let detail = command.displayDetail ?? command.displayProject {
                        Text(detail)
                            .lineLimit(1)
                    }
                    Text(commandStatus(command))
                    if command.state.isActive {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Self.commandDuration(max(0, context.date.timeIntervalSince(command.startedAt))))
                                .monospacedDigit()
                        }
                    } else {
                        Text(Self.commandDuration(max(0, (command.endedAt ?? command.updatedAt)
                            .timeIntervalSince(command.startedAt))))
                            .monospacedDigit()
                    }
                }
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .lineLimit(1)
            }
            Spacer(minLength: 0)
            if command.terminalTTY != nil {
                Button {
                    unavailableCommandTargets.remove(command.id)
                    actions.focusDevCommand(command) { focused in
                        if !focused { unavailableCommandTargets.insert(command.id) }
                    }
                } label: {
                    Image(systemName: "scope")
                        .font(font(size: NotchType.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .help("Jump to the exact terminal tab or pane")
                .accessibilityLabel("Jump to terminal for \(command.displayTitle)")
            }
            if let bundleId = command.bundleId,
               unavailableCommandTargets.contains(command.id)
                || NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) {
                Button { actions.focusApp(bundleId) } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(font(size: NotchType.caption, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .help(unavailableCommandTargets.contains(command.id)
                      ? "Open the terminal app instead"
                      : "Open the terminal app")
                .accessibilityLabel("Open terminal app for \(command.displayTitle)")
            }
            Button { actions.dismissDevCommand(command.id) } label: {
                Image(systemName: "xmark")
                    .font(font(size: NotchType.caption, weight: .semibold))
                    .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
            .help("Dismiss this activity")
            .accessibilityLabel("Dismiss \(command.displayTitle)")
        }
        .overlay(alignment: .bottomLeading) {
            if unavailableCommandTargets.contains(command.id) {
                Text("Exact target unavailable · use terminal app button")
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(NotchDesign.devReadyAmber)
                    .lineLimit(1)
                    .offset(y: s(NotchSpace.base))
            }
        }
        .padding(s(NotchSpace.snug))
        .background(NotchPaintedFill(tint: tint, lit: false, cornerRadius: s(NotchRadius.tile)))
        .clipShape(RoundedRectangle(cornerRadius: s(NotchRadius.tile), style: .continuous))
    }

    private static func commandDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        if seconds >= 3600 { return "\(seconds / 3600)h \((seconds % 3600) / 60)m" }
        if seconds >= 60 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds)s"
    }

    private func commandStatus(_ command: DevCommand) -> String {
        guard command.state == .failed else { return command.state.label }
        if let exitCode = command.exitCode { return "Failed · exit \(exitCode)" }
        return "Failed · exit unknown"
    }

    private func ciCard(_ runs: [CIRun]) -> some View {
        GeometryReader { geo in
            let gap = s(NotchSpace.base)
            let count = max(1, runs.count)
            let columns = min(count, geo.size.width >= s(NotchSpace.tile) ? 2 : 1)
            let tileW = max(s(NotchSpace.hero + NotchSpace.section),
                            (geo.size.width - gap * CGFloat(max(0, columns - 1)))
                                / CGFloat(columns))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: gap) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { index, run in
                        ciTile(run, width: tileW, height: geo.size.height)
                            .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                            .notchBump(on: run.state, reduceMotion: reduceMotion)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .clipped()
    }

    private func ciTile(_ run: CIRun, width: CGFloat, height: CGFloat) -> some View {
        let radius = s(NotchRadius.tile)
        return Button { actions.openURL(run.id) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: s(NotchSpace.snug)) {
                    Image(systemName: symbol(for: run.state))
                        .font(font(size: NotchType.body, weight: .bold))
                        .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                        .background(
                            RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                                .fill(.black.opacity(NotchOpacity.badge))
                        )
                        .accessibilityHidden(true)
                    Text(run.statusLabel)
                        .font(font(size: NotchType.caption, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .foregroundStyle(color(for: run.state))
                Spacer(minLength: s(NotchSpace.snug))
                Text(run.repoName)
                    .font(font(size: NotchType.display, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.primary))
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .truncationMode(.tail)
                Text(run.workflow)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.top, s(NotchSpace.tight))
            }
            .padding(s(NotchSpace.base))
            .frame(width: width, height: height, alignment: .topLeading)
            .background(NotchPaintedFill(tint: color(for: run.state), lit: false,
                                         cornerRadius: radius))
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .buttonStyle(NotchObjectButtonStyle(cornerRadius: radius, reduceMotion: reduceMotion))
        .accessibilityLabel("\(run.repoName), \(run.workflow), \(run.statusLabel)")
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

    /// Recent agent activity retains the black notification surface. A small
    /// status dot carries the state while the title and context get separate
    /// lines, so one long subtitle cannot swallow the actual alert.
    private func recentAlertsCard(_ alerts: [DevReadyAlert]) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Recent activity", symbol: "bell", count: alerts.count,
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Button { actions.clearRecentActivity() } label: {
                    Text("Clear")
                        .font(font(size: NotchType.caption, weight: .medium))
                        .padding(.horizontal, s(NotchSpace.base))
                        .padding(.vertical, s(NotchSpace.snug))
                }
                .buttonStyle(NotchChromeButtonStyle(reduceMotion: reduceMotion))
                .disabled(alerts.isEmpty)
                .accessibilityLabel("Clear recent activity")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                    ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                        alertRow(alert)
                            .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                    }
                }
            }
            .frame(maxHeight: s(122))
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func alertRow(_ alert: DevReadyAlert) -> some View {
        let waiting = alert.kind == .waiting
        return Button { actions.focusAlert(alert) } label: {
            HStack(alignment: .top, spacing: s(NotchSpace.base)) {
                Circle()
                    .fill(waiting ? NotchDesign.devReadyAmber : NotchDesign.devReadyGreen)
                    .frame(width: s(8), height: s(8))
                    .frame(width: s(NotchSpace.mark), height: s(NotchSpace.mark))
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    Text(alert.displayTitle)
                        .font(font(size: NotchType.body, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(alert.displaySubtitle.flatMap { $0.isEmpty ? nil : $0 }
                         ?? (waiting ? "Needs you" : "Finished"))
                        .font(font(size: NotchType.caption, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(alert.shortAgeText())
                    .font(font(size: NotchType.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, s(NotchSpace.base))
            .padding(.vertical, s(NotchSpace.snug))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                .fill(.white.opacity(NotchOpacity.wellFill)))
            .contentShape(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous))
        }
        .buttonStyle(NotchObjectButtonStyle(cornerRadius: s(NotchRadius.card), reduceMotion: reduceMotion))
    }

    /// Red is reserved for a failure — the only state that wants you to stop
    /// what you are doing.
    private func color(for state: CIRun.State) -> Color {
        switch state {
        case .failed: return .red
        case .running: return NotchDesign.devReadyAmber
        case .passed: return NotchDesign.devReadyGreen
        case .other: return .white.opacity(0.4)
        }
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

    /// The island body for Now Playing. Its artwork wash is painted by the
    /// enclosing deck; content stays inset from the silhouette and page dots.
    private func mediaCard(_ np: NowPlaying) -> some View {
        GeometryReader { geo in
            let inset = s(NotchSpace.base)
            let chrome = max(0, bottomChromeHeight)
            let progressH: CGFloat = np.hasProgress ? s(22) : 0
            let gap = s(NotchSpace.snug)
            let usableH = max(s(NotchSpace.hero),
                              geo.size.height - inset * 2 - chrome - progressH
                                - (np.hasProgress ? gap : 0))
            // Grow the cover with the island: at least hero, at most half the
            // width or the usable row height — whichever is smaller.
            let art = min(max(s(NotchSpace.hero), usableH),
                          geo.size.width * 0.42)

            VStack(alignment: .leading, spacing: gap) {
                HStack(alignment: .center, spacing: s(NotchSpace.base)) {
                    mediaArtwork(np, size: art)
                    VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                        Text(np.title)
                            .font(font(size: NotchType.display, weight: .semibold))
                            .foregroundStyle(.white.opacity(NotchOpacity.primary))
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .truncationMode(.tail)
                        Text(np.artist)
                            .font(font(size: NotchType.body, weight: .medium))
                            .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        HStack(spacing: s(NotchSpace.snug)) {
                            transportButton("backward.fill", label: "Previous track",
                                            action: actions.previous)
                            transportButton(np.isPlaying ? "pause.fill" : "play.fill",
                                            label: np.isPlaying ? "Pause" : "Play",
                                            size: 17, prominent: true, morphing: true,
                                            action: actions.togglePlayPause)
                            transportButton("forward.fill", label: "Next track",
                                            action: actions.next)
                            Spacer(minLength: 0)
                            EqualizerSlot(isPlaying: np.isPlaying, scale: readability)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
                .frame(height: art)

                if np.hasProgress {
                    MediaProgressView(nowPlaying: np, style: .expanded,
                                      readability: readability, textScale: textScale)
                }

                Spacer(minLength: 0)
            }
            .padding(inset)
            .padding(.bottom, chrome)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private func mediaArtwork(_ np: NowPlaying, size: CGFloat? = nil) -> some View {
        let side = size ?? s(NotchSpace.hero)
        let radius = min(s(NotchRadius.tile), side * 0.22)
        return Group {
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
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        // A cover is a printed object; the hairline is its edge, as on a tile.
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
            .stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: s(NotchSpace.base), y: s(NotchSpace.tight))
    }

    /// The app icon carries the colour; the surrounding card stays neutral.
    private func appCard(title: String, name: String) -> some View {
        HStack(spacing: s(NotchSpace.base)) {
            Group {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "app.fill")
                        .font(font(size: NotchType.display))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(NotchOpacity.wellFill))
                }
            }
            .frame(width: s(56), height: s(56))
            .clipShape(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                .stroke(.white.opacity(NotchOpacity.rim), lineWidth: 0.5))
            VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                Text(title)
                    .font(font(size: NotchType.caption, weight: .semibold))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                Text(name)
                    .font(font(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func volumeCard(_ level: Int) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Volume", symbol: "speaker.wave.2.fill",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Text("\(level)%")
                    .font(font(size: NotchType.hero, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            meterBar(percent: level, tint: .white.opacity(NotchOpacity.primary))
            outputPickerRow
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
                HStack(spacing: s(NotchSpace.snug)) {
                    Image(systemName: current.symbolName)
                        .font(.system(size: textSize(NotchType.body)))
                    Text(current.name)
                        .font(font(size: NotchType.body, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: textSize(NotchType.caption)))
                        .opacity(audioOutput.devices.count > 1 ? 1 : 0)
                }
                .foregroundStyle(.white.opacity(hoveredOutputPicker ? 0.9 : NotchOpacity.secondary))
                .padding(.horizontal, s(NotchSpace.base))
                .padding(.vertical, s(NotchSpace.snug))
                .background(
                    Capsule().fill(Color.white.opacity(hoveredOutputPicker ? NotchOpacity.highlight : NotchOpacity.wellFill))
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
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Calendar", symbol: "calendar",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Text(relativeStart(for: event.start))
                    .font(font(size: NotchType.caption, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
            }
            HStack(alignment: .top, spacing: s(NotchSpace.base)) {
                VStack(spacing: 0) {
                    Text(event.start, format: .dateTime.month(.abbreviated))
                        .font(font(size: NotchType.caption, weight: .semibold))
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    Text("\(Calendar.current.component(.day, from: event.start))")
                        .font(font(size: NotchType.display, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                }
                .frame(width: s(46), height: s(46))
                .background(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .fill(.white.opacity(NotchOpacity.wellFill)))
                VStack(alignment: .leading, spacing: s(NotchSpace.tight)) {
                    Text(event.title)
                        .font(font(size: NotchType.display, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                    Text(event.isAllDay ? "All day" :
                         DateFormatter.localizedString(from: event.start, dateStyle: .none, timeStyle: .short))
                        .font(font(size: NotchType.body))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    if let location = event.location, !location.isEmpty {
                        Text(location)
                            .font(font(size: NotchType.caption))
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func timerCard(_ timer: ActiveTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                HStack(spacing: s(NotchSpace.snug)) {
                    NotchCardHeading(title: timer.isFocusSession ? "Focus session" : timer.label,
                                     symbol: timer.isFocusSession ? "moon.stars" : "timer",
                                     scale: readability, textScale: textScale)
                    Spacer(minLength: 0)
                    Button(timer.isFocusSession ? "End focus" : "Cancel", action: onCancelTimer)
                        .font(font(size: NotchType.caption, weight: .medium))
                        .buttonStyle(.plain)
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .padding(.horizontal, s(NotchSpace.base))
                        .padding(.vertical, s(NotchSpace.snug))
                        .background(Capsule().fill(.white.opacity(NotchOpacity.wellFill)))
                }
                Text(StatusFormatting.countdown(timer.remaining(at: context.date)))
                    .font(font(size: NotchType.hero, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                Text("Ends at \(DateFormatter.localizedString(from: timer.endDate, dateStyle: .none, timeStyle: .short))")
                    .font(font(size: NotchType.caption))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// Two meters, tinted by how full each is. Two percentages in a column
    /// read identically at 23% and 93%; a bar does not.
    private func systemStatsCard(_ stats: SystemStats) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "System", symbol: "cpu",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Text("Live usage")
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
            }
            HStack(spacing: s(NotchSpace.base)) {
                meterTile(percent: stats.cpuPercent, label: "CPU")
                meterTile(percent: stats.memoryPercent, label: "Memory")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Green while there is plenty, amber as it runs down — the battery's own
    /// colour rule, read off the remaining charge rather than the used share
    /// the quota cards meter.
    private func batteryCard(_ status: BatteryStatus) -> some View {
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "Battery", symbol: "battery.100percent",
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                Text("\(status.level)%")
                    .font(font(size: NotchType.hero, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
            }
            meterBar(percent: status.level,
                     tint: status.isCharging ? NotchDesign.devReadyGreen : quotaColor(100 - status.level))
            HStack(spacing: s(NotchSpace.base)) {
                Text(status.isCharging ? "Charging" : "On battery")
                    .font(font(size: NotchType.body, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                Spacer(minLength: 0)
                lowPowerRow(status)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
            HStack(spacing: s(NotchSpace.snug)) {
                Image(systemName: status.isLowPower
                      ? "battery.25percent.bolt.slash" : "leaf")
                    .font(.system(size: textSize(NotchType.body)))
                Text(status.isLowPower ? "Low Power on" : "Low Power off")
                    .font(font(size: NotchType.body, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(status.isLowPower
                             ? Color.yellow.opacity(hoveredLowPower ? 1 : NotchOpacity.secondary)
                             : .white.opacity(hoveredLowPower ? 0.9 : NotchOpacity.secondary))
            .padding(.horizontal, s(NotchSpace.base))
            .padding(.vertical, s(NotchSpace.snug))
            .background(
                Capsule().fill(Color.white.opacity(hoveredLowPower ? NotchOpacity.highlight : NotchOpacity.wellFill))
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
        VStack(alignment: .leading, spacing: s(NotchSpace.base)) {
            HStack(spacing: s(NotchSpace.snug)) {
                NotchCardHeading(title: "File shelf", symbol: "folder.fill", count: items.count,
                                 scale: readability, textScale: textScale)
                Spacer(minLength: 0)
                if !items.isEmpty {
                    ShareLink(items: items.map(\.url)) {
                        Image(systemName: "square.and.arrow.up")
                            .font(font(size: NotchType.body, weight: .medium))
                            .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .help("Share shelf files")
                    Button { items.forEach { actions.removeShelfItem($0.id) } } label: {
                        Image(systemName: "trash")
                            .font(font(size: NotchType.body, weight: .medium))
                            .frame(width: s(NotchSpace.well), height: s(NotchSpace.well))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    .help("Remove all shelf files")
                }
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(font(size: NotchType.body, weight: .medium))
                    .foregroundStyle(NotchDesign.devReadyAmber)
                    .lineLimit(1)
            } else if let receipt {
                HStack(spacing: s(NotchSpace.snug)) {
                    Label("Moved to \(receipt.destinationName)", systemImage: "checkmark.circle.fill")
                        .font(font(size: NotchType.body, weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Button("Undo") { actions.undoShelfFiling() }
                        .font(font(size: NotchType.body, weight: .semibold))
                        .buttonStyle(.plain)
                    if !destinations.pinned.contains(receipt.token.to.deletingLastPathComponent()) {
                        Button("Pin folder") {
                            destinations.pin(receipt.token.to.deletingLastPathComponent())
                        }
                        .font(font(size: NotchType.body, weight: .medium))
                        .buttonStyle(.plain)
                    }
                }
                .foregroundStyle(.white)
            }

            // Files already on the shelf always win the space. The drop zone
            // only stands in when there is nothing else to show — a targeting
            // flag that failed to clear must never be able to hide the chips,
            // which are the only route to the destination menu.
            if !items.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(NotchSpace.base)) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            shelfChip(item)
                                .notchReveal(index, scale: readability, reduceMotion: reduceMotion)
                        }
                    }
                    // Leave room for the folder badge outside the final chip.
                    .padding(.trailing, s(NotchSpace.roomy))
                    .padding(.bottom, s(NotchSpace.base))
                }
                .frame(height: s(68), alignment: .top)
                .overlay(
                    RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                        .strokeBorder(NotchDesign.accent,
                                      lineWidth: isDropTargeted ? 1.4 : 0)
                )
            } else {
                VStack(spacing: s(NotchSpace.snug)) {
                    Image(systemName: "arrow.down.doc")
                        .font(font(size: NotchType.display))
                    Text(isDropTargeted ? "Drop to add" : "Drop files here")
                        .font(font(size: NotchType.body, weight: .semibold))
                    if !isDropTargeted {
                        Text("Move or share them later")
                            .font(font(size: NotchType.caption))
                            .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                    }
                }
                .foregroundStyle(.white.opacity(isDropTargeted ? 1 : NotchOpacity.secondary))
                .frame(maxWidth: .infinity)
                .frame(height: s(68))
                .background(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .fill(isDropTargeted ? NotchDesign.accent.opacity(0.15)
                         : Color.white.opacity(NotchOpacity.wellFill)))
                .overlay(RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .strokeBorder(isDropTargeted ? NotchDesign.accent
                                  : Color.white.opacity(NotchOpacity.hairline), lineWidth: 1))
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The file itself when Quick Look can draw it — the screenshot, the
    /// PDF's first page — and its type icon until then or otherwise. The
    /// thumbnail sits on the type icon's footprint so the chip does not
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
                .frame(width: s(32), height: s(32))
                .onAppear {
                    thumbnails.request(item.url, size: CGSize(width: s(40), height: s(32)))
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
            VStack(spacing: s(NotchSpace.snug)) {
                shelfPreview(item)
                    .frame(width: s(40), height: s(32))
                Text(item.name)
                    .font(font(size: NotchType.caption, weight: .medium))
                    .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: s(76))
            }
            .frame(width: s(88), height: s(60))
            // The hover lift is the shared style's now; `hoveredShelfItem`
            // still drives the remove button.
            .background(
                RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .fill(Color.white.opacity(NotchOpacity.wellFill))
            )
            .overlay(
                RoundedRectangle(cornerRadius: s(NotchRadius.card), style: .continuous)
                    .stroke(.white.opacity(NotchOpacity.hairline), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchObjectButtonStyle(cornerRadius: s(NotchRadius.card), reduceMotion: reduceMotion))
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

    private func relativeStart(for date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// `morphing` is for play/pause only. SF Symbols can cross-dissolve one
    /// glyph into the other in place, which is what a pause should look like —
    /// a button changing its mind, not the card rearranging itself.
    private func transportButton(_ symbol: String, label: String,
                                 size: CGFloat = 16, prominent: Bool = false,
                                 morphing: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: s(size), weight: .semibold))
                .foregroundStyle(prominent ? .black : .white.opacity(NotchOpacity.secondary))
                .modifier(SymbolMorph(enabled: morphing, symbol: symbol))
                .frame(width: s(prominent ? 36 : 32), height: s(36))
                .background {
                    if prominent {
                        Circle().fill(.white.opacity(0.94))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(TransportButtonStyle())
        .accessibilityLabel(label)
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

private struct TransportButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Measures the complete summary at the available width, then fits it into
/// the card without a scroll view or independent clipping of its detail rows.
struct UsageCardFit<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var idealHeight: CGFloat = 0

    static func fitScale(idealHeight: CGFloat, availableHeight: CGFloat) -> CGFloat {
        guard idealHeight > 0 else { return 1 }
        return min(1, max(0, availableHeight) / idealHeight)
    }

    var body: some View {
        GeometryReader { canvas in
            let fit = Self.fitScale(idealHeight: idealHeight, availableHeight: canvas.size.height)
            content
                .frame(width: canvas.size.width / max(0.01, fit), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { idealHeight = $0 }
                .scaleEffect(fit, anchor: .topLeading)
                .frame(width: canvas.size.width, height: canvas.size.height, alignment: .topLeading)
        }
    }
}
