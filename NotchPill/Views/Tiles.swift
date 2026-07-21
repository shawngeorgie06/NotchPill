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
        .background(.black.opacity(0.82), in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        .offset(y: 52)
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
