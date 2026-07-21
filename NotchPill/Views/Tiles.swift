import SwiftUI

// MARK: - Now Playing

struct NowPlayingTile: View {
    let nowPlaying: NowPlaying?
    let actions: NotchActions

    var body: some View {
        HStack(spacing: 12) {
            artwork
            VStack(alignment: .leading, spacing: 2) {
                Text(nowPlaying?.title ?? "Nothing playing")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(nowPlaying?.artist ?? "—")
                    .font(.system(size: 11))
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
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Rectangle().fill(.white.opacity(0.08))
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.5))
                        .font(.system(size: 18))
                }
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var controls: some View {
        HStack(spacing: 16) {
            transportButton("backward.fill", action: actions.previous)
            transportButton(nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 15, action: actions.togglePlayPause)
            transportButton("forward.fill", action: actions.next)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat = 12, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .contentShape(Rectangle())
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Battery

struct BatteryTile: View {
    let battery: BatteryInfo

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Image(systemName: symbolName)
                    .font(.system(size: 26))
                    .foregroundStyle(color, .white.opacity(0.35))
                    .symbolRenderingMode(.palette)
            }
            Text("\(battery.percent)%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var symbolName: String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<15: return "battery.0"
        case ..<40: return "battery.25"
        case ..<65: return "battery.50"
        case ..<90: return "battery.75"
        default: return "battery.100"
        }
    }

    private var color: Color {
        if battery.isCharging || battery.isPluggedIn { return .green }
        return battery.percent < 15 ? .red : .white
    }
}

// MARK: - Calendar

struct CalendarTile: View {
    let event: CalendarEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(relativeStart, systemImage: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .lineLimit(1)
            Text(event.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            Text(timeString)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

// MARK: - Collapsed live-activity indicator

/// Compact indicator that hangs just below the notch when there is activity.
struct CollapsedIndicator: View {
    let activity: NotchActivity

    var body: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(.black))
    }

    @ViewBuilder private var content: some View {
        switch activity {
        case .idle:
            EmptyView()
        case .media(let np):
            HStack(spacing: 6) {
                Image(systemName: "music.note").font(.system(size: 10))
                Text(np.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                EqualizerBars()
            }
            .foregroundStyle(.white)
        case .appSwitch(let name):
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill").font(.system(size: 10))
                Text(name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(.white)
        }
    }
}

/// Tiny animated equalizer to signal live playback.
struct EqualizerBars: View {
    @State private var animating = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(Color.green)
                    .frame(width: 2, height: animating ? 10 : 4)
                    .animation(.easeInOut(duration: 0.4).repeatForever().delay(Double(i) * 0.12),
                               value: animating)
            }
        }
        .frame(height: 10)
        .onAppear { animating = true }
    }
}
