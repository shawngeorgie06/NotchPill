import Testing
import Foundation
import Combine
@testable import NotchPill

// MARK: - Geometry / metrics math (hardware-independent)

@Suite("NotchMetrics")
struct NotchMetricsTests {
    @Test("collapsed size matches the notch, expanded design scales uniformly")
    func sizes() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 1.0)
        #expect(m.collapsedSize == CGSize(width: 180, height: 32))
        #expect(m.expandedWidth == 640)
        #expect(m.expandedHeight == 190)
    }

    @Test("scale shrinks the rendered pill uniformly")
    func scaled() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 680, designExpandedHeight: 190, scale: 0.65)
        #expect(m.expandedWidth == 442)          // 680 * 0.65
        #expect(abs(m.expandedHeight - 123.5) < 0.001) // 190 * 0.65
        #expect(m.designContentSize == CGSize(width: 680, height: 190))
    }

    @Test("collapsed preview grows with chip count")
    func collapsedPreview() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 0.65)
        #expect(m.collapsedPreviewSize(chipCount: 0) == m.collapsedSize)
        #expect(m.collapsedPreviewSize(chipCount: 2).width > m.collapsedSize.width)
        #expect(m.collapsedPreviewSize(chipCount: 2).height > m.collapsedSize.height)
    }
}

@Suite("NotchContentLayout")
struct NotchContentLayoutTests {
    @Test("fewer visible cards use a larger readability scale")
    func readabilityScaling() {
        let one = NotchContentLayout.readabilityScale(itemCount: 1)
        let three = NotchContentLayout.readabilityScale(itemCount: 3)
        let six = NotchContentLayout.readabilityScale(itemCount: 6)
        #expect(one > three)
        #expect(three > six)
    }

    @Test("text scale grows faster than layout when items are few")
    func textScaling() {
        let layoutScale: CGFloat = 1.8
        let text = NotchContentLayout.textScale(forLayoutScale: layoutScale)
        #expect(text > layoutScale)
    }

    @Test("expanded pill reshapes: fewer cards are larger, many cards compress")
    func expandedSizing() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 148, scale: 0.58)
        let one = NotchContentLayout.expandedLayout(metrics: metrics, activities: [.clock])
        let three: [ExpandedActivity] = [.clock, .volume(50), .battery(BatteryStatus(level: 80, isCharging: false))]
        let many = NotchContentLayout.expandedLayout(metrics: metrics, activities: three)
        #expect(one.size.width < many.size.width)
        #expect(one.readability > many.readability)
        #expect(one.size.height > many.size.height)
    }

    @Test("collapsed pill grows wider with more chips and shrinks readability")
    func collapsedSizing() {
        let metrics = NotchMetrics(notchWidth: 120, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 148, scale: 0.58)
        let np = NowPlaying(title: "T", artist: "A", isPlaying: true, artwork: nil)
        let one = NotchContentLayout.collapsedLayout(metrics: metrics, chips: [.media(np)])
        let three: [CollapsedChip] = [
            .media(np),
            .calendar(CalendarEvent(title: "Meet", start: .now, location: nil, isAllDay: false)),
            .timer(ActiveTimer(label: "Focus", endDate: Date().addingTimeInterval(300)))
        ]
        let many = NotchContentLayout.collapsedLayout(metrics: metrics, chips: three)
        #expect(one.readability > many.readability)
        #expect(many.size.width >= one.size.width)
    }
}

@Suite("ExpandedActivityBuilder")
struct ExpandedActivityBuilderTests {
    @Test("builds live status cards without calendar or shelf")
    func liveCards() {
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true, artwork: nil)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: np,
            nextEvent: nil,
            appSwitchHint: nil,
            frontmostApp: "Safari",
            systemVolume: 42,
            timer: nil,
            systemStats: nil,
            battery: nil,
            shelfCount: 0,
            shelfNames: [],
            showMedia: true,
            showActiveApp: true,
            showVolume: true,
            showClock: true,
            showCalendar: false,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showShelf: false
        )
        #expect(items.contains(.media(np)))
        #expect(items.contains(.activeApp(name: "Safari")))
        #expect(items.contains(.volume(42)))
        #expect(items.contains(.clock))
        #expect(items.count == 4)
    }

    @Test("respects card toggles")
    func toggles() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil,
            nextEvent: nil,
            appSwitchHint: nil,
            frontmostApp: "Safari",
            systemVolume: 50,
            timer: nil,
            systemStats: nil,
            battery: nil,
            shelfCount: 0,
            shelfNames: [],
            showMedia: false,
            showActiveApp: false,
            showVolume: false,
            showClock: true,
            showCalendar: false,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showShelf: false
        )
        #expect(items == [.clock])
    }
}

@Suite("NowPlaying progress")
struct NowPlayingProgressTests {
    @Test("interpolates elapsed time while playing")
    func interpolation() {
        let start = Date(timeIntervalSince1970: 1_000)
        let np = NowPlaying(
            title: "T",
            artist: "A",
            isPlaying: true,
            artwork: nil,
            elapsed: 10,
            duration: 100,
            playbackRate: 1,
            timestamp: start
        )
        let later = start.addingTimeInterval(5)
        #expect(abs((np.interpolatedElapsed(at: later) ?? 0) - 15) < 0.001)
    }
}

@Suite("CollapsedChipBuilder")
struct CollapsedChipBuilderTests {
    @Test("builds multiple chips at once")
    func multiple() {
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true, artwork: nil)
        let event = CalendarEvent(title: "Standup", start: Date().addingTimeInterval(900), location: nil, isAllDay: false)
        let chips = CollapsedChipBuilder.chips(
            nowPlaying: np,
            nextEvent: event,
            shelfCount: 2,
            appSwitchHint: nil,
            timer: nil,
            systemStats: nil,
            battery: nil,
            showMedia: true,
            showCalendar: true,
            showShelf: true,
            showAppSwitch: true,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showClock: false
        )
        #expect(chips.count == 3)
    }
}

@Suite("NotchActivity priority")
struct NotchActivityTests {
    @Test("app-switch outranks media, which outranks idle")
    func ordering() {
        let np = NowPlaying(title: "T", artist: "A", isPlaying: true, artwork: nil)
        #expect(NotchActivity.appSwitch("X").priority > NotchActivity.media(np).priority)
        #expect(NotchActivity.media(np).priority > NotchActivity.idle.priority)
    }
}

// MARK: - Shelf store

@MainActor
@Suite("ShelfStore")
struct ShelfStoreTests {
    private func isolatedStore() -> ShelfStore {
        ShelfStore(defaults: UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!)
    }

    @Test("add dedupes by URL")
    func dedupe() {
        let shelf = isolatedStore()
        let a = URL(fileURLWithPath: "/tmp/a.txt")
        let b = URL(fileURLWithPath: "/tmp/b.txt")
        shelf.add(urls: [a, b, a])
        #expect(shelf.items.count == 2)
        shelf.add(urls: [a])
        #expect(shelf.items.count == 2)
    }

    @Test("remove and clear")
    func removeClear() {
        let shelf = isolatedStore()
        shelf.add(urls: [URL(fileURLWithPath: "/tmp/a.txt"),
                         URL(fileURLWithPath: "/tmp/b.txt")])
        if let first = shelf.items.first { shelf.remove(first) }
        #expect(shelf.items.count == 1)
        shelf.clear()
        #expect(shelf.items.isEmpty)
    }

    @Test("items persist across store instances via shared defaults")
    func persistence() throws {
        let suite = "notchpill.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Use real, existing files so bookmarks resolve.
        let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("np-a.txt")
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("np-b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let first = ShelfStore(defaults: defaults)
        first.add(urls: [a, b])
        #expect(first.items.count == 2)

        // A fresh store on the same defaults should restore the items.
        let restored = ShelfStore(defaults: defaults)
        #expect(restored.items.count == 2)
        #expect(Set(restored.items.map { $0.url.lastPathComponent }) == ["np-a.txt", "np-b.txt"])
    }
}

// MARK: - State manager: debounce + priority (the core no-duplicate guarantee)

@MainActor
@Suite("NotchState debounce")
struct NotchStateTests {
    /// Two media changes within the debounce window must resolve to exactly one
    /// published activity.
    @Test("two media changes in <200ms => single render")
    func mediaBurstCoalesces() async throws {
        let state = NotchState()
        var emissions: [String] = []
        let cancellable = state.$activity.dropFirst().sink { emissions.append($0.transitionKey) }
        defer { cancellable.cancel() }

        state.notifyMediaChanged(NowPlaying(title: "A", artist: "x", isPlaying: true, artwork: nil))
        state.notifyMediaChanged(NowPlaying(title: "B", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(emissions == ["media"])
    }

    @Test("app-switch hint appears alongside media")
    func appSwitchBurst() async throws {
        let state = NotchState()
        var hints: [String?] = []
        let cancellable = state.$appSwitchHint.dropFirst().sink { hints.append($0) }
        defer { cancellable.cancel() }

        state.notifyMediaChanged(NowPlaying(title: "A", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        state.notifyAppSwitched("Xcode")
        try await Task.sleep(nanoseconds: 80_000_000)
        state.notifyAppSwitched("Safari")
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(hints.contains("Safari"))
    }
}
