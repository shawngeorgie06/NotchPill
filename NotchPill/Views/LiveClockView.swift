import SwiftUI

enum LiveClockFormatting {
    private static let timeWithSeconds: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("h:mm:ss a")
        return df
    }()

    private static let timeCompact: DateFormatter = {
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        return df
    }()

    private static let weekdayDate: DateFormatter = {
        let df = DateFormatter()
        df.setLocalizedDateFormatFromTemplate("EEE MMM d")
        return df
    }()

    static func time(_ date: Date, includeSeconds: Bool) -> String {
        includeSeconds ? timeWithSeconds.string(from: date) : timeCompact.string(from: date)
    }

    static func date(_ date: Date) -> String {
        weekdayDate.string(from: date)
    }
}

/// Live clock with rolling second updates for collapsed and expanded notch UI.
struct LiveClockView: View {
    enum Style { case collapsed, expanded }

    var style: Style = .expanded
    var textScale: CGFloat = 1.0
    var readability: CGFloat = 1.0
    var showSeconds: Bool = true

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func textSize(_ base: CGFloat) -> CGFloat { base * textScale }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let time = LiveClockFormatting.time(context.date, includeSeconds: showSeconds)
            switch style {
            case .collapsed:
                Text(time)
                    .font(.system(size: textSize(11), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .animation(.linear(duration: 0.18), value: time)
            case .expanded:
                VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
                    HStack(spacing: s(NotchSpace.snug)) {
                        Image(systemName: "clock")
                            .font(.system(size: textSize(NotchType.caption), weight: .bold))
                            .frame(width: s(NotchSpace.mark), height: s(NotchSpace.mark))
                            .background(RoundedRectangle(cornerRadius: s(NotchRadius.well), style: .continuous)
                                .fill(.white.opacity(NotchOpacity.wellFill)))
                        Text("Local time")
                            .font(.system(size: textSize(NotchType.title), weight: .semibold))
                            .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                    }
                    .padding(.bottom, s(NotchSpace.snug))
                    Text(time)
                        .font(.system(size: textSize(NotchType.hero), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.18), value: time)
                    Text(LiveClockFormatting.date(context.date))
                        .font(.system(size: textSize(NotchType.body), weight: .medium))
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }
}
