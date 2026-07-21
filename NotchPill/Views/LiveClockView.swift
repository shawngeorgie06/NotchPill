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
                VStack(alignment: .leading, spacing: s(4)) {
                    Text(time)
                        .font(.system(size: textSize(20), weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .animation(.linear(duration: 0.18), value: time)
                    Text(LiveClockFormatting.date(context.date))
                        .font(.system(size: textSize(11), weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineLimit(1)
                }
                .frame(minWidth: s(88), alignment: .leading)
            }
        }
    }
}
