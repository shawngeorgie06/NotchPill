import CoreGraphics

/// Render metrics for the notch pill — size and readability scale derived from
/// how many chips/cards are actually visible.
struct NotchContentLayoutMetrics {
    var size: CGSize
    /// Scales spacing, icons, and pill chrome.
    var readability: CGFloat
    /// Scales typography — grows faster than `readability` when items are few.
    var textScale: CGFloat
}

/// Computes pill dimensions and readability scaling from visible chips/cards.
///
/// Fewer visible items → larger text/chrome and a tighter pill around them.
/// More visible items → smaller text so everything still fits.
enum NotchContentLayout {
    // MARK: - Collapsed

    static func collapsedLayout(metrics: NotchMetrics, chips: [CollapsedChip]) -> NotchContentLayoutMetrics {
        guard !chips.isEmpty else {
            return NotchContentLayoutMetrics(size: metrics.collapsedSize, readability: 1, textScale: 1)
        }

        let spacing: CGFloat = 8
        let padding: CGFloat = 20
        let maxW = min(metrics.maxExpandedRenderedWidth, metrics.notchWidth + 280)
        let minW = metrics.notchWidth + 16

        let baseWidths = chips.map { collapsedChipBaseWidth($0) }
        let baseRowWidth = baseWidths.reduce(0, +)
            + spacing * CGFloat(max(0, chips.count - 1))
            + padding

        let readability = fitReadability(
            itemCount: chips.count,
            baseRowWidth: baseRowWidth,
            maxWidth: maxW,
            fewItemBoost: (2.1, 1.75, 1.45)
        )
        let rowHeight: CGFloat = 30 * readability
        let width = min(maxW, max(minW, baseRowWidth * readability))
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: metrics.notchHeight + rowHeight),
            readability: readability,
            textScale: textScale(forLayoutScale: readability)
                * textCompensation(forUserScale: metrics.userScale)
        )
    }

    static func collapsedSize(metrics: NotchMetrics, chips: [CollapsedChip]) -> CGSize {
        collapsedLayout(metrics: metrics, chips: chips).size
    }

    // MARK: - Expanded

    static func expandedLayout(metrics: NotchMetrics, activities: [ExpandedActivity]) -> NotchContentLayoutMetrics {
        guard !activities.isEmpty else {
            return NotchContentLayoutMetrics(
                size: CGSize(
                    width: max(metrics.notchWidth, 140),
                    height: metrics.notchHeight + metrics.topGap + 36
                ),
                readability: 1,
                textScale: 1
            )
        }

        let includesMedia = activities.contains(where: { if case .media = $0 { return true }; return false })
        let spacing: CGFloat = 10
        let padding: CGFloat = 28
        let maxW = metrics.maxExpandedRenderedWidth
        let minW = metrics.notchWidth + 20

        let baseWidths = activities.map { expandedCardBaseWidth($0) }
        let baseRowWidth = baseWidths.reduce(0, +)
            + spacing * CGFloat(max(0, activities.count - 1))
            + padding

        let readability = fitReadability(
            itemCount: activities.count,
            baseRowWidth: baseRowWidth,
            maxWidth: maxW,
            fewItemBoost: (2.2, 1.85, 1.5)
        )
        let baseContentHeight = expandedContentBaseHeight(activities)
        let cornerPad: CGFloat = 4
        let contentHeight = baseContentHeight * readability + cornerPad
        let width = min(maxW, max(minW, baseRowWidth * readability))
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: metrics.notchHeight + metrics.topGap + contentHeight),
            readability: readability,
            textScale: textScale(forLayoutScale: readability)
                * textCompensation(forUserScale: metrics.userScale)
        )
    }

    static func expandedSize(metrics: NotchMetrics, activities: [ExpandedActivity]) -> CGSize {
        expandedLayout(metrics: metrics, activities: activities).size
    }

    // MARK: - Dev ready peek

    /// What one peek row actually renders (`DevReadyPeekRow.tapRow`): a ~16pt
    /// title line, 3pt of `VStack` spacing, a ~16pt badge capsule (10pt text plus
    /// 2pt padding each side), and 7pt of vertical padding top and bottom.
    ///
    /// Was 42, which under-budgeted by roughly the padding — invisible while
    /// peeks were one row of a short title, then clipping the bottom row once
    /// several stacked up. A single-alert peek isn't in a ScrollView, so an
    /// under-budgeted row is cut off by the window rather than scrolled to.
    static let devReadyRowHeight: CGFloat = 52
    /// Answer capsule size. Also the minimum *width*, so a one-character label
    /// ("1") is still a square target rather than a sliver. 32 rather than the
    /// old ~24: these are the primary action on a waiting peek and were the
    /// smallest thing on it.
    static let answerButtonHeight: CGFloat = 32
    static let answerButtonSpacing: CGFloat = 8
    /// Width the per-row ✕ occupies: a 28pt target plus its 8pt trailing padding.
    static let dismissControlWidth: CGFloat = 36
    static let devReadyMaxVisibleRows = 3
    /// Wider than collapsed/hover chips so agent names and subtitles fit
    /// comfortably.
    ///
    /// Do not raise this to buy room for new controls: the peek is capped at
    /// `maxExpandedRenderedWidth` (`designExpandedWidth * scale`, ~416pt on real
    /// hardware), so a larger minimum is silently clamped away and only breaks
    /// the invariant that a peek is at least this wide. Controls have to be paid
    /// for out of the title, which truncates — never out of the badges, which
    /// would wrap and push the row past its budgeted height.
    static let devReadyMinWidth: CGFloat = 380

    static func devReadyListHeight(rowCount: Int) -> CGFloat {
        let visible = min(max(1, rowCount), devReadyMaxVisibleRows)
        let dividers = max(0, visible - 1)
        return devReadyRowHeight * CGFloat(visible) + CGFloat(dividers)
    }

    static func devReadyLayout(metrics: NotchMetrics, alerts: [DevReadyAlert]) -> NotchContentLayoutMetrics {
        let count = max(1, alerts.count)
        let headerHeight: CGFloat = count > 1 ? 18 : 0
        let listHeight = devReadyListHeight(rowCount: count)
        let labelLen = CGFloat(alerts.map { ($0.agent ?? $0.source ?? $0.title).count }.max() ?? 16)
        let titleLen = CGFloat(alerts.map(\.title.count).max() ?? 16)
        // Every row carries a ✕ (28pt + 8pt trailing). Without this allowance the
        // control eats title width instead of being given its own, and titles
        // that used to fit start truncating.
        let contentWidth = 300 + dismissControlWidth + max(labelLen, titleLen) * 2.5
        let width = min(
            metrics.maxExpandedRenderedWidth,
            max(metrics.notchWidth + 168, devReadyMinWidth, contentWidth)
        )
        let height = metrics.notchHeight + metrics.topGap + headerHeight + listHeight + 4
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: height),
            readability: 1.05,
            textScale: 1.08
        )
    }

    /// Extra height `.waiting` rows need on top of `devReadyRowHeight`, budgeted
    /// against what `DevReadyPeekRow` actually renders (Tiles.swift). Per row:
    ///
    /// - `6`  — the row's outer `VStack(spacing: 6)` between the tap row and the
    ///          waiting section (the section is always present for `.waiting`).
    /// - `30` — the two-line `.lineLimit(2)` message at 11pt (2 × ~14pt leading
    ///          plus a little slack), when that alert carries one.
    /// - the answer button row: the inner `VStack(spacing: 6)` gap, the capsule
    ///   (`answerButtonHeight`), and the row's `.padding(.bottom, 6)`.
    ///
    /// Under-budgeting here is not cosmetic: a single-alert peek skips the
    /// `ScrollView` and `devReadyContent` pins the list to the window height, so
    /// anything past it draws outside the NSWindow — clipped *and* not
    /// hit-testable, i.e. the answer capsules stop taking clicks.
    ///
    /// The allowance is **per row**, summed over the rows the peek actually shows.
    /// A single flat allowance was enough only while two waiting peeks could not
    /// coexist; once alerts are keyed on `sessionId`, several sessions on one
    /// project stay on screen together, and one allowance stretched across them
    /// left every row after the first without room for its own question line —
    /// its answer buttons rendered under the previous row's text with the
    /// question scrolled out of view, so you could not tell what you were
    /// answering.
    ///
    /// `devReadyLayout` shows at most `devReadyMaxVisibleRows`, so only that many
    /// allowances are budgeted — the **largest** ones, since any row can be
    /// scrolled to and none of them may clip when it is.
    /// - Parameter answerEnabled: overrides `AppSettings.shared.agentReplyEnabled`.
    ///   Tests pass it explicitly so they never read (or write) the developer's
    ///   real UserDefaults. (It is `Bool?` rather than a defaulted `Bool` because
    ///   a default argument is evaluated in a nonisolated context and cannot
    ///   touch the main-actor singleton.)
    @MainActor
    static func waitingExtraHeight(
        alerts: [DevReadyAlert],
        answerEnabled: Bool? = nil
    ) -> CGFloat {
        let enabled = answerEnabled ?? AppSettings.shared.agentReplyEnabled
        return alerts
            .map { waitingRowExtra(for: $0, answerEnabled: enabled) }
            .sorted(by: >)
            .prefix(devReadyMaxVisibleRows)
            .reduce(0, +)
    }

    /// One `.waiting` row's extra height over `devReadyRowHeight`, budgeted
    /// against what that row renders — evaluated per alert, because two waiting
    /// rows can differ (one carries a question, one is stale and so draws no
    /// buttons).
    @MainActor
    private static func waitingRowExtra(
        for alert: DevReadyAlert,
        answerEnabled: Bool
    ) -> CGFloat {
        guard alert.kind == .waiting else { return 0 }
        // Same rule the row draws by — shared rather than mirrored, because
        // when these two drifted the peek reserved space for buttons it never
        // drew.
        let canAnswer = alert.canAnswerFromNotch(replyEnabled: answerEnabled)
        let sectionSpacing: CGFloat = 6
        // A permission request draws its own body — a summary line plus up to
        // four diff lines — in place of the one-line question.
        let messageExtra: CGFloat
        if let request = alert.permissionRequest {
            messageExtra = 18 + CGFloat(request.previewLines.count) * 14 + 6
        } else {
            messageExtra = alert.questionText != nil ? 30 : 0
        }
        let buttonExtra: CGFloat = canAnswer ? 6 + answerButtonHeight + 6 : 0
        return sectionSpacing + messageExtra + buttonExtra
    }

    /// Taller peek for `.waiting` alerts — adds room for the question message line
    /// and (when answerable) the Yes/No/1/2/3 button row. See
    /// `waitingExtraHeight` for the per-component budget.
    @MainActor
    static func waitingLayout(
        metrics: NotchMetrics,
        alerts: [DevReadyAlert],
        answerEnabled: Bool? = nil
    ) -> NotchContentLayoutMetrics {
        let base = devReadyLayout(metrics: metrics, alerts: alerts)
        let extra = waitingExtraHeight(alerts: alerts, answerEnabled: answerEnabled)
        return NotchContentLayoutMetrics(
            size: CGSize(width: base.size.width, height: base.size.height + extra),
            readability: base.readability,
            textScale: base.textScale
        )
    }

    /// Fixed-size peek for the in-app update progress bar.
    static func updateLayout(metrics: NotchMetrics) -> NotchContentLayoutMetrics {
        let width = min(metrics.designExpandedWidth * metrics.scale,
                        max(metrics.notchWidth + 240, 380))
        let height = metrics.notchHeight + metrics.topGap + 78
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: height),
            readability: 1.05,
            textScale: 1.05
        )
    }

    /// Room for the agent's question above the field: two 11pt lines plus the
    /// VStack's spacing. Must match what `ReplyComposeView` renders.
    static let replyQuestionExtra: CGFloat = 36

    /// Composer panel for the in-notch reply field. Grows when the target is a
    /// question, so the user can read what was asked while typing the answer
    /// instead of switching back to the terminal to re-read it.
    static func replyComposeLayout(metrics: NotchMetrics,
                                   hasQuestion: Bool = false) -> NotchContentLayoutMetrics {
        let width = min(metrics.designExpandedWidth * metrics.scale,
                        max(metrics.notchWidth + 240, 380))
        let height = metrics.notchHeight + metrics.topGap + 92
            + (hasQuestion ? replyQuestionExtra : 0)
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: height),
            readability: 1.05,
            textScale: 1.05
        )
    }

    /// Legacy helper used by tests.
    static func readabilityScale(itemCount: Int) -> CGFloat {
        switch itemCount {
        case 0: return 1.0
        case 1: return 2.2
        case 2: return 1.85
        case 3: return 1.5
        case 4: return 1.0
        case 5: return 0.88
        default: return max(0.7, 1.0 - CGFloat(itemCount - 4) * 0.08)
        }
    }

    /// Typography grows faster than layout when there is extra room.
    static func textScale(forLayoutScale scale: CGFloat) -> CGFloat {
        guard scale > 1 else { return max(0.82, scale) }
        return scale + (scale - 1) * 0.9
    }

    /// Type compensation for the user's size preference.
    ///
    /// The whole pill is shrunk uniformly, type included — so at 70% the text
    /// would render at 70% and become the first thing that stops being
    /// readable. This gives most of that back: shrinking to 70% still yields
    /// ~86% type, so the pill gets meaningfully smaller while the words stay
    /// legible. Growing is left alone; nobody enlarges the pill and then
    /// complains the text is too big.
    static func textCompensation(forUserScale userScale: CGFloat) -> CGFloat {
        guard userScale > 0, userScale < 1 else { return 1 }
        return 1 / pow(userScale, 0.55)
    }

    /// How many cards a pill this size can show without becoming unreadable.
    ///
    /// Shrinking has to *remove* things, not squeeze them — five cards crammed
    /// into a 70% pill is worse than two you can actually read. Cards are
    /// already in priority order (live agents first), so trimming the tail
    /// keeps what matters.
    static func visibleCardLimit(forUserScale userScale: CGFloat) -> Int {
        // Retuned after using it. The old cutoffs dropped the default size to
        // two cards, which read as content going missing rather than as a
        // deliberately compact pill — and the type compensation means three
        // still fit legibly at 70%.
        switch userScale {
        case ..<0.85: return 3
        case ..<1.0: return 4
        default: return 5
        }
    }

    /// Design canvas size (pre-scale) for the expanded card row.
    static func expandedDesignContentSize(metrics: NotchMetrics, activities: [ExpandedActivity]) -> CGSize {
        let layout = expandedLayout(metrics: metrics, activities: activities)
        let renderedContentHeight = max(0, layout.size.height - metrics.notchHeight - metrics.topGap)
        return CGSize(
            width: layout.size.width / metrics.scale,
            height: renderedContentHeight / metrics.scale
        )
    }

    // MARK: - Fit math

    private static func fitReadability(
        itemCount: Int,
        baseRowWidth: CGFloat,
        maxWidth: CGFloat,
        fewItemBoost: (CGFloat, CGFloat, CGFloat)
    ) -> CGFloat {
        guard baseRowWidth > 0, maxWidth > 0 else { return 1 }

        let fitScale = maxWidth / baseRowWidth
        if baseRowWidth <= maxWidth {
            switch itemCount {
            case 1: return min(fewItemBoost.0, max(1.6, fitScale * 0.95))
            case 2: return min(fewItemBoost.1, max(1.35, fitScale * 0.92))
            case 3: return min(fewItemBoost.2, max(1.1, fitScale * 0.9))
            default: return min(1.05, fitScale)
            }
        }
        return max(0.68, fitScale)
    }

    private static func collapsedChipBaseWidth(_ chip: CollapsedChip) -> CGFloat {
        switch chip {
        case .media: return 136
        case .systemStats: return 132
        case .calendar: return 96
        case .timer: return 56
        case .shelf: return 52
        case .appSwitch: return 72
        case .battery: return 44
        case .clock: return 72
        }
    }

    /// How tall the row needs to be: the tallest card in it, not a constant.
    ///
    /// It used to be a flat 96 with media on screen and 66 without, times the
    /// readability boost. That budgets for a *full* pill regardless of what is
    /// in it, so one agent row beside three CI rows got the same box as a
    /// crowded one and the difference showed up as dead space under the cards —
    /// worst at small sizes, where the whole point was to take less room.
    ///
    /// The constant was wrong in both directions, which is why this is measured
    /// per card rather than retuned. With media on screen and one agent row it
    /// budgeted 96 and left dead space under everything — the reported bug.
    /// With three agent rows and no media it budgeted 66 and clipped the third
    /// row mid-line, which nobody had reported but is visible the moment you
    /// look.
    ///
    /// Row-based cards grow with what they hold, capped at the rows they show
    /// before their own `ScrollView` takes over. The clamp is the range the
    /// pill has always lived in: never taller than a media row needs, never so
    /// short that a row of one-line chips becomes a letterbox.
    static func expandedContentBaseHeight(_ activities: [ExpandedActivity]) -> CGFloat {
        guard !activities.isEmpty else { return 66 }
        let tallest = activities.map(expandedCardBaseHeight).max() ?? 66
        return min(96, max(48, tallest))
    }

    /// Rows a card renders before it starts scrolling. Beyond this the card's
    /// own `ScrollView` takes over, so the pill must not keep growing.
    private static let expandedMaxCardRows = 3

    private static func rowsHeight(header: CGFloat, row: CGFloat, count: Int) -> CGFloat {
        header + row * CGFloat(min(expandedMaxCardRows, max(1, count)))
    }

    private static func expandedCardBaseHeight(_ activity: ExpandedActivity) -> CGFloat {
        switch activity {
        // Artwork and title over a transport row. Still the tallest card, and
        // the reason the old rule keyed off it — but it wants ~78, not the 96
        // the whole row was being sized to.
        case .media: return 78
        case .agents(let sessions): return rowsHeight(header: 18, row: 26, count: sessions.count)
        case .openCodeUsage: return 56
        case .codexQuota: return 56
        case .ci(let runs): return rowsHeight(header: 18, row: 18, count: runs.count)
        case .recentAlerts(let alerts): return rowsHeight(header: 18, row: 22, count: alerts.count)
        // Everything else is a label over a value.
        default: return 56
        }
    }

    private static func expandedCardBaseWidth(_ activity: ExpandedActivity) -> CGFloat {
        switch activity {
        case .media: return 248
        case .calendar: return 118
        case .timer: return 96
        case .systemStats: return 96
        case .shelf: return 108
        // Widest card by design: three rows of "project … status" need the room,
        // and a truncated project name defeats the point of the card.
        case .agents: return 210
        case .openCodeUsage: return 124
        case .codexQuota: return 164
        case .ci: return 150
        case .recentAlerts: return 170
        case .activeApp, .appSwitch: return 92
        case .volume: return 76
        case .clock: return 76
        case .battery: return 76
        }
    }
}

private extension NotchMetrics {
    var maxExpandedRenderedWidth: CGFloat {
        designExpandedWidth * scale
    }
}
