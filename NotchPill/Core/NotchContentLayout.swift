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
        let rowHeight: CGFloat = 38 * readability
        let width = min(maxW, max(minW, baseRowWidth * readability))
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: metrics.notchHeight + rowHeight),
            readability: readability,
            textScale: textScale(forLayoutScale: readability)
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
                    height: metrics.notchHeight + metrics.topGap + 52
                ),
                readability: 1,
                textScale: 1
            )
        }

        let includesMedia = activities.contains(where: { if case .media = $0 { return true }; return false })
        let spacing: CGFloat = 10
        let padding: CGFloat = 32
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
        let baseContentHeight: CGFloat = includesMedia ? 120 : 84
        let contentHeight = baseContentHeight * readability
        let width = min(maxW, max(minW, baseRowWidth * readability))
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: metrics.notchHeight + metrics.topGap + contentHeight),
            readability: readability,
            textScale: textScale(forLayoutScale: readability)
        )
    }

    static func expandedSize(metrics: NotchMetrics, activities: [ExpandedActivity]) -> CGSize {
        expandedLayout(metrics: metrics, activities: activities).size
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
        guard scale > 1 else { return max(0.78, scale) }
        return scale + (scale - 1) * 0.55
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
        case .media: return 118
        case .systemStats: return 132
        case .calendar: return 96
        case .timer: return 56
        case .shelf: return 52
        case .appSwitch: return 72
        case .battery: return 44
        case .clock: return 72
        }
    }

    private static func expandedCardBaseWidth(_ activity: ExpandedActivity) -> CGFloat {
        switch activity {
        case .media: return 248
        case .calendar: return 118
        case .timer: return 96
        case .systemStats: return 96
        case .shelf: return 108
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
