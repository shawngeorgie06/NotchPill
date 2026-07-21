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
        HStack(spacing: 12) {
            transportButton("backward.fill", action: actions.previous)
            transportButton(nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 17, action: actions.togglePlayPause)
            transportButton("forward.fill", action: actions.next)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat = 15, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
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
        HStack(spacing: 16) {
            transportButton("backward.fill", action: actions.previous)
            transportButton(nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                            size: 20, action: actions.togglePlayPause)
            transportButton("forward.fill", action: actions.next)
        }
    }

    private func transportButton(_ symbol: String, size: CGFloat = 17, action: @escaping () -> Void) -> some View {
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

// MARK: - File shelf

/// Drag files onto the notch to stash them here; drag them back out to Finder,
/// AirDrop, Mail, etc. Highlights while a drag hovers the drop zone.
struct ShelfTile: View {
    @ObservedObject var shelf: ShelfStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "tray.full").font(.system(size: 13))
                Text("Shelf").font(.system(size: 15, weight: .medium))
                Spacer(minLength: 0)
                if !shelf.items.isEmpty {
                    // Share/AirDrop everything on the shelf.
                    ShareLink(items: shelf.items.map(\.url)) {
                        Image(systemName: "square.and.arrow.up").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.7))
                    Button { shelf.clear() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.4))
                }
            }
            .foregroundStyle(.white.opacity(0.6))

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        if shelf.items.isEmpty {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                .foregroundStyle(shelf.isDropTargeted ? Color.accentColor : .white.opacity(0.25))
                .overlay(
                    Text("Drop files")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.4))
                )
                .frame(height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(shelf.isDropTargeted ? Color.accentColor.opacity(0.15) : .clear)
                )
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(shelf.items) { item in
                        ShelfChip(item: item) { shelf.remove(item) }
                    }
                }
            }
            .frame(height: 44)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(shelf.isDropTargeted ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
    }
}

/// A single stashed file: icon + name, draggable out, removable.
struct ShelfChip: View {
    let item: ShelfStore.Item
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 2) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 30, height: 30)
            Text(item.name)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(width: 44)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.06)))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.white, .black)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
        // Drag the real file back out to Finder / AirDrop / any drop target.
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .contextMenu {
            ShareLink("Share / AirDrop…", item: item.url)
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Button("Remove", role: .destructive, action: onRemove)
        }
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

// MARK: - Dev ready peek

/// One or more agent-ready rows when tasks finish around the same time.
struct DevReadyPeekListView: View {
    let alerts: [DevReadyAlert]
    let actions: NotchActions
    /// When set, the row list scrolls inside this height (used for multiple agents).
    var maxScrollHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            if alerts.count > 1 {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchDesign.devReadyGreen)
                    Text("\(alerts.count) agents ready")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
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
            ForEach(Array(alerts.enumerated()), id: \.element.id) { index, alert in
                DevReadyPeekRow(alert: alert, actions: actions)
                if index < alerts.count - 1 {
                    Rectangle()
                        .fill(Color.white.opacity(0.08))
                        .frame(height: 1)
                        .padding(.horizontal, 12)
                }
            }
        }
    }
}

/// Single dev-ready row — tap to jump to the source app and dismiss that agent.
struct DevReadyPeekRow: View {
    let alert: DevReadyAlert
    let actions: NotchActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: handleTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(NotchDesign.devReadyGreen.opacity(0.22))
                        .frame(width: pulse ? 18 : 12, height: pulse ? 18 : 12)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                                   value: pulse)
                    Circle()
                        .fill(NotchDesign.devReadyGreen)
                        .frame(width: 8, height: 8)
                }
                .frame(width: 20)

                sourceIcon

                VStack(alignment: .leading, spacing: 3) {
                    Text(alert.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        if let agent = alert.agent, !agent.isEmpty {
                            agentBadge(agent, prominent: true)
                        }
                        if let source = alert.source, !source.isEmpty,
                           alert.agent?.caseInsensitiveCompare(source) != .orderedSame {
                            agentBadge(source, prominent: false)
                        }
                        if let subtitle = alert.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        } else if alert.bundleId != nil {
                            Text("Tap to open")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.38))
                        }
                    }
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(DevReadyRowButtonStyle())
        .onAppear { pulse = !reduceMotion }
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if let icon = alert.appIcon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NotchDesign.devReadyGreen)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private func agentBadge(_ text: String, prominent: Bool) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(prominent ? NotchDesign.devReadyGreen : .white.opacity(0.55))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                (prominent ? NotchDesign.devReadyGreen.opacity(0.14) : Color.white.opacity(0.08)),
                in: Capsule()
            )
    }

    private func handleTap() {
        if let bundleId = alert.bundleId {
            actions.focusApp(bundleId)
        }
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
    static func activities(
        nowPlaying: NowPlaying?,
        nextEvent: CalendarEvent?,
        appSwitchHint: String?,
        frontmostApp: String?,
        systemVolume: Int?,
        timer: ActiveTimer?,
        systemStats: SystemStats?,
        battery: BatteryStatus?,
        shelfCount: Int,
        shelfNames: [String],
        showMedia: Bool,
        showActiveApp: Bool,
        showVolume: Bool,
        showClock: Bool,
        showCalendar: Bool,
        showTimer: Bool,
        showSystemStats: Bool,
        showBattery: Bool,
        showShelf: Bool
    ) -> [ExpandedActivity] {
        var items: [ExpandedActivity] = []
        if showMedia, let np = nowPlaying, !np.isEmpty { items.append(.media(np)) }
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
        if showShelf, shelfCount > 0 { items.append(.shelf(count: shelfCount, names: shelfNames)) }
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

    private func s(_ value: CGFloat) -> CGFloat { value * readability }
    private func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size * textScale, weight: weight)
    }

    var body: some View {
        Group {
            switch activity {
            case .media(let np):
                mediaCard(np)
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
            case .shelf(let count, let names):
                shelfCard(count: count, names: names)
            }
        }
        .frame(
            minWidth: expandToFill ? nil : s(88),
            maxWidth: expandToFill ? .infinity : nil,
            alignment: .leading
        )
        .layoutPriority(expandToFill ? 1 : 0)
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
                if np.isPlaying { EqualizerBars(scale: readability) }
            }
            HStack(spacing: s(14)) {
                transportButton("backward.fill", action: actions.previous)
                transportButton(np.isPlaying ? "pause.fill" : "play.fill", size: 16, action: actions.togglePlayPause)
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

    private func appCard(title: String, name: String) -> some View {
        VStack(alignment: .leading, spacing: s(6)) {
            Text(title)
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            HStack(spacing: s(6)) {
                if let appIcon {
                    Image(nsImage: appIcon)
                        .resizable()
                        .frame(width: s(22), height: s(22))
                } else {
                    Image(systemName: "app.fill")
                        .font(.system(size: s(18)))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Text(name)
                    .font(font(size: 14, weight: .semibold))
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
                Label(timer.label, systemImage: "timer")
                    .font(font(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                Text(StatusFormatting.countdown(timer.remaining(at: context.date)))
                    .font(font(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                Button("Cancel", action: onCancelTimer)
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

    private func shelfCard(count: Int, names: [String]) -> some View {
        VStack(alignment: .leading, spacing: s(4)) {
            Label("Shelf", systemImage: "tray.full")
                .font(font(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.45))
            Text(count == 1 ? "1 file" : "\(count) files")
                .font(font(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            ForEach(names, id: \.self) { name in
                Text(name)
                    .font(font(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
        }
        .frame(minWidth: s(100), alignment: .leading)
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

    private func transportButton(_ symbol: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: s(size), weight: .medium))
                .foregroundStyle(.white)
                .frame(width: s(20), height: s(20))
                .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
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
        showMedia: Bool,
        showCalendar: Bool,
        showShelf: Bool,
        showAppSwitch: Bool,
        showTimer: Bool,
        showSystemStats: Bool,
        showBattery: Bool,
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
                if case .media(let np) = chip, np.isPlaying {
                    EqualizerBars(scale: readability)
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
