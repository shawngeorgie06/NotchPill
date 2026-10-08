import AppKit
import SwiftUI

/// Deterministic surfaces for checking card clipping and the root artwork wash
/// in SwiftUI previews and the visual fixture test suite.
@MainActor
struct VisualFixtureHarness: View {
    enum Surface: String, CaseIterable, Identifiable, Hashable {
        case mediaWithArtwork
        case notificationWithArtwork
        case maximumText
        case cardPicker
        case clipboardHeader
        case clipboardSearchEmpty
        case commandsEmpty
        case agentsDense
        case usageDense
        var id: String { rawValue }
    }

    @State private var surface: Surface
    @State private var reduceMotion: Bool
    @State private var display: Display
    /// Retains the earlier rectangular surface as a diagnostic comparison.
    let compareWave1Shoulders: Bool

    init(surface: Surface = .mediaWithArtwork, reduceMotion: Bool = false,
         display: Display = .builtIn, compareWave1Shoulders: Bool = true) {
        _surface = State(initialValue: surface)
        _reduceMotion = State(initialValue: reduceMotion)
        _display = State(initialValue: display)
        self.compareWave1Shoulders = compareWave1Shoulders
    }

    enum Display: String, CaseIterable, Identifiable {
        case builtIn, external, scaled
        var id: String { rawValue }

        var metrics: NotchMetrics {
            switch self {
            case .builtIn:
                NotchMetrics(notchWidth: 185, notchHeight: 32,
                             designExpandedWidth: 680, designExpandedHeight: 190, scale: 1)
            case .external:
                NotchMetrics(notchWidth: 220, notchHeight: 30,
                             designExpandedWidth: 760, designExpandedHeight: 220, scale: 1,
                             hasPhysicalNotch: false)
            case .scaled:
                NotchMetrics(notchWidth: 185, notchHeight: 32,
                             designExpandedWidth: 680, designExpandedHeight: 190,
                             scale: 0.72, userScale: 0.72)
            }
        }
    }

    private var artwork: NSImage {
        let image = NSImage(size: NSSize(width: 96, height: 96))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 48, height: 96)).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 48, y: 0, width: 48, height: 96)).fill()
        image.unlockFocus()
        return image
    }

    private var nowPlaying: NowPlaying {
        NowPlaying(title: "A Long Track Title That Must Stay Inside the Card",
                   artist: "Fixture Artist", isPlaying: true, artwork: artwork,
                   elapsed: 88, duration: 214)
    }

    private var notification: DevReadyAlert {
        DevReadyAlert(title: "Build finished successfully",
                      subtitle: "NotchPill · feature/visual-fixtures",
                      source: "Xcode", agent: "Fixture Agent")
    }

    private var activity: ExpandedActivity {
        switch surface {
        case .mediaWithArtwork: .media(nowPlaying)
        case .notificationWithArtwork: .activeApp(name: "Notification takeover")
        case .cardPicker: .activeApp(name: "All Cards")
        case .clipboardHeader: .clipboard([], searching: false)
        case .clipboardSearchEmpty: .clipboard([], searching: true)
        case .commandsEmpty: .commands([])
        case .agentsDense:
            .agents(AgentHomeTray([
                AgentSession(id: "fixture-working", agent: "claude-code", project: "NotchPill", state: .working, lastActivity: Date(timeIntervalSince1970: 1_791_470_000), task: "Refine the expanded notch typography and shoulder clearance"),
                AgentSession(id: "fixture-waiting", agent: "codex", project: "A longer project name", state: .waiting(since: nil), lastActivity: Date(timeIntervalSince1970: 1_791_470_000), task: "Review the build and verify the smallest readable labels")
            ]))
        case .usageDense:
            .claudeQuota(ClaudeQuota(sessionPercent: 76, sessionResetsAt: nil,
                                    weeklyPercent: 42, weeklyResetsAt: nil,
                                    extraSpentMinor: 250, extraLimitMinor: 1000,
                                    extraCurrency: "USD",
                                    modelWindows: [.init(name: "opus", percent: 58, resetsAt: nil)],
                                    updatedAt: nil))
        case .maximumText:
            .activeApp(name: String(repeating: "A long app title for clipping · ", count: 8))
        }
    }

    private var fixtureTokens: TokenUsageSummary {
        TokenUsageSummary(byTool: [TokenUsageSummary.claude: [
            "claude-opus": TokenTally(input: 450_000, output: 120_000, cacheRead: 2_500_000),
            "claude-sonnet": TokenTally(input: 80_000, output: 32_000)
        ]])
    }

    private var layout: NotchContentLayoutMetrics {
        if surface == .notificationWithArtwork {
            return NotchContentLayout.devReadyLayout(metrics: display.metrics, alerts: [notification])
        }
        return NotchContentLayout.expandedDeckLayout(metrics: display.metrics, activities: [activity])
    }

    private var contentHeight: CGFloat {
        NotchContentLayout.surfaceContentHeight(metrics: display.metrics, surfaceSize: layout.size)
    }

    private var backdrop: NowPlaying? {
        MediaBackdropSelection.resolve(
            isExpanded: true,
            isCollapsing: false,
            hasDevReadyAlerts: surface == .notificationWithArtwork,
            hasReplyCompose: false,
            hasUpdateProgress: false,
            activities: surface == .mediaWithArtwork ? [.media(nowPlaying)] : [.activeApp(name: "Fixture")],
            selectedPage: 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Card", selection: $surface) {
                    ForEach(Surface.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Display", selection: $display) {
                    ForEach(Display.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Toggle("Reduce Motion", isOn: $reduceMotion)
            }
            Text("Canvas \(Int(layout.size.width)) × \(Int(layout.size.height))")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: display.metrics.notchHeight)
                    if surface == .notificationWithArtwork {
                        DevReadyPeekListView(alerts: [notification], actions: .noop,
                                             titleLines: [notification.id: 2])
                            .padding(.top, NotchContentLayout.surfaceTopInset(metrics: display.metrics))
                            .frame(width: layout.size.width,
                                   height: contentHeight,
                                   alignment: .top)
                    } else if surface == .cardPicker {
                        NotchCardPicker(items: NotchDeckPickerItem.items(for: ExpandedActivity.allKinds.map(\.kind)),
                                        selectedKind: "agents", textScale: layout.textScale,
                                        reduceMotion: reduceMotion, onSelect: { _ in }, onClose: {})
                            .frame(width: layout.size.width, height: contentHeight)
                            .padding(.top, NotchContentLayout.surfaceTopInset(metrics: display.metrics))
                    } else {
                        ExpandedActivityCard(activity: activity,
                                             appIcon: nil,
                                             actions: .noop,
                                             readability: 1,
                                             textScale: NotchContentLayout.textScale(
                                                forLayoutScale: layout.readability),
                                             expandToFill: true,
                                             reduceMotionOverride: reduceMotion,
                                             bottomChromeHeight: NotchContentLayout.deckChromeHeight,
                                             tokenUsage: surface == .usageDense ? fixtureTokens : nil)
                            .padding(.horizontal, surface == .mediaWithArtwork ? 0 : NotchSpace.section)
                            .padding(.top, surface == .mediaWithArtwork ? 0 : NotchSpace.base)
                            .padding(.bottom, surface == .mediaWithArtwork ? 0 : NotchSpace.base + NotchContentLayout.deckChromeHeight)
                            .frame(width: layout.size.width, height: contentHeight, alignment: .top)
                            .padding(.top, NotchContentLayout.surfaceTopInset(metrics: display.metrics))
                    }
                }
            }
            .frame(width: layout.size.width, height: layout.size.height, alignment: .top)
            .mask {
                if compareWave1Shoulders {
                    ExpandedNotchShape(notchWidth: display.metrics.notchWidth,
                                       notchHeight: display.metrics.notchHeight,
                                       hasPhysicalNotch: display.metrics.hasPhysicalNotch,
                                       wrapsHardwareNotch: true)
                } else {
                    NotchShape(bottomRadius: 22, topRadius: display.metrics.hasPhysicalNotch ? 0 : 22)
                        .frame(height: layout.size.height - floatingInset)
                        .padding(.top, floatingInset)
                }
            }
            .background {
                if compareWave1Shoulders {
                    ExpandedPillSurface(notchWidth: display.metrics.notchWidth,
                                        notchHeight: display.metrics.notchHeight, progress: 1,
                                        hasPhysicalNotch: display.metrics.hasPhysicalNotch,
                                       wrapsHardwareNotch: true) {
                        fixtureBackdrop
                    }
                } else {
                    PillSurface(bottomRadius: 22, topRadius: display.metrics.hasPhysicalNotch ? 0 : 22) {
                        fixtureBackdrop
                    }
                    .frame(height: layout.size.height - floatingInset)
                    .padding(.top, floatingInset)
                }
            }
        }
        .padding()
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var floatingInset: CGFloat { display.metrics.hasPhysicalNotch ? 0 : 4 }

    @ViewBuilder
    private var fixtureBackdrop: some View {
        if let backdrop { MediaBackdrop(nowPlaying: backdrop, size: layout.size) }
    }
}

#Preview("Expanded card fixtures") {
    VisualFixtureHarness()
}
