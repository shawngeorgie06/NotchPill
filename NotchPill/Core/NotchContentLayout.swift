import AppKit
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

    /// The attached island is a deck, not a dashboard. Every activity gets a
    /// readable full-width page, so adding media, quota, CI, or another agent
    /// never turns the notch into a wider or denser strip of tiny cards.
    static func expandedDeckLayout(metrics: NotchMetrics, activities: [ExpandedActivity],
                                   page: Int? = nil,
                                   tokenRows: Int = 0) -> NotchContentLayoutMetrics {
        let maxW = metrics.maxExpandedRenderedWidth
        let preferredWidth = 360 * metrics.userScale
        let width = min(maxW, max(metrics.notchWidth + 112, preferredWidth))
        let cardHeight = min(expandedContentCeiling,
                             max(56, expandedContentBaseHeight(activities, page: page,
                                                              tokenRows: tokenRows)))
        // The page dot is part of the deck's frame of reference, even when
        // there is only one card. A consistent footer says "this is page 1"
        // rather than making media, active app, or any other one-page setup
        // look like a different kind of notch. Its space is reserved here,
        // alongside the card, so it cannot hang below the pill.
        let deckChrome: CGFloat = showsDeckChrome(for: activities) ? deckChromeHeight : 0
        return NotchContentLayoutMetrics(
            size: CGSize(width: width,
                         height: metrics.notchHeight + metrics.topGap + cardHeight + deckChrome + 10),
            readability: 1,
            textScale: textCompensation(forUserScale: metrics.userScale)
        )
    }

    static func expandedDeckSize(metrics: NotchMetrics, activities: [ExpandedActivity],
                                 page: Int? = nil, tokenRows: Int = 0) -> CGSize {
        expandedDeckLayout(metrics: metrics, activities: activities,
                           page: page, tokenRows: tokenRows).size
    }

    /// Every nonempty deck gets its footer, including a single-page deck. This
    /// is shared by the SwiftUI view and the sizing code: splitting the rule is
    /// how the dots once rendered outside the window reserved for them.
    static func showsDeckChrome(for activities: [ExpandedActivity]) -> Bool {
        !activities.isEmpty
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
    /// The reply (↰) control: a 28pt circle plus its 8pt trailing padding.
    static let replyControlWidth: CGFloat = 36
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

    /// Ceiling on how tall a caption may push the peek.
    ///
    /// Was four, which still truncated ordinary dictation: the peek is capped
    /// near 416pt wide, so a line holds roughly 47 characters and four lines
    /// ran out inside two spoken sentences — the ellipsis was back. Eight
    /// covers a paragraph (~375 characters) and still leaves the peek shorter
    /// than the screen.
    ///
    /// A ceiling stays, rather than growing without limit: past a paragraph the
    /// notch stops being a glance and becomes a document, and the full text is
    /// already on the clipboard. Where the estimate falls short the title
    /// shrinks to fit instead of truncating — see `titleMinimumScale`.
    static let baseTitleMaxLines = 12

    /// The ceiling after the user's caption-size preference is applied.
    static func titleMaxLines(scale: Double = 1) -> Int {
        max(1, Int((Double(baseTitleMaxLines) * scale).rounded()))
    }

    /// Kept for callers that do not scale (and for the default argument below).
    static var titleMaxLines: Int { baseTitleMaxLines }

    /// How far a wrapped title may shrink to avoid an ellipsis.
    ///
    /// The line estimate is a character-count approximation — real glyph widths
    /// vary, so a caption that needs 8.2 lines by measurement would truncate at
    /// an 8-line limit no matter how carefully the constant is tuned. Allowing
    /// the type to drop to 80% (13pt → ~10.4pt, still comfortably readable)
    /// turns that class of near-miss into slightly smaller text rather than
    /// lost words, which is the better trade for something you enabled in order
    /// to read.
    ///
    /// It also absorbs the estimator's error in the one direction the height
    /// budget cannot: shrinking never needs more height than was reserved.
    static let titleMinimumScale: CGFloat = 0.8

    /// Height of one wrapped title line at the peek's 13pt semibold, including
    /// the `VStack(spacing: 3)` the row draws between lines.
    static let titleLineHeight: CGFloat = 17

    /// Width a peek gets when its title wraps.
    ///
    /// Ordinary peeks are capped at `maxExpandedRenderedWidth` — 720 × 0.54 ≈
    /// 389pt here — which with `devReadyMinWidth` at 380 leaves them barely a
    /// character of slack. That is right for an agent peek, whose title is a
    /// label and whose job is to stay notch-shaped.
    ///
    /// It is the wrong ceiling for a caption. At ~389pt a line holds about 47
    /// characters, so a spoken paragraph needs eight of them and anything
    /// longer truncates no matter how the height budget is tuned. Height was
    /// never the scarce resource; **width** was. Doubling the width halves the
    /// lines, which is the only change here with real headroom in it.
    ///
    /// Bounded by the actual screen rather than a constant, so this cannot
    /// produce a peek wider than the display on hardware I cannot test. 60% of
    /// the screen keeps it recognisably a notch element rather than a banner,
    /// and it never returns less than the ordinary cap.
    static func peekWidthCeiling(metrics: NotchMetrics, wrapping: Bool,
                                 scale: Double = 1) -> CGFloat {
        let ordinary = metrics.maxExpandedRenderedWidth
        guard wrapping else { return ordinary }
        let fraction = min(0.94, 0.72 * scale)
        guard metrics.screenWidth > 0 else {
            return max(ordinary, min(760 * CGFloat(scale), 1200))
        }
        // Never wider than the screen, whatever the preference says: the peek
        // is centred on the notch, so an over-wide one would hang off both
        // edges rather than simply looking large.
        return max(ordinary, min(metrics.screenWidth * CGFloat(fraction),
                                 metrics.screenWidth - 24))
    }

    /// Characters that fit on one line of the 13pt semibold title at `width`.
    ///
    /// Kept for the height *estimate* only. Text is not monospaced, so this
    /// average is wrong for any individual sentence — see `measuredTitleLines`.
    static func titleCharactersPerLine(width: CGFloat) -> Int {
        // The row spends width on the status dot, the source icon and controls.
        let textWidth = width - (dismissControlWidth + 70)
        return max(8, Int(textWidth / 6.6))
    }

    /// The exact font `DevReadyPeekRow` renders a title in. Measuring against
    /// anything else is guesswork, and guessing low is what puts an ellipsis on
    /// a sentence that was supposed to fit.
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    /// Width left for the title once the row's furniture is paid for: status
    /// dot, source icon, and the ✕ (plus ↰ where a row can reply).
    static func titleTextWidth(inPeekOfWidth width: CGFloat, replyable: Bool) -> CGFloat {
        max(60, width - (dismissControlWidth + (replyable ? replyControlWidth : 0) + 70))
    }

    /// Lines this exact string needs at this exact width, by measuring it.
    ///
    /// The old character-count estimate divided length by an average glyph
    /// width. That average is wrong for every real sentence — "Will" and "MMMM"
    /// are the same four characters and nowhere near the same width — and when
    /// it guessed low the row was given `lineLimit(1)` for text that needed
    /// 1.2 lines, so the tail was replaced by "…". A short sentence truncating
    /// while a long one wrapped fine was exactly this: the estimate only has to
    /// be wrong by one line, and it is wrongest near the boundary.
    ///
    /// TextKit answers the same question the renderer will ask, so the count is
    /// right by construction rather than by tuning a constant.
    static func measuredTitleLines(for text: String, width: CGFloat,
                                   maxLines: Int, replyable: Bool = false) -> Int {
        guard !text.isEmpty else { return 1 }
        let textWidth = titleTextWidth(inPeekOfWidth: width, replyable: replyable)
        let bounds = NSAttributedString(string: text, attributes: [.font: titleFont])
            .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading])
        let lines = Int(ceil(bounds.height / titleLineHeight - 0.01))
        return min(maxLines, max(1, lines))
    }

    /// Lines a title of this length needs.
    ///
    /// Estimated from `devReadyMinWidth` rather than the peek's final width,
    /// and that choice is deliberate: the real peek is never *narrower* than
    /// the minimum, so a wider one needs fewer lines than this predicts. The
    /// error therefore only ever runs toward reserving height that goes unused,
    /// never toward text drawn outside the window.
    static func titleLines(for text: String,
                           width: CGFloat = devReadyMinWidth,
                           maxLines: Int = baseTitleMaxLines) -> Int {
        let perLine = titleCharactersPerLine(width: width)
        let needed = Int(ceil(Double(text.count) / Double(perLine)))
        return min(maxLines, max(1, needed))
    }

    /// Extra height the wrapped titles add, over the one line already inside
    /// `devReadyRowHeight`. Summed over the rows actually shown, largest first,
    /// on the same reasoning as `waitingExtraHeight`.
    static func titleExtraHeight(alerts: [DevReadyAlert],
                                 lines: [String: Int] = [:]) -> CGFloat {
        alerts
            .map { CGFloat(max(1, lines[$0.id] ?? $0.titleLines ?? 1) - 1) * titleLineHeight }
            .sorted(by: >)
            .prefix(devReadyMaxVisibleRows)
            .reduce(0, +)
    }

    /// The shape a caption should settle into before it is worth getting wider.
    ///
    /// Width is spent only to keep a caption from becoming a tall column. Below
    /// this many lines the peek has a sensible shape already and taking more of
    /// the screen buys nothing; above it, widening is what stops the pill from
    /// running down the display.
    static let captionTargetLines = 4

    /// The narrowest width that shows the text, rather than the widest allowed.
    ///
    /// The ceiling is a *limit*, and using it as the answer made every caption
    /// the same enormous width: a short sentence became a 1050pt ribbon two
    /// lines tall, which is a worse shape than the one it replaced. Extra width
    /// is only worth taking when the alternative is running out of lines.
    ///
    /// So: grow only until the text fits inside the line budget, then take back
    /// whatever the last line did not use. That second step is what removes the
    /// dead space after a short caption — wrapped text almost never fills its
    /// final line, and a box sized to the width you *offered* rather than the
    /// width the text *used* has a blank tail by construction.
    static func fittedCaptionWidth(titles: [String], ordinary: CGFloat, ceiling: CGFloat,
                                   targetLines: Int, replyable: Bool) -> CGFloat {
        guard ceiling > ordinary else { return ordinary }
        func linesNeeded(at width: CGFloat) -> Int {
            titles.map {
                measuredTitleLines(for: $0, width: width, maxLines: .max, replyable: replyable)
            }.max() ?? 1
        }
        // Binary search the narrowest width inside the budget. Widths are
        // continuous and the line count falls monotonically with width, so a
        // handful of probes lands within a point of the boundary.
        var low = ordinary
        var high = ceiling
        if linesNeeded(at: ordinary) <= targetLines {
            high = ordinary
        } else if linesNeeded(at: ceiling) > targetLines {
            // Even the widest peek cannot hold it. Take the ceiling; the line
            // cap and `minimumScaleFactor` absorb the remainder.
            return ceiling
        } else {
            for _ in 0..<12 {
                let mid = (low + high) / 2
                if linesNeeded(at: mid) <= targetLines { high = mid } else { low = mid }
            }
        }
        let fitted = high
        // Reclaim the unused tail of the last line.
        let furniture = fitted - titleTextWidth(inPeekOfWidth: fitted, replyable: replyable)
        let ink = titles.map { title -> CGFloat in
            guard !title.isEmpty else { return 0 }
            return NSAttributedString(string: title, attributes: [.font: titleFont])
                .boundingRect(with: CGSize(width: titleTextWidth(inPeekOfWidth: fitted,
                                                                replyable: replyable),
                                           height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading])
                .width
        }.max() ?? 0
        // +2 for the rounding TextKit does between measuring and drawing. Never
        // narrower than an ordinary peek, and never wider than what we fitted.
        let tightened = min(fitted, max(ordinary, ceil(ink) + furniture + 2))
        // Taking width back must not cost a line — a word pushed onto a new row
        // would trade the blank tail for a taller pill.
        return linesNeeded(at: tightened) <= linesNeeded(at: fitted) ? tightened : fitted
    }

    /// One answer for "how wide is the peek, and how many lines does each row
    /// get", so the window, the height budget and the renderer cannot disagree.
    ///
    /// They used to. `titleLines` was baked into the alert at ~380pt, the width
    /// was then clamped by a character-count heuristic that could land anywhere
    /// between 380 and the ceiling, and the row was given a `lineLimit` computed
    /// for neither. A short caption came out at ~494pt with `lineLimit(1)` and
    /// truncated; only text long enough to push the heuristic past the ceiling
    /// got the wide peek it needed.
    struct PeekTitleLayout {
        var width: CGFloat
        var lines: [String: Int]
        func lines(for alert: DevReadyAlert) -> Int { lines[alert.id] ?? 1 }
    }

    /// Last computed answer, kept because this is called from a view body.
    ///
    /// Sizing a peek now measures text rather than counting characters, and
    /// `fittedCaptionWidth` probes a dozen widths to find the narrowest fit —
    /// so one call can lay out a long caption fifteen times. SwiftUI re-renders
    /// this view on hover ticks, which run at display rate, and the peek's
    /// contents almost never change while it is on screen. A single-entry memo
    /// therefore removes essentially all of the repeat work; without it the
    /// cost scales with the length of what you dictated, on every frame.
    @MainActor private static var memo: (key: PeekTitleKey, value: PeekTitleLayout)?

    private struct PeekTitleKey: Equatable {
        var titles: [String]
        var ids: [String]
        var ordinary: CGFloat
        var ceiling: CGFloat
        var maxLines: Int
        var replyable: Bool
    }

    @MainActor
    static func peekTitleLayout(metrics: NotchMetrics, alerts: [DevReadyAlert],
                                answerEnabled: Bool? = nil) -> PeekTitleLayout {
        let replyEnabled = answerEnabled ?? AppSettings.shared.agentReplyEnabled
        let anyReplyable = alerts.contains { $0.canReplyFromNotch(replyEnabled: replyEnabled) }
        let controls = dismissControlWidth + (anyReplyable ? replyControlWidth : 0)
        let labelLen = CGFloat(alerts.map { ($0.agent ?? $0.source ?? $0.title).count }.max() ?? 16)
        let titleLen = CGFloat(alerts.map(\.title.count).max() ?? 16)
        let contentWidth = 300 + controls + max(labelLen, titleLen) * 2.5
        let maxLines = titleMaxLines(scale: AppSettings.shared.captionScale)

        // What the peek would be if nothing wrapped — an agent ping's width.
        let ordinary = min(
            peekWidthCeiling(metrics: metrics, wrapping: false),
            max(metrics.notchWidth + 168, devReadyMinWidth, contentWidth)
        )
        let ceilingForKey = peekWidthCeiling(metrics: metrics, wrapping: true,
                                             scale: AppSettings.shared.captionScale)
        let key = PeekTitleKey(titles: alerts.map(\.displayTitle), ids: alerts.map(\.id),
                               ordinary: ordinary, ceiling: ceilingForKey,
                               maxLines: maxLines, replyable: anyReplyable)
        if let memo, memo.key == key { return memo.value }

        // Wrapping is decided by measuring at that width, not by guessing from
        // length. Anything that does not fit on one line there is content
        // rather than a label, and content gets the wider ceiling outright —
        // *not* `min`'d against the character heuristic, which is what used to
        // strand a short caption at a width its own text did not fit in.
        let wrapping = alerts.contains {
            measuredTitleLines(for: $0.displayTitle, width: ordinary,
                               maxLines: maxLines, replyable: anyReplyable) > 1
        }
        let ceiling = ceilingForKey
        let width = wrapping
            ? fittedCaptionWidth(titles: alerts.map(\.displayTitle),
                                 ordinary: ordinary, ceiling: ceiling,
                                 targetLines: captionTargetLines, replyable: anyReplyable)
            : ordinary
        // Measured again at the width actually used: a caption that needed six
        // lines at 389pt may need two at 1058pt, and reserving six would leave
        // four lines of empty pill under it.
        var lines: [String: Int] = [:]
        for alert in alerts {
            lines[alert.id] = measuredTitleLines(for: alert.displayTitle, width: width,
                                                 maxLines: maxLines, replyable: anyReplyable)
        }
        let result = PeekTitleLayout(width: width, lines: lines)
        memo = (key, result)
        return result
    }

    @MainActor
    static func devReadyLayout(metrics: NotchMetrics, alerts: [DevReadyAlert],
                               answerEnabled: Bool? = nil) -> NotchContentLayoutMetrics {
        let count = max(1, alerts.count)
        let headerHeight: CGFloat = count > 1 ? 18 : 0
        let listHeight = devReadyListHeight(rowCount: count)
        let title = peekTitleLayout(metrics: metrics, alerts: alerts, answerEnabled: answerEnabled)
        let height = metrics.notchHeight + metrics.topGap + headerHeight + listHeight + 4
            + titleExtraHeight(alerts: alerts, lines: title.lines)
        return NotchContentLayoutMetrics(
            size: CGSize(width: title.width, height: height),
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
            let lines = request.isPlan ? request.planPreview.count
                : max(request.previewLines.count, request.commandPreviewLineLimit)
            messageExtra = 18 + CGFloat(lines) * 14 + 6
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
        let base = devReadyLayout(metrics: metrics, alerts: alerts, answerEnabled: answerEnabled)
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
        case .agent: return 118
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
    /// before their own `ScrollView` takes over. Agent rows deliberately earn
    /// a little more vertical room than the small utility cards: the expanded
    /// notch is where you read the work, rather than merely count sessions.
    /// The ceiling is two agent rows plus their header.
    ///
    /// It used to be 112, which was two rows back when a row was ~47pt. The
    /// console redesign took rows to 52 and the ceiling stayed put, so two
    /// sessions and three both clamped to the same height and you saw one row
    /// and a sliver of the next — the card scrolled with only two agents on it.
    ///
    /// Derived from the row metrics rather than written as a number so the two
    /// cannot drift apart again.
    static let expandedContentCeiling: CGFloat = agentsHeader + agentsRow * 2

    /// Height for the card **on screen**, not the tallest card in the deck.
    ///
    /// The deck shows one page at a time, but was sized to whichever card was
    /// tallest — so a three-row agents card left the pill that tall on every
    /// other page, and a usage card sat in a block of empty space it had no
    /// use for. Sizing to the visible page costs an animated height change
    /// when you turn a page, which is what a deck of different-sized cards
    /// should do anyway.
    ///
    /// `page` out of range falls back to the old behaviour rather than
    /// guessing, so a transient mismatch between the view's page and the
    /// layout's cannot produce a collapsed pill.
    static func expandedContentBaseHeight(_ activities: [ExpandedActivity],
                                          page: Int? = nil,
                                          tokenRows: Int = 0) -> CGFloat {
        guard !activities.isEmpty else { return 66 }
        let measured: CGFloat
        if let page, activities.indices.contains(page) {
            measured = expandedCardBaseHeight(activities[page], tokenRows: tokenRows)
        } else {
            measured = activities.map { expandedCardBaseHeight($0, tokenRows: tokenRows) }.max() ?? 66
        }
        return min(expandedContentCeiling, max(48, measured))
    }

    /// Height the deck's footer strip needs: the page dots' 22pt tap targets
    /// plus the 5pt `VStack` gap above them.
    ///
    /// Was 22 — the strip's own height with the gap forgotten. Five points is
    /// not much until a card is also over its own budget, and then the two
    /// shortfalls land on the same edge and clip the row that tells you which
    /// page you are on and how many there are.
    static let deckChromeHeight: CGFloat = 27

    /// Rows a card renders before it starts scrolling. Beyond this the card's
    /// own `ScrollView` takes over, so the pill must not keep growing.
    private static let expandedMaxCardRows = 3

    /// An agent row's title/status line, its activity line, and the runtime and
    /// context line under them — plus the card header. Named because the height
    /// ceiling is derived from these; see `expandedContentCeiling`.
    ///
    /// 52 → 63 when the metrics line was added. The row grew and this did not,
    /// which is the exact drift the ceiling comment above warns about.
    static let agentsHeader: CGFloat = 18
    static let agentsRow: CGFloat = 63

    private static func rowsHeight(header: CGFloat, row: CGFloat, count: Int) -> CGFloat {
        header + row * CGFloat(min(expandedMaxCardRows, max(1, count)))
    }

    /// Height the folded token lines need on a quota card.
    ///
    /// A total line at 11pt plus one 9pt line per model shown, over the small
    /// pad above them. Declared here rather than left to the view, because a
    /// card that renders more than its budget pushes the deck's page dots off
    /// the bottom of the pill — the same drift `agentsRow` documents.
    static func tokenLinesHeight(modelRows: Int) -> CGFloat {
        guard modelRows > 0 else { return 0 }
        return 3 + 14 + 12 * CGFloat(modelRows)
    }

    private static func expandedCardBaseHeight(_ activity: ExpandedActivity,
                                               tokenRows: Int = 0) -> CGFloat {
        switch activity {
        case .claudeQuota: return 70 + tokenLinesHeight(modelRows: tokenRows)
        case .codexQuota: return 56 + tokenLinesHeight(modelRows: tokenRows)
        // Artwork and title over a transport row. Still the tallest card, and
        // the reason the old rule keyed off it — but it wants ~78, not the 96
        // the whole row was being sized to.
        case .media: return 78
        // Agent rows have a title/status line and one terminal-style activity
        // line. Two are visible — the ceiling is derived from exactly that —
        // and a third or later session scrolls inside the card instead of
        // turning the notch into a full-height panel.
        case .agents(let sessions): return rowsHeight(header: agentsHeader, row: agentsRow,
                                                      count: sessions.count)
        case .openCodeUsage: return 56
        // Header (13) + 3 + meter (15pt value 18, 2, bar 4, 2, 9pt caption 11
        // = 37) + 3 + a 10pt trailing line (13). The trailing line is the
        // "extra $x" on Claude and the "38 of 2000 · renews in 27d" on Cursor;
        // both were budgeted as if it were not there, so the card overflowed
        // its allowance by exactly one line and pushed the deck's page dots off
        // the bottom of the pill.
        case .cursorQuota: return 70
        case .shelf: return 66
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
        case .claudeQuota: return 176
        case .cursorQuota: return 176
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
