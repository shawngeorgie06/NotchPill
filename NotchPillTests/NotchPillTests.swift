import Testing
import Foundation
import Combine
@testable import NotchPill

// MARK: - Geometry / metrics math (hardware-independent)

@Suite("NotchMetrics")
struct NotchMetricsTests {
    @Test("collapsed size matches the notch, expanded adds the pill height")
    func sizes() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 1.0)
        #expect(m.collapsedSize == CGSize(width: 180, height: 32))
        #expect(m.expandedSize == CGSize(width: 640, height: 222))
    }

    @Test("scale shrinks the rendered pill uniformly")
    func scaled() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 680, designExpandedHeight: 190, scale: 0.65)
        #expect(m.expandedWidth == 442)          // 680 * 0.65
        #expect(abs(m.expandedHeight - 123.5) < 0.001) // 190 * 0.65
        #expect(m.designContentSize == CGSize(width: 680, height: 190))
    }
}

// MARK: - Activity priority

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
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        state.notifyMediaChanged(NowPlaying(title: "B", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 400_000_000) // let it settle

        #expect(emissions == ["media"])
    }

    @Test("app-switch burst => single appSwitch render, then reverts to media")
    func appSwitchBurst() async throws {
        let state = NotchState()
        var emissions: [String] = []
        let cancellable = state.$activity.dropFirst().sink { emissions.append($0.transitionKey) }
        defer { cancellable.cancel() }

        // Establish media first.
        state.notifyMediaChanged(NowPlaying(title: "A", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        // Rapid app switches.
        state.notifyAppSwitched("Xcode")
        try await Task.sleep(nanoseconds: 80_000_000)
        state.notifyAppSwitched("Safari")
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(emissions.filter { $0 == "media" }.count == 1)
        #expect(emissions.filter { $0 == "appSwitch" }.count == 1)
    }
}
