import Testing
import Foundation
import Combine
@testable import NotchPill

// MARK: - Process capture (artwork deadlock regression)

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures output larger than the pipe buffer without deadlocking")
    func largeOutput() {
        // ~200 KB, far exceeding the ~64 KB pipe buffer. The old pattern
        // (waitUntilExit before draining) would hang here — the exact bug that
        // froze the now-playing stream on artwork fetch.
        let byteCount = 200_000
        let data = ProcessRunner.capture("/bin/sh", ["-c", "head -c \(byteCount) /dev/zero | base64"])
        #expect(data != nil)
        // base64 of 200 KB is ~270 KB; just assert we got well past the buffer.
        #expect((data?.count ?? 0) > 100_000)
    }

    @Test("returns nil on non-zero exit")
    func failureExit() {
        #expect(ProcessRunner.capture("/bin/sh", ["-c", "exit 3"]) == nil)
    }
}

// MARK: - Update version comparison

@Suite("UpdateChecker version compare")
struct UpdateVersionTests {
    @Test("newer versions are detected, equal/older are not")
    func ordering() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        #expect(UpdateChecker.isNewer("1.1.10", than: "1.1.9"))   // numeric, not lexical
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.1.9", than: "1.1.9"))   // equal
        #expect(!UpdateChecker.isNewer("1.1.8", than: "1.1.9"))   // older
        #expect(UpdateChecker.isNewer("1.1.9", than: "1.1"))      // more components
        #expect(!UpdateChecker.isNewer("1.1", than: "1.1.0"))     // equal padded
    }
}

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

@Suite("DevReadyAlert")
struct DevReadyAlertTests {
    @Test("parses JSON payload")
    func json() throws {
        let data = Data("""
        {"id":"a1","title":"Done","subtitle":"Review","source":"Cursor","agent":"Composer","bundleId":"com.example.app"}
        """.utf8)
        let alert = try #require(DevReadyAlert.parse(from: data))
        #expect(alert.title == "Done")
        #expect(alert.subtitle == "Review")
        #expect(alert.source == "Cursor")
        #expect(alert.agent == "Composer")
        #expect(alert.bundleId == "com.example.app")
    }

    @Test("parses distributed notification userInfo")
    func userInfo() {
        let alert = DevReadyAlert.parse(userInfo: [
            "id": "job-1",
            "title": "Build complete",
            "subtitle": "All green",
            "source": "Terminal",
            "agent": "claude-code",
            "bundleId": "com.apple.Terminal"
        ])
        #expect(alert?.title == "Build complete")
        #expect(alert?.agent == "claude-code")
        #expect(alert?.bundleId == "com.apple.Terminal")
    }

    @Test("dev ready layout is wider than a single collapsed chip")
    func width() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let alert = DevReadyAlert(title: "Agent finished", agent: "Composer")
        let layout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [alert])
        #expect(layout.size.width >= NotchContentLayout.devReadyMinWidth)
        #expect(layout.size.width > metrics.notchWidth + 120)
    }

    @Test("dev ready layout grows with multiple agents")
    func layout() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let one = DevReadyAlert(title: "Agent finished", agent: "Composer")
        let two = [
            DevReadyAlert(title: "A", agent: "Composer"),
            DevReadyAlert(title: "B", agent: "claude-code"),
        ]
        let singleLayout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [one])
        let multiLayout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: two)
        #expect(multiLayout.size.height > singleLayout.size.height)
    }

    @Test("dev ready layout caps height for many agents")
    func cappedLayout() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let three = (1...3).map { DevReadyAlert(title: "Task \($0)", agent: "Agent \($0)") }
        let six = (1...6).map { DevReadyAlert(title: "Task \($0)", agent: "Agent \($0)") }
        let layout3 = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: three)
        let layout6 = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: six)
        #expect(layout3.size.height == layout6.size.height)
    }

    @Test("state queues multiple dev-ready alerts")
    @MainActor
    func queue() {
        let state = NotchState()
        state.enqueueDevReady([
            DevReadyAlert(id: "1", title: "One", agent: "A"),
            DevReadyAlert(id: "2", title: "Two", agent: "B"),
        ])
        #expect(state.devReadyAlerts.count == 2)
        state.removeDevReady(id: "1")
        #expect(state.devReadyAlerts.count == 1)
        #expect(state.devReadyAlerts.first?.agent == "B")
    }
}

@Suite("waitingLayout sizing")
struct WaitingLayoutTests {
    // `answerEnabled` is always passed explicitly: reading AppSettings.shared
    // would couple these to the developer's real UserDefaults, and mutating it
    // would write to them.
    private let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                       designExpandedWidth: 640, designExpandedHeight: 190,
                                       scale: 0.65, topGap: 10)
    private let waitingAlerts = [
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                      kind: .waiting, message: "Allow Bash?")
    ]

    @Test("a waiting alert with a message is taller than the finished peek")
    @MainActor func tallerThanFinished() {
        let waiting = NotchContentLayout
            .waitingLayout(metrics: metrics, alerts: waitingAlerts, answerEnabled: true).size.height
        let finished = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: waitingAlerts).size.height
        #expect(waiting > finished)
    }

    @Test("the extra height budgets every gap the row actually renders")
    @MainActor func extraMatchesRenderTree() {
        // 6 (outer VStack spacing) + 30 (2-line message) + 6+24+6 (button row).
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: true) == 72)
    }

    @Test("with answering off only the message is budgeted")
    @MainActor func noAnswerButtons() {
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: false) == 36)
    }

    @Test("an untargetable waiting alert gets no button allowance")
    @MainActor func untargetable() {
        let alerts = [DevReadyAlert(title: "proj", kind: .waiting, message: "Allow Bash?")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true) == 36)
    }

    @Test("finished-only alerts get no waiting allowance")
    @MainActor func finishedOnly() {
        let alerts = [DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true) == 0)
    }
}

@Suite("NowPlayingDisplayResolver")
struct NowPlayingDisplayResolverTests {
    @Test("streaming domain is not shown as artist")
    func streamingDomain() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Friends",
            artist: "vixsrc.to",
            album: nil,
            bundleIdentifier: "com.brave.Browser"
        )
        #expect(resolved?.title == "Friends")
        #expect(resolved?.artist == "")
    }

    @Test("album show name fills in when artist is a site")
    func episodeWithAlbum() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "The One Where Monica Gets a Roommate",
            artist: "streamsite.net",
            album: "Friends, Season 1",
            bundleIdentifier: "com.google.Chrome"
        )
        #expect(resolved?.title == "The One Where Monica Gets a Roommate")
        #expect(resolved?.artist == "Friends")
    }

    @Test("service name title promotes album movie name")
    func netflixTitleNoise() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Netflix",
            artist: "",
            album: "Inception",
            bundleIdentifier: "com.apple.Safari"
        )
        #expect(resolved?.title == "Inception")
    }

    @Test("combined show and episode title is split")
    func combinedTitle() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Breaking Bad - Ozymandias",
            artist: "netflix.com",
            album: nil,
            bundleIdentifier: "com.apple.Safari"
        )
        #expect(resolved?.title == "Ozymandias")
        #expect(resolved?.artist == "Breaking Bad")
    }

    @Test("music metadata is unchanged")
    func music() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "T-Shirt",
            artist: "Migos",
            album: "Culture II",
            mediaType: "MRMediaRemoteMediaTypeMusic"
        )
        #expect(resolved?.title == "T-Shirt")
        #expect(resolved?.artist == "Migos")
    }

    @Test("youtube keeps channel as artist")
    func youtube() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "WWDC Keynote",
            artist: "Apple",
            album: nil,
            bundleIdentifier: "com.google.Chrome"
        )
        #expect(resolved?.title == "WWDC Keynote")
        #expect(resolved?.artist == "Apple")
    }
}

// MARK: - TerminalReplyInjector (delivery core + targeting policy)

@Suite("TerminalReplyInjector")
struct TerminalReplyInjectorTests {
    private func alert(bundleId: String?) -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code", bundleId: bundleId)
    }

    @Test("canTarget requires a non-empty bundle id")
    func canTargetRule() {
        #expect(TerminalReplyInjector.canTarget(alert(bundleId: "com.googlecode.iterm2")))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: nil)))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: "")))
    }

    @Test("validate rejects empty text")
    func rejectsEmpty() {
        #expect(TerminalReplyInjector.validate(text: "   ", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == .emptyText)
    }

    @Test("validate rejects missing target")
    func rejectsNoTarget() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: nil,
            isRunning: true, accessibilityGranted: true) == .noTarget)
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "",
            isRunning: true, accessibilityGranted: true) == .noTarget)
    }

    @Test("validate rejects when target app not running")
    func rejectsNotRunning() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: false, accessibilityGranted: true) == .targetNotRunning)
    }

    @Test("validate rejects when accessibility denied")
    func rejectsAccessibility() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: false) == .accessibilityDenied)
    }

    @Test("validate passes when all preconditions met")
    func passes() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == nil)
    }
}

// MARK: - NotchState reply compose

@MainActor
@Suite("NotchState reply compose")
struct NotchStateReplyTests {
    private func alert() -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code",
                      bundleId: "com.googlecode.iterm2")
    }

    @Test("beginReply opens composer targeting the alert")
    func begins() {
        let s = NotchState()
        s.beginReply(to: alert())
        #expect(s.replyCompose?.targetAlert.title == "proj")
        #expect(s.replyCompose?.draft == "")
    }

    @Test("updateReplyDraft records text and clears prior error")
    func updates() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.setReplyError("boom")
        s.updateReplyDraft("hello")
        #expect(s.replyCompose?.draft == "hello")
        #expect(s.replyCompose?.errorText == nil)
    }

    @Test("cancelReply clears the composer")
    func cancels() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.cancelReply()
        #expect(s.replyCompose == nil)
    }

    @Test("mutators no-op when composer is closed")
    func noopWhenClosed() {
        let s = NotchState()
        s.updateReplyDraft("x")
        s.setReplyError("y")
        #expect(s.replyCompose == nil)
    }
}

@Suite("DevReadyAlert kind/message")
struct DevReadyAlertKindTests {
    @Test("legacy JSON without kind decodes as .finished, no message")
    func legacyDecodes() {
        let data = #"{"id":"a","title":"proj","subtitle":"finished","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a != nil)
        #expect(a?.kind == .finished)
        #expect(a?.message == nil)
    }

    @Test("waiting JSON decodes kind + message")
    func waitingDecodes() {
        let data = #"{"id":"b","title":"proj","kind":"waiting","message":"Claude needs permission to run Bash","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a?.kind == .waiting)
        #expect(a?.message == "Claude needs permission to run Bash")
    }

    @Test("unknown kind falls back to .finished")
    func unknownKind() {
        let data = #"{"id":"c","title":"proj","kind":"bogus"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: data)?.kind == .finished)
    }

    @Test("userInfo path reads kind + message")
    func userInfoDecodes() {
        let a = DevReadyAlert.parse(userInfo: ["title":"proj","kind":"waiting","message":"pick one"])
        #expect(a?.kind == .waiting)
        #expect(a?.message == "pick one")
    }
}

@MainActor @Suite("NotchState waiting peeks")
struct NotchStateWaitingTests {
    private func waiting(_ msg: String, bundle: String = "com.apple.Terminal",
                         project: String = "proj") -> DevReadyAlert {
        DevReadyAlert(title: project, bundleId: bundle, kind: .waiting, message: msg)
    }
    @Test("a new waiting alert replaces a prior waiting alert for the same session")
    func replacesPerSession() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1"))
        s.enqueueWaiting(waiting("q2"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 1)
        #expect(waits.first?.message == "q2")
    }
    @Test("waiting alerts for different terminal apps coexist")
    func differentTerminals() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", bundle: "com.apple.Terminal"))
        s.enqueueWaiting(waiting("q2", bundle: "com.googlecode.iterm2"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 2)
    }
    @Test("two projects in the same terminal app coexist (replace key includes title)")
    func sameBundleDifferentProject() {
        // Two Claude Code sessions in two iTerm windows share the bundle id;
        // keying on bundleId alone would let one project clobber the other.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", bundle: "com.googlecode.iterm2", project: "NotchPill"))
        s.enqueueWaiting(waiting("q2", bundle: "com.googlecode.iterm2", project: "fleetmap"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 2)
        #expect(waits.map(\.message) == ["q1", "q2"])
    }
    @Test("a finished ping supersedes that session's waiting peek")
    func finishedSupersedesOwnSession() {
        // Waiting peeks never auto-dismiss, so the finished ping is what retires
        // them: once the agent reports done it is no longer blocked, and leaving
        // the peek up would offer to type `y` into a terminal that moved on.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?"))
        s.enqueueDevReady([DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.isEmpty)
        #expect(s.devReadyAlerts.count == 1)
    }
    @Test("a finished ping leaves another session's waiting peek alone")
    func finishedSparesOtherSession() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", project: "NotchPill"))
        s.enqueueDevReady([DevReadyAlert(title: "fleetmap", bundleId: "com.apple.Terminal")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }
    @Test("clearAll drops waiting peeks where the finished sweep spares them")
    func clearAllVsFinishedSweep() {
        // The pair's contract: the fade timer must never take a waiting peek,
        // but an explicit ✕/Escape must.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?"))
        s.enqueueDevReady([DevReadyAlert(title: "other", bundleId: "com.apple.Terminal")])
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.map(\.kind) == [.waiting])
        s.clearAllDevReady()
        #expect(s.devReadyAlerts.isEmpty)
    }
    @Test("an on-screen waiting peek demotes once it ages past the stale window")
    func staleWaitingDemotes() {
        // The ingest check can't cover this: a waiting peek never fades, so the
        // one on screen is what sits there while the terminal moves on.
        let s = NotchState()
        let now = Date()
        var old = waiting("Allow Bash?")
        old.createdAt = now.timeIntervalSince1970 - (DevReadyProvider.waitingStaleAfter + 60)
        s.enqueueWaiting(old)
        #expect(s.demoteStaleWaiting(now: now))
        #expect(s.devReadyAlerts.map(\.kind) == [.finished])
        #expect(!s.demoteStaleWaiting(now: now))   // idempotent
    }
    @Test("a fresh waiting peek is left alone by the stale sweep")
    func freshWaitingSurvives() {
        let s = NotchState()
        let now = Date()
        var fresh = waiting("Allow Bash?")
        fresh.createdAt = now.timeIntervalSince1970 - 5
        s.enqueueWaiting(fresh)
        #expect(!s.demoteStaleWaiting(now: now))
        #expect(s.devReadyAlerts.map(\.kind) == [.waiting])
    }
    @Test("removeDevReady clears a waiting alert (answered)")
    func answeredClears() {
        let s = NotchState()
        let a = waiting("q1")
        s.enqueueWaiting(a)
        s.removeDevReady(id: a.id)
        #expect(s.devReadyAlerts.isEmpty)
    }
    @Test("a finished ping's dismiss sweep leaves a waiting peek standing")
    func finishedSweepSparesWaiting() {
        // `dismissDevReady`'s auto-dismiss timer calls clearFinishedDevReady, so a
        // finished ping from terminal B must not erase terminal A's blocked question.
        let s = NotchState()
        let blocked = waiting("Allow Bash?")
        s.enqueueWaiting(blocked)
        s.enqueueDevReady([DevReadyAlert(id: "fin", title: "other", subtitle: "finished")])
        #expect(s.devReadyAlerts.count == 2)
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.map(\.id) == [blocked.id])
    }
    @Test("clearFinishedDevReady empties the list when nothing is waiting")
    func finishedOnlyClearsFully() {
        let s = NotchState()
        s.enqueueDevReady([DevReadyAlert(id: "a", title: "one"), DevReadyAlert(id: "b", title: "two")])
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.isEmpty)
    }
}

@Suite("DevReadyDedup routing")
struct DevReadyDedupTests {
    @Test("a repeated finished ping inside the window is suppressed")
    func finishedSuppressed() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(a) == true)
    }
    @Test("a finished ping past the window is allowed again")
    func finishedExpires() {
        var dedup = DevReadyDedup()
        let now = Date()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a, now: now) == false)
        #expect(dedup.shouldSuppress(a, now: now.addingTimeInterval(13)) == false)
    }
    @Test("waiting alerts bypass the fingerprint dedup entirely")
    func waitingBypasses() {
        // Every question in a session shares the project|branch fingerprint —
        // "permission to use Bash" then "permission to use Write" 5s later would
        // be dropped, and the agent would hang with nothing on screen.
        var dedup = DevReadyDedup()
        let q1 = DevReadyAlert(title: "proj", subtitle: "waiting · main",
                               kind: .waiting, message: "use Bash?")
        let q2 = DevReadyAlert(title: "proj", subtitle: "waiting · main",
                               kind: .waiting, message: "use Write?")
        #expect(dedup.shouldSuppress(q1) == false)
        #expect(dedup.shouldSuppress(q2) == false)
    }
    @Test("a waiting alert does not poison the finished window")
    func waitingNotRecorded() {
        var dedup = DevReadyDedup()
        let waiting = DevReadyAlert(title: "proj", subtitle: "s", kind: .waiting)
        let finished = DevReadyAlert(title: "proj", subtitle: "s")
        #expect(dedup.shouldSuppress(waiting) == false)
        #expect(dedup.shouldSuppress(finished) == false)
    }
}

@Suite("stale waiting signals")
struct StaleWaitingTests {
    private func waiting(ageSeconds: TimeInterval?) -> DevReadyAlert {
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal", kind: .waiting,
                      message: "Allow Bash?",
                      createdAt: ageSeconds.map { Date().timeIntervalSince1970 - $0 })
    }
    @Test("a waiting signal older than the TTL is demoted to finished")
    func staleDemoted() {
        // Queued at 2pm while NotchPill was closed, delivered at 6pm: the answer
        // buttons would type `y⏎` into a terminal back at a shell prompt.
        let demoted = DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: 4 * 3600))
        #expect(demoted.kind == .finished)
        #expect(demoted.message == "Allow Bash?")   // still shown, just not answerable
    }
    @Test("a fresh waiting signal stays waiting")
    func freshKept() {
        #expect(DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: 10)).kind == .waiting)
    }
    @Test("a missing createdAt is treated as not stale")
    func missingTimestamp() {
        #expect(DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: nil)).kind == .waiting)
    }
    @Test("a finished alert is never touched")
    func finishedUntouched() {
        let old = DevReadyAlert(title: "proj", createdAt: 1)
        #expect(DevReadyProvider.demotingStaleWaiting(old).kind == .finished)
    }
    @Test("createdAt decodes from a number, a numeric string, or not at all")
    func createdAtDecoding() {
        let num = #"{"id":"a","title":"p","createdAt":1750000000}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: num)?.createdAt == 1_750_000_000)
        let str = #"{"id":"a","title":"p","createdAt":"1750000000"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: str)?.createdAt == 1_750_000_000)
        // Malformed / missing must never drop the alert.
        let bad = #"{"id":"a","title":"p","createdAt":"not-a-number"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: bad)?.createdAt == nil)
        #expect(DevReadyAlert.parse(from: bad)?.title == "p")
        let none = #"{"id":"a","title":"p"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: none)?.createdAt == nil)
        // userInfo path too.
        #expect(DevReadyAlert.parse(userInfo: ["title": "p", "createdAt": 1_750_000_000])?
            .createdAt == 1_750_000_000)
        #expect(DevReadyAlert.parse(userInfo: ["title": "p", "createdAt": "bogus"])?.createdAt == nil)
    }
}

// MARK: - AgentAnswer

@Suite("AgentAnswer")
struct AgentAnswerTests {
    @Test("keystrokes map correctly")
    func keystrokes() {
        #expect(AgentAnswer.yes.keystroke == "y")
        #expect(AgentAnswer.no.keystroke == "n")
        #expect(AgentAnswer.digit(2).keystroke == "2")
    }
    @Test("labels")
    func labels() {
        #expect(AgentAnswer.yes.label == "Yes")
        #expect(AgentAnswer.digit(3).label == "3")
    }
    @Test("standard set is Yes/No/1/2/3")
    func standard() {
        #expect(AgentAnswer.standardSet == [.yes, .no, .digit(1), .digit(2), .digit(3)])
    }
}
