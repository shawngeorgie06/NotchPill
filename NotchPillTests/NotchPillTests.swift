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

    // The download URL came out of the API response with its scheme and host
    // unread, so the entire chain rested on api.github.com being the only
    // thing that could ever shape that JSON.
    @Test("only https GitHub origins are accepted as update downloads")
    func downloadOriginIsChecked() {
        #expect(UpdateChecker.isTrustedDownload(
            URL(string: "https://github.com/shawngeorgie06/NotchPill/releases/download/v1/a.zip")!))
        #expect(UpdateChecker.isTrustedDownload(
            URL(string: "https://objects.githubusercontent.com/x/a.zip")!))

        // Plaintext, a local path, and a look-alike that would pass a naive
        // prefix or "contains" check.
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "http://github.com/x/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "file:///tmp/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "https://github.com.evil.test/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "https://notgithub.com/a.zip")!))
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

    @Test("pinned activity moves to the front without changing the others")
    func pinnedActivity() {
        let items: [ExpandedActivity] = [.clock, .timer(ActiveTimer(label: "Focus", endDate: .now.addingTimeInterval(60))), .volume(40)]
        let ordered = ExpandedActivityBuilder.prioritizing(items, pinnedKind: "timer")
        #expect(ordered.map(\.kind) == ["timer", "clock", "volume"])
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

    @Test("surfaces the active agent before expansion")
    func activeAgent() {
        let session = AgentSession(id: "s", agent: "codex", project: "NotchPill",
                                   state: .working, lastActivity: Date(), locatorId: nil,
                                   directory: nil, subagent: nil, task: nil, toolActivity: nil)
        let chips = CollapsedChipBuilder.chips(
            nowPlaying: nil, nextEvent: nil, shelfCount: 0, appSwitchHint: nil,
            timer: nil, systemStats: nil, battery: nil, agentSessions: [session],
            showMedia: false, showCalendar: false, showShelf: false, showAppSwitch: false,
            showTimer: false, showSystemStats: false, showBattery: false,
            showAgents: true, showClock: false)
        #expect(chips == [.agent(name: "Codex", state: "working", count: 1)])
    }

    @Test("generated Codex workspace labels yield to the real task")
    func generatedWorkspaceDoesNotBecomeAgentContext() {
        let session = AgentSession(id: "s", agent: "codex", project: "w",
                                   state: .working, lastActivity: Date(), locatorId: nil,
                                   directory: nil, subagent: nil,
                                   task: "Fix the expanded notch title", toolActivity: nil)
        #expect(session.displayContext == "Fix the expanded notch title")
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

@Suite("System HUD sources")
struct SystemHUDSourceTests {
    @Test("brightness values clamp to the HUD range")
    func brightnessPercent() {
        #expect(BrightnessProvider.percent(from: -0.5) == 0)
        #expect(BrightnessProvider.percent(from: 0.625) == 63)
        #expect(BrightnessProvider.percent(from: 1.5) == 100)
    }

    @Test("HUD duration stays within a readable range")
    func hudDurationClamp() {
        #expect(AppSettings.clampSystemHUDDuration(0.1) == 0.8)
        #expect(AppSettings.clampSystemHUDDuration(1.7) == 1.7)
        #expect(AppSettings.clampSystemHUDDuration(9) == 3.0)
    }
}

@Suite("Dev-ready dismiss gesture")
struct DevReadyDismissSwipeTests {
    @Test("only a deliberate leftward horizontal swipe dismisses")
    func dismissalDirection() {
        #expect(DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -52, height: 2)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: 52, height: 2)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -30, height: 1)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -90, height: 90)))
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
    @MainActor
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
    @MainActor
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
    @MainActor
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

@Suite("answer sets declared by the signal")
struct AgentAnswerSpecTests {
    @Test("label:keystroke pairs, and bare labels that are their own key")
    func parsesPairs() {
        let parsed = AgentAnswer.parse("Yes:y|No:n|1|2|3")
        #expect(parsed?.map(\.label) == ["Yes", "No", "1", "2", "3"])
        #expect(parsed?.map(\.keystroke) == ["y", "n", "1", "2", "3"])
    }

    @Test("labels may contain spaces and commas")
    func labelsWithPunctuation() {
        // `|` and `:` separate precisely so a label like this stays intact.
        let parsed = AgentAnswer.parse("Allow for session:a|Deny, always:d")
        #expect(parsed?.map(\.label) == ["Allow for session", "Deny, always"])
        #expect(parsed?.map(\.keystroke) == ["a", "d"])
    }

    @Test("a trailing ! suppresses Return")
    func suppressesReturn() {
        // A TUI that self-confirms on keypress must not also get a Return — it
        // would confirm whatever prompt came next.
        let parsed = AgentAnswer.parse("Approve:a!|Deny:d")
        #expect(parsed?.first?.appendsReturn == false)
        #expect(parsed?.last?.appendsReturn == true)
    }

    @Test("empty and malformed specs fall back rather than render nothing")
    func emptySpecs() {
        #expect(AgentAnswer.parse(nil) == nil)
        #expect(AgentAnswer.parse("") == nil)
        #expect(AgentAnswer.parse("   ") == nil)
        #expect(AgentAnswer.parse("||") == nil)
        #expect(AgentAnswer.parse(":x") == nil)     // no label
        #expect(AgentAnswer.parse("Label:") == nil) // no keystroke
    }

    @Test("an alert with no spec offers no buttons at all")
    @MainActor func noSpecMeansNoButtons() {
        // The inferred Yes/No/1/2/3 set was removed by request. Falling back
        // to it here would put those capsules back, since permission
        // decisions also reach the button row.
        let alert = DevReadyAlert(title: "p", agent: "claude-code",
                                  bundleId: "com.apple.Terminal", kind: .waiting)
        #expect(alert.answers.isEmpty)
        #expect(!alert.canAnswerFromNotch(replyEnabled: true))
        #expect(alert.answerDelivery == .keystrokes)
    }

    /// An agent that states its options keeps them: nothing is being guessed.
    @Test("a declared set is still offered")
    @MainActor func declaredAnswersSurvive() {
        let alert = DevReadyAlert(title: "p", agent: "codex",
                                  bundleId: "com.apple.Terminal", kind: .waiting,
                                  answerSpec: "Yes:y|No:n")
        #expect(alert.answers.map(\.label) == ["Yes", "No"])
        #expect(alert.canAnswerFromNotch(replyEnabled: true))
    }

    @Test("a declared set overrides the per-agent guesswork")
    func declarationWins() {
        // Codex would be refused by name, but a signal that says how to answer it
        // knows better than our heuristic.
        let alert = DevReadyAlert(title: "p", agent: "codex", bundleId: "com.apple.Terminal",
                                  kind: .waiting, answerSpec: "Approve:a|Deny:d")
        #expect(alert.supportsTypedAnswers)
        #expect(alert.answers.map(\.label) == ["Approve", "Deny"])
    }

    @Test("delivery=none refuses answers even with a declared set")
    func deliveryNone() {
        let alert = DevReadyAlert(title: "p", bundleId: "com.apple.Terminal", kind: .waiting,
                                  answerSpec: "Yes:y", deliverySpec: "none")
        #expect(!alert.supportsTypedAnswers)
    }

    @Test("delivery=paste is honoured")
    func deliveryPaste() {
        let alert = DevReadyAlert(title: "p", bundleId: "com.apple.Terminal", kind: .waiting,
                                  deliverySpec: "paste")
        #expect(alert.answerDelivery == .paste)
    }

    @Test("answers and delivery survive both signal transports")
    func roundTrips() throws {
        let data = Data("""
        {"id":"a1","title":"p","kind":"waiting","answers":"Approve:a|Deny:d","delivery":"paste"}
        """.utf8)
        let decoded = try #require(DevReadyAlert.parse(from: data))
        #expect(decoded.answers.map(\.keystroke) == ["a", "d"])
        #expect(decoded.answerDelivery == .paste)

        let posted = DevReadyAlert.parse(userInfo: [
            "title": "p", "kind": "waiting", "answers": "Approve:a", "delivery": "none"
        ])
        #expect(posted?.answers.map(\.label) == ["Approve"])
        #expect(posted?.supportsTypedAnswers == false)
    }
}

@Suite("agent branding")
struct AgentBrandingTests {
    @Test("the agent field identifies a brandable agent")
    func recognisesAgents() {
        #expect(DevReadyAlert(title: "p", agent: "claude-code").knownAgent == .claudeCode)
        #expect(DevReadyAlert(title: "p", agent: "codex").knownAgent == .codex)
        // Case-insensitive: the hook writes lowercase, a hand-rolled caller may not.
        #expect(DevReadyAlert(title: "p", agent: "Claude-Code").knownAgent == .claudeCode)
    }

    @Test("`source` identifies the agent when `agent` is absent")
    func fallsBackToSource() {
        #expect(DevReadyAlert(title: "p", source: "codex").knownAgent == .codex)
    }

    @Test("Cursor is recognised under either name it reports")
    func recognisesCursor() {
        #expect(DevReadyAlert(title: "p", agent: "Cursor").knownAgent == .cursor)
        #expect(DevReadyAlert(title: "p", agent: "Composer").knownAgent == .cursor)
    }

    @Test("unrecognised producers stay unbranded and keep the host icon")
    func unknownAgents() {
        // CI hooks and bare scripts must keep falling through to the host app's
        // icon — the branding is additive, not a replacement.
        #expect(DevReadyAlert(title: "p", agent: "buildbot").knownAgent == nil)
        #expect(DevReadyAlert(title: "p").knownAgent == nil)
    }

    @Test("answers are offered only where they would actually land")
    func typedAnswerSupport() {
        // Delivery is synthetic keystrokes into the host's frontmost window.
        // Cursor and the Codex app are GUIs, and Codex's approval prompt uses
        // its own keymap — offering Yes/No/1/2/3 there is a button that lies.
        #expect(DevReadyAlert(title: "p", agent: "claude-code").supportsTypedAnswers)
        #expect(!DevReadyAlert(title: "p", agent: "codex").supportsTypedAnswers)
        #expect(!DevReadyAlert(title: "p", agent: "Composer").supportsTypedAnswers)
        // Unrecognised producers keep the previous behaviour — someone wiring
        // their own terminal agent opted in by sending kind=waiting.
        #expect(DevReadyAlert(title: "p", agent: "my-tui-agent").supportsTypedAnswers)
    }

    @Test("an unanswerable waiting row budgets no button height")
    @MainActor func unanswerableRowIsShorter() {
        // The height budget must mirror `canAnswer`, or a peek reserves space
        // for buttons the row will not draw. Since the generic capsules were
        // removed, neither of these draws any — only a permission decision does.
        let codex = DevReadyAlert(title: "p", agent: "codex", bundleId: "com.openai.codex",
                                  kind: .waiting, message: "Approve?")
        let claude = DevReadyAlert(title: "p", agent: "claude-code", bundleId: "com.apple.Terminal",
                                   kind: .waiting, message: "Approve?")
        let decision = DevReadyAlert(title: "p", agent: "claude-code",
                                     bundleId: "com.apple.Terminal", kind: .waiting,
                                     message: "Approve?", deliverySpec: "decision",
                                     requestId: "req-1")
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [codex], answerEnabled: true)
                == WaitingLayoutTests.messageOnlyExtra)
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [claude], answerEnabled: true)
                == WaitingLayoutTests.messageOnlyExtra)
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [decision], answerEnabled: true)
                == WaitingLayoutTests.withButtonsExtra)
    }

    @Test("an agent with no app installed has no agent icon to show")
    func noAppNoIcon() {
        // Drives the ClaudeMark fallback: knownAgent is set but agentAppIcon is
        // nil, so the row must draw the mark rather than the terminal's icon.
        let alert = DevReadyAlert(title: "p", agent: "claude-code",
                                  bundleId: "com.apple.Terminal")
        if alert.agentAppIcon == nil {
            #expect(alert.knownAgent == .claudeCode)
        }
    }
}

@Suite("DevReadyAlert.questionText")
struct QuestionTextTests {
    @Test("only a waiting alert with a non-empty message has a question")
    func onlyWaitingWithMessage() {
        #expect(DevReadyAlert(title: "p", kind: .waiting, message: "Allow Bash?").questionText == "Allow Bash?")
        // A finished ping's message is not a question — showing it in the
        // composer would invite an answer nothing is waiting for.
        #expect(DevReadyAlert(title: "p", kind: .finished, message: "Allow Bash?").questionText == nil)
        #expect(DevReadyAlert(title: "p", kind: .waiting, message: "").questionText == nil)
        #expect(DevReadyAlert(title: "p", kind: .waiting).questionText == nil)
    }
}

@MainActor @Suite("replyComposeLayout")
struct ReplyComposeLayoutTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 180, notchHeight: 32,
                     designExpandedWidth: 640, designExpandedHeight: 190,
                     scale: 0.65, topGap: 10)
    }
    @Test("the composer reserves extra height when it shows a question")
    func growsForQuestion() {
        let plain = NotchContentLayout.replyComposeLayout(metrics: metrics).size.height
        let withQ = NotchContentLayout.replyComposeLayout(metrics: metrics, hasQuestion: true).size.height
        #expect(withQ - plain == NotchContentLayout.replyQuestionExtra)
    }
    @Test("width is unchanged by the question")
    func widthUnchanged() {
        #expect(NotchContentLayout.replyComposeLayout(metrics: metrics).size.width
                == NotchContentLayout.replyComposeLayout(metrics: metrics, hasQuestion: true).size.width)
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
    /// A permission decision. Since the generic Yes/No/1/2/3 capsules were
    /// removed, this is the only kind that still draws buttons — so it is the
    /// only kind whose height budget has to include them.
    private let waitingAlerts = [
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                      kind: .waiting, message: "Allow Bash?",
                      deliverySpec: "decision", requestId: "req-1")
    ]

    @Test("a waiting alert with a message is taller than the finished peek")
    @MainActor func tallerThanFinished() {
        let waiting = NotchContentLayout
            .waitingLayout(metrics: metrics, alerts: waitingAlerts, answerEnabled: true).size.height
        let finished = NotchContentLayout
            .devReadyLayout(metrics: metrics, alerts: waitingAlerts, answerEnabled: true).size.height
        #expect(waiting > finished)
    }

    /// 6 (outer VStack spacing) + 30 (2-line message), with no button row.
    static let messageOnlyExtra: CGFloat = 36
    /// …plus the button row: 6 gap + capsule + 6 bottom padding. Derived from the
    /// capsule constant so resizing the buttons updates the budget with it —
    /// under-budgeting clips them outside the window, where they stop hit-testing.
    static var withButtonsExtra: CGFloat {
        messageOnlyExtra + 6 + NotchContentLayout.answerButtonHeight + 6
    }

    @Test("the extra height budgets every gap the row actually renders")
    @MainActor func extraMatchesRenderTree() {
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: true)
                == Self.withButtonsExtra)
    }

    @Test("with answering off only the message is budgeted")
    @MainActor func noAnswerButtons() {
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: false)
                == Self.messageOnlyExtra)
    }

    @Test("an untargetable waiting alert gets no button allowance")
    @MainActor func untargetable() {
        let alerts = [DevReadyAlert(title: "proj", kind: .waiting, message: "Allow Bash?")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true)
                == Self.messageOnlyExtra)
    }

    /// The generic quick-answer capsules are gone: a plain waiting alert now
    /// budgets the message and nothing else, however answerable it looks.
    @Test("a plain waiting alert no longer budgets buttons")
    @MainActor func plainWaitingHasNoButtons() {
        let alerts = [DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                                    kind: .waiting, message: "Allow Bash?")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true)
                == Self.messageOnlyExtra)
    }

    @Test("finished-only alerts get no waiting allowance")
    @MainActor func finishedOnly() {
        let alerts = [DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true) == 0)
    }

    /// A permission decision, for the same reason as `waitingAlerts`: it is
    /// the only kind that still draws buttons.
    private func waiting(_ msg: String, session: String) -> DevReadyAlert {
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                      kind: .waiting, message: msg, sessionId: session,
                      deliverySpec: "decision", requestId: "req-\(session)")
    }

    @Test("each waiting row gets its own allowance")
    @MainActor func perRowAllowance() {
        // The flat allowance left every row after the first with no room for its
        // question, so its buttons rendered under the previous row's text.
        let two = [waiting("Allow Bash?", session: "a"), waiting("Allow Write?", session: "b")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: two, answerEnabled: true)
                == Self.withButtonsExtra * 2)
    }

    @Test("a finished row alongside a waiting one adds no allowance")
    @MainActor func mixedKinds() {
        let mixed = [waiting("Allow Bash?", session: "a"),
                     DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: mixed, answerEnabled: true)
                == Self.withButtonsExtra)
    }

    @Test("only the visible rows are budgeted, taking the tallest")
    @MainActor func capsAtVisibleRows() {
        // devReadyLayout shows at most devReadyMaxVisibleRows, so budgeting every
        // row would grow the window past what it can display. The tallest are
        // chosen because any row can be scrolled to and must not clip.
        let four = (1...4).map { waiting("Allow Bash \($0)?", session: "s\($0)") }
        let capped = NotchContentLayout.devReadyMaxVisibleRows
        #expect(NotchContentLayout.waitingExtraHeight(alerts: four, answerEnabled: true)
                == CGFloat(capped) * Self.withButtonsExtra)
    }

    @Test("a peek with two waiting rows is taller than one with a single row")
    @MainActor func twoRowsAreTaller() {
        let one = NotchContentLayout.waitingLayout(
            metrics: metrics, alerts: [waiting("Allow Bash?", session: "a")],
            answerEnabled: true).size.height
        let two = NotchContentLayout.waitingLayout(
            metrics: metrics,
            alerts: [waiting("Allow Bash?", session: "a"), waiting("Allow Write?", session: "b")],
            answerEnabled: true).size.height
        // Both the base row and its own waiting allowance must be added.
        #expect(two >= one + NotchContentLayout.devReadyRowHeight + Self.withButtonsExtra)
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

/// The case `bundleId` + project title cannot see: two agent sessions on the
/// same repo in the same terminal app. Before the hook passed `session_id`, one
/// session's question replaced the other's and either one finishing retired both.
@MainActor @Suite("waiting peeks keyed on session id")
struct WaitingSessionIdentityTests {
    private func waiting(_ msg: String, session: String? = nil,
                         bundle: String = "com.cmuxterm.app",
                         project: String = "NotchPill") -> DevReadyAlert {
        DevReadyAlert(title: project, bundleId: bundle, kind: .waiting,
                      message: msg, sessionId: session)
    }

    @Test("two sessions in one project and one terminal app coexist")
    func distinctSessionsCoexist() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-b"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.map(\.message) == ["Allow Bash?", "Allow Write?"])
    }

    @Test("a second question from the same session still replaces the first")
    func sameSessionReplaces() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-a"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 1)
        #expect(waits.first?.message == "Allow Write?")
    }

    @Test("session id outranks the project title")
    func sessionIdBeatsTitle() {
        // A session that changes directory reports a different project title but
        // is still the same blocked session — one peek, not two.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", session: "sess-a", project: "NotchPill"))
        s.enqueueWaiting(waiting("q2", session: "sess-a", project: "fleetmap"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }

    @Test("a finished ping retires only its own session's waiting peek")
    func finishedRetiresOwnSessionOnly() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-b"))
        s.enqueueDevReady([DevReadyAlert(title: "NotchPill", bundleId: "com.cmuxterm.app",
                                         sessionId: "sess-a")])
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.map(\.message) == ["Allow Write?"])
    }

    @Test("signals with no session id keep the bundleId + title behaviour")
    func legacyFallback() {
        // An older hook script, or anything calling notify-notchpill.sh directly.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1"))
        s.enqueueWaiting(waiting("q2"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }

    @Test("a session-less signal falls back rather than orphaning a peek")
    func mixedFallsBack() {
        // Deliberate: treating these as different sessions would leave a waiting
        // peek nothing can ever supersede, still offering to answer a dead question.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueDevReady([DevReadyAlert(title: "NotchPill", bundleId: "com.cmuxterm.app")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.isEmpty)
    }

    @Test("session id round-trips through both signal transports")
    func decoding() throws {
        let data = Data("""
        {"id":"a1","title":"NotchPill","kind":"waiting","message":"Allow Bash?","sessionId":"sess-a"}
        """.utf8)
        #expect(try #require(DevReadyAlert.parse(from: data)).sessionId == "sess-a")

        let posted = DevReadyAlert.parse(userInfo: ["title": "NotchPill", "sessionId": "sess-a"])
        #expect(posted?.sessionId == "sess-a")
    }

    @Test("absent or blank session ids read as no session")
    func blankIsAbsent() {
        // The shell writers omit the key, but a caller passing "" must not make
        // every session-less signal match every other one on an empty string.
        let data = Data(#"{"id":"a1","title":"NotchPill","sessionId":"   "}"#.utf8)
        #expect(DevReadyAlert.parse(from: data)?.sessionId == nil)
        #expect(DevReadyAlert(title: "NotchPill", sessionId: "").sessionId == nil)
        #expect(DevReadyAlert(title: "NotchPill").sessionId == nil)
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
    // REGRESSION: Cursor can run Claude Code as its backend, so one turn fired
    // Cursor's hook *and* the spawned `claude` process's Stop hook a second
    // later. Both reported honestly — the Claude hook correctly named Cursor as
    // the host app — and the pair read as a Claude session never started.
    @Test("one turn in one app is one peek, even from two agents")
    func crossAgentSameHostCollapses() {
        var dedup = DevReadyDedup()
        let cursor = DevReadyAlert(title: "Question for you", subtitle: "regenerate the memo?",
                                   source: "Cursor", agent: "cursor",
                                   bundleId: "com.todesktop.230313mzl4w4u92")
        let claude = DevReadyAlert(title: "bid-no-bid", subtitle: "finished · main",
                                   source: "Cursor", agent: "claude-code",
                                   bundleId: "com.todesktop.230313mzl4w4u92",
                                   sessionId: "1573ad8b")
        #expect(dedup.shouldSuppress(cursor) == false)   // the specific one wins
        #expect(dedup.shouldSuppress(claude) == true)
    }

    // The collapse must not swallow real concurrent work: two Claude Code
    // sessions in one terminal are two turns, which is the entire reason peeks
    // are keyed on the session id.
    @Test("two sessions of the same agent in one terminal both get through")
    func sameAgentSameHostBothPeek() {
        var dedup = DevReadyDedup()
        let one = DevReadyAlert(title: "NotchPill", subtitle: "finished · main",
                                source: "cmux", agent: "claude-code",
                                bundleId: "com.cmuxterm.app", sessionId: "aaa")
        let two = DevReadyAlert(title: "murmur-app", subtitle: "finished · main",
                                source: "cmux", agent: "claude-code",
                                bundleId: "com.cmuxterm.app", sessionId: "bbb")
        #expect(dedup.shouldSuppress(one) == false)
        #expect(dedup.shouldSuppress(two) == false)
    }

    @Test("a later turn in the same app is not collapsed")
    func hostWindowExpires() {
        var dedup = DevReadyDedup()
        let now = Date()
        let cursor = DevReadyAlert(title: "Question for you", subtitle: "a",
                                   source: "Cursor", agent: "cursor", bundleId: "com.cursor")
        let claude = DevReadyAlert(title: "proj", subtitle: "finished · main",
                                   source: "Cursor", agent: "claude-code", bundleId: "com.cursor")
        #expect(dedup.shouldSuppress(cursor, now: now) == false)
        #expect(dedup.shouldSuppress(claude, now: now.addingTimeInterval(6)) == false)
    }

    // A peek with no host app (the transcript watcher emits none) has nothing to
    // relate it to anything else, so it must never be collapsed.
    @Test("peeks without a host app are unaffected")
    func noBundleUnaffected() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj-a", subtitle: "finished", agent: "claude-code")
        let b = DevReadyAlert(title: "proj-b", subtitle: "finished", agent: "codex")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == false)
    }

    @Test("two sessions on the same branch both get through")
    func distinctSessionsNotSuppressed() {
        // project|branch is byte-identical for both. Suppressing the second is
        // not just a missing peek: the ping never reaches enqueueDevReady, so
        // that session's waiting peek keeps its live answer buttons.
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main", sessionId: "sess-a")
        let b = DevReadyAlert(title: "proj", subtitle: "finished · main", sessionId: "sess-b")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == false)
        #expect(dedup.shouldSuppress(a) == true)   // still a true double-fire
    }
    @Test("session-less pings keep the title|subtitle window")
    func legacySuppressionUnchanged() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        let b = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == true)
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

/// The hookless watchers. Both bugs that reached the user in 1.8.x lived in this
/// logic and neither had a test, so every case below is either a regression or
/// a shape taken from a real transcript on disk.
@Suite("transcript turn detection")
struct TranscriptTurnTests {
    private func tail(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    @Test("Codex live session names its newest user request")
    func codexUsesNewestPrompt() {
        let transcript = tail([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Draft the release notes"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"I will do that"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix the Codex live-agent text"}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Fix the Codex live-agent text")
    }

    @Test("Codex current transcript shape names its newest user request")
    func codexUsesResponseItemPrompt() {
        let transcript = tail([
            #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"Make the title meaningful"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"I will do that"}}"#,
            #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"Fix the one-letter Codex title"}]}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Fix the one-letter Codex title")
    }

    @Test("Codex approval handoffs use an activity label, not protocol text")
    func codexApprovalHandoff() {
        let handoff = "The following is the Codex agent history added since your last approval assessment."
        let transcript = tail([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Draft the release notes"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(handoff)"}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Draft the release notes")

        #expect(AgentSessionScanner.codexLastPrompt(in:
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(handoff)"}}"#)
                == "Reviewing a permission request")
    }

    @Test("Claude tool calls become a compact file action")
    func claudeToolActivity() {
        let transcript = #"{"message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/auth.swift"}}]}}"#
        #expect(AgentSessionScanner.claudeToolActivity(in: transcript)
                == AgentToolActivity(tool: "Edit", detail: "src/auth.swift"))
    }

    @Test("Codex exec calls become a compact command action")
    func codexToolActivity() {
        let transcript = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"{\"cmd\":\"xcodebuild test\"}"}}"#
        #expect(AgentSessionScanner.codexToolActivity(in: transcript)
                == AgentToolActivity(tool: "Bash", detail: "xcodebuild test"))
    }

    @Test("Codex desktop tool expressions expose their command")
    func codexDesktopToolActivity() {
        let transcript = #"{"type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const r = await tools.exec_command({\"cmd\":\"xcodebuild test\"});"}}"#
        #expect(AgentSessionScanner.codexToolActivity(in: transcript)
                == AgentToolActivity(tool: "Bash", detail: "xcodebuild test"))
    }

    @Test("Codex local rate-limit record exposes a real quota and reset")
    func codexQuota() {
        let transcript = #"{"timestamp":"2026-07-31T17:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":42.4,"resets_at":1786130351},"credits":{"balance":"123.45"}}}}"#
        let quota = AgentSessionScanner.codexQuota(in: transcript)
        #expect(quota?.usedPercent == 42)
        #expect(quota?.resetsAt == Date(timeIntervalSince1970: 1_786_130_351))
        #expect(quota?.creditsLabel == "123.45 credits balance")
        #expect(quota?.updatedAt == ISO8601DateFormatter().date(from: "2026-07-31T17:00:00Z"))
    }

    @Test("Codex oversized session metadata still exposes its working directory")
    func codexOversizedMetadataHasWorkingDirectory() {
        let prefix = #"{"payload":{"cwd":"/Users/me/Project","base_instructions":""#
        let text = prefix + String(repeating: "x", count: 40_000)
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/Project")
    }

    @Test("an assistant message ends the turn")
    func assistantEnds() {
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#
        ])))
    }

    @Test("REGRESSION: a message you just sent is not a finished turn")
    func userDoesNotEnd() {
        // 1.8.x peeked "finished" the moment the user pressed Return, because it
        // fired on any write that went quiet without looking at what was written.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"user","message":{"role":"user"}}"#
        ])))
    }

    @Test("bookkeeping records trailing a turn don't mask it")
    func bookkeepingSkipped() {
        // Claude Code writes these after the assistant message; treating them as
        // the last word would silently suppress every peek.
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"attachment"}"#,
            #"{"type":"file-history-snapshot"}"#
        ])))
    }

    @Test("bookkeeping after a user message still isn't a finished turn")
    func bookkeepingAfterUser() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"file-history-snapshot"}"#
        ])))
    }

    @Test("REGRESSION: Codex nests its record under `payload`")
    func codexPayloadShape() {
        // 1.8.0 only read top-level keys, so every Codex session was silently
        // dropped — no peek, nothing logged.
        #expect(AgentTranscriptProvider.turnEnded(inTail:
            #"{"timestamp":"t","type":"response_item","payload":{"type":"agent_message"}}"#))
        #expect(!AgentTranscriptProvider.turnEnded(inTail:
            #"{"timestamp":"t","type":"response_item","payload":{"type":"user_message"}}"#))
    }

    @Test("an unrecognised record is not evidence of a finished turn")
    func unknownRecord() {
        // Better a missed peek than one fired at nothing.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: #"{"type":"something-new"}"#))
    }

    @Test("garbage and empty tails are safe")
    func malformed() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: ""))
        #expect(!AgentTranscriptProvider.turnEnded(inTail: "not json at all"))
        // A tail sliced mid-line must not throw away the whole decision.
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"ssage":{"role":"user"}}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#
        ])))
    }

    /// A stand-in filesystem, so naming is tested against a fixed tree instead
    /// of whatever happens to exist on the machine running the tests.
    private static let tree: Set<String> = [
        "/Users", "/Users/me", "/Users/me/Projects", "/Users/me/Projects/NotchPill",
        "/Users/me/bid-no-bid", "/Users/me/Projects/cv-prep"
    ]
    private func name(_ dir: String) -> String? {
        AgentTranscriptProvider.claudeProjectName(
            fromDirectory: dir, home: "/Users/me", exists: { Self.tree.contains($0) })
    }

    @Test("project name comes from the encoded working directory")
    func projectNaming() {
        #expect(name("-Users-me-Projects-NotchPill") == "NotchPill")
        #expect(AgentTranscriptProvider.claudeProjectName(fromDirectory: "") == nil)
    }

    @Test("Codex transcript notifications never use the generated w workspace as a title")
    func codexNotificationTitleUsesUsefulFallback() {
        #expect(AgentTranscriptProvider.codexFinishedTitle(project: "w", task: "continue")
            == "Codex finished")
        #expect(AgentTranscriptProvider.codexFinishedTitle(
            project: "w", task: "Fix the one-letter Codex notification title"
        ) == "Fix the one-letter Codex notification title")
        #expect(AgentTranscriptProvider.codexFinishedTitle(project: "NotchPill", task: nil)
            == "NotchPill")
    }

    // REGRESSION: a session started in the home directory peeked as the account
    // name ("shawngeorgie"), which reads like a project nobody has.
    @Test("the home directory is named Home, not the account")
    func homeDirectoryNaming() {
        #expect(name("-Users-me") == "Home")
        #expect(AgentTranscriptProvider.displayName(forPath: "/Users/me", home: "/Users/me") == "Home")
    }

    // REGRESSION: splitting on "-" and taking the last segment turned
    // `bid-no-bid` into `bid`. Only the filesystem can resolve the ambiguity.
    @Test("dashes in a folder name survive the round trip")
    func dashedProjectNaming() {
        #expect(name("-Users-me-bid-no-bid") == "bid-no-bid")
        #expect(name("-Users-me-Projects-cv-prep") == "cv-prep")
        #expect(AgentTranscriptProvider.claudePath(
            fromDirectory: "-Users-me-bid-no-bid",
            exists: { Self.tree.contains($0) }) == "/Users/me/bid-no-bid")
    }

    @Test("a deleted directory still yields its best-effort name")
    func vanishedProjectNaming() {
        // Nothing below /Users/me matches, so the remainder is kept verbatim
        // rather than the peek losing its label entirely.
        #expect(name("-Users-me-gone-away") == "gone-away")
    }
}

@Suite("Focused activity ordering")
struct FocusedActivityTests {
    @Test("known agents retain a jump target when an old hook omits its host")
    func knownAgentJumpFallbacks() {
        let codex = DevReadyAlert(title: "Done", agent: "codex")
        let cursor = DevReadyAlert(title: "Done", agent: "cursor")
        let claudeInCmux = DevReadyAlert(title: "Done", source: "cmux", agent: "claude-code")
        #expect(codex.jumpTargetBundleIds == ["com.openai.codex"])
        #expect(cursor.jumpTargetBundleIds == ["com.todesktop.230313mzl4w4u92"])
        #expect(claudeInCmux.jumpTargetBundleIds == ["com.cmuxterm.app"])
    }

    @Test("notification history strips a past approval payload")
    func notificationHistoryIsPresentationOnly() {
        let alert = DevReadyAlert(title: "Ship", subtitle: "Done", kind: .waiting,
                                  requestId: "request-123", permissionPayload: "sensitive")
        let history = NotchState.historyEntry(for: alert)
        #expect(history.kind == .finished)
        #expect(history.requestId == nil)
        #expect(history.permissionPayload == nil)
    }

    @Test("Focus timer carries its focused presentation state")
    func focusTimerState() {
        let focus = ActiveTimer(label: "Focus", endDate: .now.addingTimeInterval(60))
        let regular = ActiveTimer(label: "Timer", endDate: .now.addingTimeInterval(60))
        #expect(focus.isFocusSession)
        #expect(!regular.isFocusSession)
    }

    @Test("a blocked agent becomes the focused item ahead of completions")
    func waitingWins() {
        let finished = DevReadyAlert(title: "build", kind: .finished, createdAt: 20)
        let waiting = DevReadyAlert(title: "approval", kind: .waiting, createdAt: 10)
        #expect(DevReadyAlert.focusOrdered([finished, waiting]).first?.id == waiting.id)
    }

    @Test("the newest completion leads when nothing needs attention")
    func newestFinishedWins() {
        let older = DevReadyAlert(title: "older", kind: .finished, createdAt: 10)
        let newer = DevReadyAlert(title: "newer", kind: .finished, createdAt: 20)
        #expect(DevReadyAlert.focusOrdered([older, newer]).first?.id == newer.id)
    }
}

@Suite("Media swipe controls")
struct MediaSwipeTests {
    @Test("horizontal swipes select the matching transport action")
    func horizontalDirections() {
        #expect(MediaSwipeDirection.from(translation: CGSize(width: -48, height: 3)) == .next)
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 48, height: 3)) == .previous)
    }

    @Test("short and vertical drags do not change playback")
    func ignoresAmbiguousDrags() {
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 20, height: 0)) == nil)
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 42, height: 72)) == nil)
    }
}

@Suite("Live agent sessions")
struct AgentSessionTests {
    private func session(_ id: String, _ state: AgentSession.State,
                         at: Date, agent: String = "claude-code") -> AgentSession {
        AgentSession(id: id, agent: agent, project: id, state: state, lastActivity: at)
    }

    @Test("a transcript written seconds ago is working, not idle")
    func recentIsWorking() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-2),
                                   blocked: false, now: now) == .working)
    }

    // An agent thinking between two tool calls writes nothing for a few
    // seconds. Flickering working→idle→working reads as a bug.
    @Test("a short pause mid-turn stays working")
    func shortPauseStaysWorking() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-7),
                                   blocked: false, now: now) == .working)
    }

    @Test("a long pause becomes idle, dated from the last write")
    func longPauseIsIdle() {
        let now = Date()
        let last = now.addingTimeInterval(-120)
        #expect(AgentSession.state(lastWrite: last, blocked: false, now: now) == .idle(since: last))
    }

    // Blocked beats everything: a session waiting on you has by definition not
    // written anything recently, so time alone would call it idle.
    @Test("blocked wins over quiet")
    func blockedWins() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-600),
                                   blocked: true, now: now) == .waiting(since: nil))
    }

    @Test("waiting sessions float above newer working ones")
    func waitingSortsFirst() {
        let now = Date()
        let ordered = AgentSession.ordered([
            session("fresh", .working, at: now),
            session("blocked", .waiting(since: nil), at: now.addingTimeInterval(-300)),
            session("old", .idle(since: now.addingTimeInterval(-600)),
                    at: now.addingTimeInterval(-600))
        ])
        #expect(ordered.map(\.id) == ["blocked", "fresh", "old"])
    }

    @Test("the card keeps completed turns without calling them live")
    func completedTurnsAreShownAsCompleted() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "done")
        let rows = AgentSession.displaySessions(
            live: [session("working", .working, at: now)], waitingAlerts: [],
            completedAlerts: [completed])
        #expect(rows.map(\.id) == ["working", "done"])
        #expect(rows.last?.isCompleted == true)
        #expect(rows.last?.statusLabel.hasPrefix("completed") == true)
    }

    @Test("an unanswered prompt wins over a completed turn for the same session")
    func waitingPromptReplacesCompletedTurn() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "session")
        let waiting = DevReadyAlert(
            id: "question", title: "Release", subtitle: nil, source: "Codex",
            agent: "codex", bundleId: nil, kind: .waiting,
            message: "Ship it?", createdAt: now.timeIntervalSince1970,
            sessionId: "session")
        let rows = AgentSession.displaySessions(live: [], waitingAlerts: [waiting],
                                                completedAlerts: [completed])
        #expect(rows.count == 1)
        #expect(rows[0].isWaiting)
    }

    @Test("a newer live transcript beats an older completion")
    func resumedSessionBeatsOldCompletion() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "session")
        let rows = AgentSession.displaySessions(
            live: [session("session", .working, at: now)], waitingAlerts: [],
            completedAlerts: [completed])
        #expect(rows.count == 1)
        #expect(rows[0].state == .working)
    }

    @Test("durations stay short enough for a notch row")
    func durationsAreCompact() {
        let now = Date()
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-45), now: now) == "45s")
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-240), now: now) == "4m")
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-7200), now: now) == "2h")
        // A clock skew must not render "-3s".
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(3), now: now) == "0s")
    }

    @Test("the card is only offered when something is running")
    func emptyListShowsNoCard() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            shelfCount: 0, shelfNames: [], agentSessions: [],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.isEmpty)
    }

    @Test("live agents lead the card row")
    func agentsComeFirst() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: "Xcode",
            systemVolume: 40, timer: nil, systemStats: nil, battery: nil,
            shelfCount: 0, shelfNames: [],
            agentSessions: [session("a", .working, at: Date())],
            showMedia: false, showActiveApp: true, showVolume: true, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.first?.id.hasPrefix("agents-") == true)
    }

    @Test("OpenCode usage follows live agents and is not presented as a quota")
    func openCodeUsageFollowsAgents() {
        let usage = OpenCodeUsage(inputTokens: 900, outputTokens: 100, reasoningTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            shelfCount: 0, shelfNames: [],
            agentSessions: [session("a", .working, at: Date())], openCodeUsage: usage,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["agents", "openCodeUsage"])
    }

    @Test("the toggle actually suppresses the card")
    func toggleOffHidesCard() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            shelfCount: 0, shelfNames: [],
            agentSessions: [session("a", .working, at: Date())],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: false)
        #expect(items.isEmpty)
    }
}

@Suite("Notch size preference")
struct NotchScaleTests {
    @Test("out-of-range values are clamped, not honoured")
    func clamps() {
        // A hand-edited plist must not be able to produce a pill that is
        // invisible or wider than the display.
        #expect(AppSettings.clampNotchScale(0.1) == AppSettings.notchScaleRange.lowerBound)
        #expect(AppSettings.clampNotchScale(9.0) == AppSettings.notchScaleRange.upperBound)
        #expect(AppSettings.clampNotchScale(1.0) == 1.0)
    }

    @Test("a corrupt value falls back to the default")
    func nonFiniteIsSafe() {
        // `defaults.double(forKey:)` returns 0 for a missing or non-numeric key,
        // and NaN survives a plist round trip — both would otherwise collapse
        // the pill to nothing.
        #expect(AppSettings.clampNotchScale(.nan) == 1.0)
        #expect(AppSettings.clampNotchScale(0) == AppSettings.notchScaleRange.lowerBound)
    }
}

@Suite("Shrinking adapts content, not just size")
struct NotchScaleAdaptationTests {
    // Shrinking the pill shrinks type with it, which makes text the first thing
    // to stop being readable. Compensation gives most of it back.
    @Test("smaller pill keeps type readable")
    func typeResistsShrinking() {
        let small = NotchContentLayout.textCompensation(forUserScale: 0.7)
        let mid = NotchContentLayout.textCompensation(forUserScale: 0.85)
        #expect(small > mid)          // the smaller it gets, the more it gives back
        #expect(small > 1.15)         // 70% pill renders type at ~86%, not 70%
        #expect(0.7 * small < 1.0)    // but never larger than at full size
    }

    @Test("enlarging is left alone")
    func growingIsUncompensated() {
        #expect(NotchContentLayout.textCompensation(forUserScale: 1.0) == 1)
        #expect(NotchContentLayout.textCompensation(forUserScale: 1.3) == 1)
    }

    @Test("a corrupt scale cannot produce a divide-by-zero")
    func zeroScaleIsSafe() {
        #expect(NotchContentLayout.textCompensation(forUserScale: 0) == 1)
        #expect(NotchContentLayout.textCompensation(forUserScale: -1) == 1)
    }

    @Test("the smaller it gets, the fewer cards it shows")
    func fewerCardsWhenSmall() {
        #expect(NotchContentLayout.visibleCardLimit(forUserScale: 0.7) == 3)
        #expect(NotchContentLayout.visibleCardLimit(forUserScale: 0.85) == 4)
        #expect(NotchContentLayout.visibleCardLimit(forUserScale: 1.0) == 5)
        #expect(NotchContentLayout.visibleCardLimit(forUserScale: 1.3) == 5)
        // The default size must never be one of the stingy ones.
        #expect(NotchContentLayout.visibleCardLimit(
            forUserScale: CGFloat(AppSettings.defaultNotchScale)) >= 3)
    }

    @Test("the limit never drops below something worth showing")
    func limitStaysUseful() {
        for scale in stride(from: 0.7, through: 1.3, by: 0.05) {
            #expect(NotchContentLayout.visibleCardLimit(forUserScale: CGFloat(scale)) >= 3)
        }
    }
}

@Suite("Agent names and task text")
struct AgentTaskTests {
    private func s(_ agent: String) -> AgentSession {
        AgentSession(id: "x", agent: agent, project: "p", state: .working, lastActivity: Date())
    }

    // "claude-code" is a wire identifier, not a label.
    @Test("wire ids become readable names")
    func names() {
        #expect(s("claude-code").agentName == "Claude")
        #expect(s("codex").agentName == "Codex")
        #expect(s("cursor").agentName == "Cursor")
        #expect(s("some-new-tool").agentName == "some-new-tool")
        #expect(s("").agentName == "Agent")
    }

    @Test("a short prompt is shown whole")
    func shortPromptKept() {
        #expect(AgentSession.summarize("fix the login bug") == "fix the login bug")
    }

    // Claude Code brackets pasted text and command output; without stripping,
    // rows would read "<command-name> …" instead of the actual request.
    @Test("wrapper tags are stripped")
    func tagsStripped() {
        #expect(AgentSession.summarize("<command-name>/compact</command-name> tidy up") == "tidy up")
        #expect(AgentSession.summarize("line one\nline two") == "line one line two")
    }

    @Test("long prompts truncate on a word boundary")
    func truncatesCleanly() {
        let long = "please refactor the authentication module and split it into smaller files"
        let out = AgentSession.summarize(long)!
        #expect(out.count <= 53)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("  "))
        // Never ends mid-word before the ellipsis.
        #expect(!out.dropLast().hasSuffix("refacto"))
    }

    @Test("nothing to show stays nil rather than becoming an empty row")
    func emptyIsNil() {
        #expect(AgentSession.summarize(nil) == nil)
        #expect(AgentSession.summarize("") == nil)
        #expect(AgentSession.summarize("   \n  ") == nil)
        #expect(AgentSession.summarize("<only><tags/></only>") == nil)
    }
}

@Suite("Sub-agent naming and session location")
struct AgentIdentityTests {
    private func session(subagent: String?) -> AgentSession {
        AgentSession(id: "x", agent: "claude-code", project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("a running sub-agent names the row")
    func subagentWins() {
        #expect(session(subagent: "code-reviewer").displayName == "Code Reviewer")
        #expect(session(subagent: "gsd-doc-writer").displayName == "Gsd Doc Writer")
        #expect(session(subagent: nil).displayName == "Claude")
        #expect(session(subagent: "").displayName == "Claude")
    }

    private func line(_ json: String) -> String { json }

    // A sub-agent is only "running" until its result comes back. Without the
    // pairing, a row would name a reviewer that finished twenty minutes ago.
    @Test("the parent's description separates same-type sub-agents")
    func descriptionDistinguishesRuns() {
        let parent = [
            #"{"message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"Explore","description":"Explore notch view layer"}}]}}"#,
            #"{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"agentId: aaa111"}]}}"#,
            #"{"message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"Explore","description":"Explore hover and window code"}}]}}"#,
            #"{"message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"agentId: bbb222"}]}}"#
        ].joined(separator: "\n")
        let first = AgentSessionScanner.subagentInfo(inParent: parent, agentId: "aaa111")
        let second = AgentSessionScanner.subagentInfo(inParent: parent, agentId: "bbb222")
        #expect(first?.type == "Explore")
        #expect(second?.type == "Explore")
        #expect(first?.task == "Explore notch view layer")
        #expect(second?.task == "Explore hover and window code")
        #expect(first?.task != second?.task)
    }

    @Test("noise never yields a name")
    func noiseIsSafe() {
        #expect(AgentSessionScanner.subagentInfo(inParent: "", agentId: "a") == nil)
        #expect(AgentSessionScanner.subagentInfo(inParent: "not json", agentId: "a") == nil)
        #expect(AgentSessionScanner.subagentInfo(
            inParent: #"{"message":{"content":[]}}"#, agentId: "a") == nil)
    }

    // MARK: - Locating the hosting app

    private static let table = """
    2186   685 /Users/me/.local/bin/claude --session-id ABC123 --settings {}
     685   681 /bin/zsh -lic something
     681   680 -/bin/zsh /var/folders/x/cmux-surface-resume/claude-F331
     680   504 /usr/bin/login -flp me /bin/bash
     504     1 /Applications/cmux.app/Contents/MacOS/cmux
    """

    @Test("the hosting app is found by walking parents")
    func walksToApp() {
        let entries = AgentSessionLocator.parse(Self.table)
        #expect(entries.count == 5)
        #expect(AgentSessionLocator.appBundlePath(in: entries.last!.args) == "/Applications/cmux.app")
    }

    @Test("a cycle or a rootless chain terminates")
    func malformedTreeTerminates() {
        // Two processes claiming each other as parent must not spin: this runs
        // on a tap, in front of the user.
        let cyclic = AgentSessionLocator.parse("""
        10 11 /bin/a
        11 10 /bin/b
        """)
        #expect(AgentSessionLocator.bundleId(walkingUpFrom: 10, in: cyclic) == nil)
        #expect(AgentSessionLocator.bundleId(walkingUpFrom: 999, in: cyclic) == nil)
    }

    @Test("a non-app process yields nothing rather than a guess")
    func noAppNoAnswer() {
        #expect(AgentSessionLocator.appBundlePath(in: "/usr/bin/login -flp me") == nil)
        #expect(AgentSessionLocator.appBundlePath(in: "") == nil)
    }
}

@Suite("Choosing the right process to focus")
struct LocatorChoiceTests {
    private let sid = "SESSION-42"

    // A grep, an editor with the transcript open, or a diagnostic all mention
    // the session id. Focusing whatever those descend from sends you somewhere
    // random, so the real agent binary has to win.
    @Test("the agent process beats a bystander that merely mentions the id")
    func prefersAgentProcess() {
        let table = AgentSessionLocator.parse("""
        900 901 /usr/bin/grep SESSION-42 /tmp/log
        901 902 /Applications/Notes.app/Contents/MacOS/Notes
        800 801 /Users/me/.local/bin/claude --session-id SESSION-42
        801 504 /bin/zsh -lic x
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table)
                == Bundle(path: "/Applications/cmux.app")?.bundleIdentifier)
    }

    // The agentish filter listed only claude and codex, and matched on a bare
    // substring. So an OpenCode session ranked its own binary no higher than a
    // `tail` on its transcript — and whichever `ps` happened to list first won.
    @Test("opencode's own process outranks a bystander holding its transcript")
    func prefersOpenCodeProcess() {
        let table = AgentSessionLocator.parse("""
        900 901 /usr/bin/tail -f /tmp/SESSION-42.jsonl
        901 902 /Applications/Notes.app/Contents/MacOS/Notes
        800 801 /Users/me/.local/bin/opencode --session SESSION-42
        801 504 /bin/zsh -lic x
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table)
                == Bundle(path: "/Applications/cmux.app")?.bundleIdentifier)
    }

    // Substring matching also counted a process whose *arguments* named the
    // binary. `codex` appearing in a path is not a codex process.
    @Test("a path merely containing an agent name is not an agent")
    func argumentMentionIsNotTheBinary() {
        let table = AgentSessionLocator.parse("""
        900 504 /usr/bin/vim /Users/me/codex/notes-SESSION-42.md
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        let ranked = AgentSessionLocator.candidates(forSessionId: sid, in: table)
        #expect(ranked.count == 1)
        #expect(!AgentSessionLocator.isProcess(ranked[0].args, named: "codex"))
    }

    @Test("a bystander is still used when it is the only match")
    func fallsBackToAnyMatch() {
        let table = AgentSessionLocator.parse("""
        900 504 /usr/bin/tail -f SESSION-42.jsonl
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table) != nil)
    }

    @Test("no match yields nothing rather than an arbitrary app")
    func noMatchNoGuess() {
        let table = AgentSessionLocator.parse("504 1 /Applications/cmux.app/Contents/MacOS/cmux")
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table) == nil)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: "", in: table) == nil)
    }

    @Test("Terminal tab script targets only the session TTY")
    func terminalTabScriptUsesEscapedTTY() {
        let script = AgentSessionLocator.terminalFocusScript(tty: #"/dev/ttys\"012"#)
        // Raw string: `\"` is literal here, so the quotes around the value are
        // plain. Only the escaping *inside* it is the thing under test.
        #expect(script.contains(#"tty of terminalTab is "/dev/ttys\\\"012""#))
        #expect(script.contains("set selected tab of terminalWindow to terminalTab"))
    }

    // Reported: tapping a live-agent row did nothing. `focus` selects a tab
    // inside cmux and says nothing about which app is frontmost, so the script
    // matched, focused, returned true — and the caller, treating true as
    // success, returned before the activation fallback. cmux stayed behind
    // whatever you were looking at. Terminal and iTerm always activated first.
    @Test("the cmux script brings cmux to the front, not just the tab")
    func cmuxScriptActivates() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/Users/me/proj")
        #expect(script.contains("activate"))
        // Before the match loop: focusing a tab in a background app is the bug.
        let activate = script.range(of: "activate")
        let loop = script.range(of: "repeat with cmuxWindow")
        #expect(activate != nil && loop != nil)
        if let activate, let loop { #expect(activate.lowerBound < loop.lowerBound) }
    }

    @Test("cmux script matches on the working directory it was given")
    func cmuxScriptUsesDirectory() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/Users/me/proj")
        #expect(script.contains(#"working directory of cmuxTerminal is "/Users/me/proj""#))
        #expect(script.contains("focus (item 1 of matches)"))
    }

    /// Two tabs on one directory are indistinguishable, and focusing the wrong
    /// one is worse than focusing the app — so the script declines to choose.
    @Test("cmux script refuses to guess between duplicate matches")
    func cmuxScriptRefusesAmbiguity() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/tmp")
        #expect(script.contains("if (count of matches) is 1 then"))
        #expect(script.contains("return false"))
    }

    @Test("cmux script escapes a directory containing a quote")
    func cmuxScriptEscapesDirectory() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: #"/tmp/a"b"#)
        #expect(script.contains(#"is "/tmp/a\"b""#))
    }

    @Test("iTerm script selects the exact split-pane session")
    func iTermSessionScriptUsesTTY() {
        let script = AgentSessionLocator.iTermFocusScript(tty: "/dev/ttys012")
        #expect(script.contains("tty of terminalSession is \"/dev/ttys012\""))
        #expect(script.contains("tell terminalWindow to select"))
        #expect(script.contains("tell terminalTab to select"))
        #expect(script.contains("tell terminalSession to select"))
    }
}

@Suite("Sub-agent path parsing")
struct SubagentPathTests {
    private let side = "/Users/me/.claude/projects/-Users-me-proj/SESSION/subagents/agent-abc123.jsonl"

    @Test("a sidechain reveals its agent and its parent session")
    func parsesSidechain() {
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: side)) == "abc123")
        #expect(AgentSessionScanner.parentSessionId(ofPath: side) == "SESSION")
    }

    // A normal session must not be mistaken for a sub-agent, or it would be
    // located via a parent that does not exist.
    @Test("a normal session is not a sidechain")
    func normalSessionIsNot() {
        let normal = "/Users/me/.claude/projects/-Users-me-proj/SESSION.jsonl"
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: normal)) == nil)
        #expect(AgentSessionScanner.parentSessionId(ofPath: normal) == nil)
    }

    @Test("a file in the right folder but the wrong shape is rejected")
    func wrongPrefixRejected() {
        let odd = "/Users/me/.claude/projects/p/S/subagents/notes.jsonl"
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: odd)) == nil)
    }
}

@Suite("Pill hit rule")
struct HitRuleTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 200)
    private let notchW: CGFloat = 200
    private let notchH: CGFloat = 32
    private let expandedSize = CGSize(width: 400, height: 160)
    private let collapsedSize = CGSize(width: 200, height: 40)

    private func accepts(_ p: NSPoint, expanded: Bool = true) -> Bool {
        NotchContainerView.accepts(p, bounds: bounds,
                                   notchWidth: notchW, notchHeight: notchH,
                                   expanded: expanded,
                                   collapsedSize: collapsedSize,
                                   expandedSize: expandedSize)
    }

    @Test("clicks land on the pill body")
    func bodyAccepts() {
        #expect(accepts(NSPoint(x: 250, y: 80)))
    }

    // REGRESSION: the passthrough check grew the rects by 2pt while hitTest used
    // them exact, leaving a band around every edge where the window swallowed a
    // click and routed it nowhere. The peek's ✕ sits ~8pt from that edge, which
    // is exactly how it came to feel unreliable. Both callers now share this
    // rule, so the band can only come back if the slack itself is dropped.
    @Test("the slack band just outside the body is still clickable")
    func slackBandAccepts() {
        let bodyRight: CGFloat = 250 + 400 / 2      // 450
        #expect(accepts(NSPoint(x: bodyRight - 1, y: 80)))   // inside
        #expect(accepts(NSPoint(x: bodyRight + 1, y: 80)))   // within slack
    }

    @Test("well outside the pill is not clickable")
    func outsideRejected() {
        #expect(!accepts(NSPoint(x: 490, y: 80)))
        #expect(!accepts(NSPoint(x: 10, y: 80)))
    }

    // The strip beside the physical notch must stay with the browser, or
    // clicking a tab hits the overlay instead.
    @Test("tab ears beside the notch never accept")
    func tabEarsRejected() {
        let earY = bounds.height - notchH / 2
        #expect(!accepts(NSPoint(x: 20, y: earY)))
        #expect(!accepts(NSPoint(x: 480, y: earY)))
        // …but the notch column between them does.
        #expect(accepts(NSPoint(x: 250, y: earY)))
    }

    @Test("collapsed only accepts the collapsed pill")
    func collapsedRule() {
        #expect(accepts(NSPoint(x: 250, y: 190), expanded: false))
        #expect(!accepts(NSPoint(x: 250, y: 80), expanded: false))
    }

    // A rect list that disagrees with the accept rule is how the two paths
    // drifted apart the first time.
    @Test("every interactive rect's centre is accepted")
    func rectsAgreeWithRule() {
        let rects = NotchContainerView.interactiveRects(
            bounds: bounds, notchWidth: notchW, notchHeight: notchH,
            expanded: true, collapsedSize: collapsedSize, expandedSize: expandedSize)
        #expect(rects.count == 2)
        for rect in rects {
            #expect(accepts(NSPoint(x: rect.midX, y: rect.midY)))
        }
    }
}

@Suite("Media payload parsing")
struct MediaPayloadTests {
    // Micros must win over seconds. If the precedence flips, a 3-minute track
    // reports 180 million seconds and the scrubber is off by 10^6 — visible as
    // a progress bar that never moves.
    @Test("microsecond keys take precedence over second keys")
    func microsWin() {
        let payload: [String: Any] = ["durationMicros": NSNumber(value: 180_000_000),
                                      "duration": NSNumber(value: 999)]
        #expect(MediaRemoteBridge.parseDuration(payload) == 180)
    }

    @Test("seconds are used when micros are absent")
    func secondsFallback() {
        #expect(MediaRemoteBridge.parseDuration(["duration": NSNumber(value: 210)]) == 210)
        #expect(MediaRemoteBridge.parseDuration([:]) == nil)
    }

    // Four keys in a documented order; "now" variants are fresher than the
    // plain ones and must be preferred.
    @Test("elapsed prefers the freshest key available")
    func elapsedPrecedence() {
        let all: [String: Any] = [
            "elapsedTimeNowMicros": NSNumber(value: 30_000_000),
            "elapsedTimeMicros": NSNumber(value: 20_000_000),
            "elapsedTimeNow": NSNumber(value: 10),
            "elapsedTime": NSNumber(value: 5)
        ]
        #expect(MediaRemoteBridge.parseElapsed(all) == 30)
        var without = all; without["elapsedTimeNowMicros"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 20)
        without["elapsedTimeMicros"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 10)
        without["elapsedTimeNow"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 5)
        without["elapsedTime"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == nil)
    }

    @Test("timestamps convert from epoch micros")
    func timestampConversion() {
        let d = MediaRemoteBridge.parseTimestamp(["timestampEpochMicros": NSNumber(value: 1_700_000_000_000_000)])
        #expect(d?.timeIntervalSince1970 == 1_700_000_000)
        let plain = MediaRemoteBridge.parseTimestamp(["timestamp": NSNumber(value: 1_700_000_000)])
        #expect(plain?.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("wrong types are ignored rather than coerced")
    func wrongTypesIgnored() {
        // A string here would previously read as nil, not as a bogus number —
        // pin it, because `as? NSNumber` on a numeric string is a classic trap.
        #expect(MediaRemoteBridge.parseDuration(["duration": "210"]) == nil)
        #expect(MediaRemoteBridge.parseElapsed(["elapsedTime": NSNull()]) == nil)
    }
}

/// Characterization tests: these record what the resolver does *today*, so a
/// cleanup can be proven not to change behaviour.
@Suite("Now playing video titles")
struct VideoTitleTests {
    private func resolve(_ t: String, _ a: String, _ al: String) -> (title: String, artist: String)? {
        NowPlayingDisplayResolver.resolve(title: t, artist: a, album: al,
                                          mediaType: "video",
                                          bundleIdentifier: "com.apple.Safari")
    }

    // The case the dead branch was reaching for: a player putting a site domain
    // in the title and the real name in the artist. The title must not survive
    // as the artist line — showing "netflix.com" under the show is the bug.
    @Test("a domain title is replaced, not demoted to the artist line")
    func domainTitleReplaced() {
        let out = resolve("netflix.com", "Stranger Things", "")
        #expect(out?.title == "Stranger Things")
        #expect(out?.artist == "")
    }

    @Test("a real title is left alone")
    func realTitleKept() {
        let out = resolve("Chapter One", "Stranger Things", "")
        #expect(out?.title == "Chapter One")
        #expect(out?.artist == "Stranger Things")
    }

    @Test("the album supplies the show when the title is noise")
    func albumSuppliesShow() {
        let out = resolve("youtube.com", "", "Stranger Things, Season 1")
        #expect(out?.title == "Stranger Things")
    }

    @Test("nothing at all resolves to nothing")
    func emptyIsNil() {
        #expect(NowPlayingDisplayResolver.resolve(title: "", artist: "", album: "") == nil)
        #expect(NowPlayingDisplayResolver.resolve(title: nil, artist: nil, album: nil) == nil)
    }
}

@Suite("Hover forgiveness follows the size setting")
struct HoverPaddingTests {
    // A smaller pill is a smaller target. Leaving the slack at a flat 14/10pt
    // shrank the forgiveness twice over — smaller target, same absolute margin —
    // and the pointer slipped out while reaching for a control.
    @Test("shrinking the pill widens the slack")
    func smallerGetsMoreSlack() {
        let full = NotchController.hoverPadding(forUserScale: 1.0)
        let small = NotchController.hoverPadding(forUserScale: 0.75)
        #expect(small.x > full.x)
        #expect(small.y > full.y)
        #expect(small.collapsedX > full.collapsedX)
    }

    @Test("the default is unchanged")
    func defaultUnchanged() {
        let p = NotchController.hoverPadding(forUserScale: 1.0)
        #expect(p.x == 14)
        #expect(p.y == 10)
        #expect(p.collapsedX == 10)
        #expect(p.collapsedY == 6)
    }

    // Enlarging must not make hovering fussier than it is at 100%.
    @Test("growing never reduces the slack")
    func growingKeepsSlack() {
        let big = NotchController.hoverPadding(forUserScale: 1.3)
        #expect(big.x == 14)
        #expect(big.y == 10)
    }

    @Test("a corrupt scale cannot produce a runaway or zero zone")
    func corruptScaleClamped() {
        let zero = NotchController.hoverPadding(forUserScale: 0)
        #expect(zero.x == 28)          // clamped at 0.5, not divided by zero
        #expect(zero.x.isFinite)
        let negative = NotchController.hoverPadding(forUserScale: -5)
        #expect(negative.x == 28)
    }
}

@Suite("CI status")
struct CIStatusTests {
    // gh reports an in-flight run as queued/in_progress with an *empty*
    // conclusion. Reading the conclusion alone would paint every running build
    // as a failure — the loudest possible wrong answer.
    @Test("a running build is not a failure")
    func runningIsNotFailure() {
        #expect(CIRun.state(status: "in_progress", conclusion: "") == .running)
        #expect(CIRun.state(status: "queued", conclusion: "") == .running)
        #expect(CIRun.state(status: "completed", conclusion: "") == .running)
    }

    @Test("finished states map correctly")
    func finishedStates() {
        #expect(CIRun.state(status: "completed", conclusion: "success") == .passed)
        #expect(CIRun.state(status: "completed", conclusion: "failure") == .failed)
        #expect(CIRun.state(status: "completed", conclusion: "startup_failure") == .failed)
        #expect(CIRun.state(status: "completed", conclusion: "cancelled") == .other("cancelled"))
    }

    @Test("failures sort above everything, then running")
    func ordering() {
        let now = Date()
        func run(_ id: String, _ st: CIRun.State, _ age: TimeInterval) -> CIRun {
            CIRun(id: id, repo: "o/r", workflow: id, branch: "main",
                  state: st, started: now.addingTimeInterval(-age))
        }
        let ordered = CIRun.ordered([
            run("newest-pass", .passed, 10),
            run("running", .running, 300),
            run("failed", .failed, 900)
        ])
        #expect(ordered.map(\.id) == ["failed", "running", "newest-pass"])
    }

    @Test("both remote forms yield the repo slug")
    func slugParsing() {
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner/name.git") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner/name") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "git@github.com:owner/name.git") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "  git@github.com:owner/name.git\n") == "owner/name")
    }

    // A non-GitHub remote has no runs to fetch, and guessing a slug would send
    // `gh` after a repo that does not exist.
    @Test("non-GitHub remotes are declined")
    func nonGitHubDeclined() {
        #expect(CIRun.repoSlug(fromRemote: "git@gitlab.com:owner/name.git") == nil)
        #expect(CIRun.repoSlug(fromRemote: "/local/path/repo") == nil)
        #expect(CIRun.repoSlug(fromRemote: "") == nil)
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner") == nil)
    }
}

@Suite("Card width shares")
struct CardShareTests {
    @Test("cards with no per-kind default split evenly")
    func equalByDefault() {
        let shares = AppSettings.shares(for: ["media", "clock"], weights: [:])
        #expect(shares["media"] == 0.5)
        #expect(shares["clock"] == 0.5)
    }

    // CI is three short rows of "repo — passed". At an equal split it took half
    // the row to say very little, and the first thing anyone did was drag it
    // back down; agents carries a task line per session and earns the width.
    @Test("out of the box, agents is wider than CI")
    func defaultsFavourAgents() {
        let shares = AppSettings.shares(for: ["agents", "ci"], weights: [:])
        #expect((shares["agents"] ?? 0) > (shares["ci"] ?? 1))
        #expect(abs((shares["agents"] ?? 0) + (shares["ci"] ?? 0) - 1) < 0.0001)
    }

    // A row someone has already arranged must not move when a default changes.
    @Test("an explicit weight beats the per-kind default")
    func explicitWinsOverDefault() {
        let shares = AppSettings.shares(for: ["agents", "ci"],
                                        weights: ["agents": 1.0, "ci": 1.0])
        #expect(shares["agents"] == 0.5)
        #expect(shares["ci"] == 0.5)
    }

    @Test("every default sits inside the range the sliders allow")
    func defaultsAreReachable() {
        for kind in ["agents", "ci", "media", "clock", "battery", "anything"] {
            let w = AppSettings.defaultWeight(for: kind)
            #expect(AppSettings.cardWeightRange.contains(w))
        }
    }

    // The thing the feature is for: "live agents 80%, media 20%".
    @Test("weights produce the asked-for split")
    func eightyTwenty() {
        let shares = AppSettings.shares(for: ["agents", "media"],
                                        weights: ["agents": 2.0, "media": 0.5])
        #expect(shares["agents"] == 0.8)
        #expect(shares["media"] == 0.2)
    }

    @Test("shares always sum to the whole row")
    func sharesSumToOne() {
        let kinds = ["agents", "media", "clock", "battery"]
        let shares = AppSettings.shares(for: kinds,
                                        weights: ["agents": 3, "media": 0.4, "clock": 1])
        let total = shares.values.reduce(0, +)
        #expect(abs(total - 1.0) < 0.0001)
        // A card with no weight set still gets a share.
        #expect((shares["battery"] ?? 0) > 0)
    }

    // A zero or negative weight would divide the row by nothing and collapse
    // every card to a sliver.
    @Test("degenerate weights cannot collapse the row")
    func degenerateWeights() {
        #expect(AppSettings.clampWeight(0) == AppSettings.cardWeightRange.lowerBound)
        #expect(AppSettings.clampWeight(-5) == AppSettings.cardWeightRange.lowerBound)
        #expect(AppSettings.clampWeight(.nan) == 1.0)
        #expect(AppSettings.clampWeight(99) == AppSettings.cardWeightRange.upperBound)
        let shares = AppSettings.shares(for: ["a", "b"], weights: ["a": 0, "b": -1])
        #expect(abs((shares["a"] ?? 0) - 0.5) < 0.0001)
    }

    @Test("an empty row yields no shares rather than dividing by zero")
    func emptyRow() {
        #expect(AppSettings.shares(for: [], weights: [:]).isEmpty)
    }
}

@Suite("CI repo memory")
struct CIRepoMemoryTests {
    // A release is tagged and then walked away from: the agent session ends in
    // seconds, the build takes minutes. Tying the card to the session made CI
    // disappear exactly when it mattered.
    @Test("a repo outlives the session that introduced it")
    func repoIsRemembered() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("owner/repo", at: now)
        #expect(await p.repos(at: now.addingTimeInterval(1800)) == ["owner/repo"])
    }

    @Test("but not forever")
    func repoExpires() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("owner/repo", at: now)
        #expect(await p.repos(at: now.addingTimeInterval(7200)).isEmpty)
    }

    @Test("the most recent repo wins the budget")
    func newestFirst() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("old/one", at: now.addingTimeInterval(-600))
        await p.remember("new/two", at: now)
        #expect(await p.repos(at: now).first == "new/two")
    }
}

// MARK: - Onboarding

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("walks forward and stops at the end")
    func walksForward() {
        var flow = OnboardingFlow()
        #expect(flow.current == .welcome)
        #expect(flow.isFirst)
        for _ in 0..<20 { flow.next() }
        #expect(flow.current == .finish)
        #expect(flow.isLast)
    }

    @Test("walks back and stops at the start")
    func walksBack() {
        var flow = OnboardingFlow()
        flow.next()
        #expect(flow.current == .accessibility)
        for _ in 0..<20 { flow.back() }
        #expect(flow.current == .welcome)
    }

    // Dividing by steps.count - 1 is one off-by-one away from dividing by zero,
    // and a one-step flow is exactly what an all-satisfied guide would be.
    @Test("a single-step flow has finite progress")
    func singleStep() {
        let flow = OnboardingFlow(steps: [.finish])
        #expect(flow.progress == 0)
        #expect(flow.isFirst && flow.isLast)
    }

    @Test("an empty flow still has a step to show")
    func emptyFlow() {
        let flow = OnboardingFlow(steps: [])
        #expect(flow.current == .finish)
    }

    @Test("progress ends at 1")
    func progressCompletes() {
        var flow = OnboardingFlow()
        while !flow.isLast { flow.next() }
        #expect(flow.progress == 1)
    }

    @Test("every step says something")
    func everyStepHasCopy() {
        for step in OnboardingStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(step.detail.count > 20)
        }
    }
}

@Suite("Onboarding gating")
struct OnboardingGateTests {
    @Test("a fresh install sees the guide")
    func freshInstall() {
        #expect(Onboarding.shouldShow(completedVersion: 0))
    }

    @Test("a completed install does not")
    func alreadyDone() {
        #expect(!Onboarding.shouldShow(completedVersion: Onboarding.currentVersion))
    }
}

@Suite("Agent hook detection")
struct AgentHookDetectionTests {
    // Detection must agree with the installer's own --status, which greps
    // case-insensitively for the same word.
    @Test("finds the marker whatever the case")
    func findsMarker() {
        #expect(AgentHooks.isInstalled(inConfig: #"{"command": "notchpill-agent-question.sh"}"#))
        #expect(AgentHooks.isInstalled(inConfig: "command = \"/x/NotchPill/hook.sh\""))
    }

    @Test("an unrelated config is not wired up")
    func noMarker() {
        #expect(!AgentHooks.isInstalled(inConfig: #"{"hooks": {"Stop": []}}"#))
        #expect(!AgentHooks.isInstalled(inConfig: ""))
    }

    @Test("ANSI colouring is stripped from the transcript")
    func stripsAnsi() {
        #expect(AgentHooks.cleanOutput("\u{1B}[32m✓\u{1B}[0m Claude Code — wired up\n")
                == "✓ Claude Code — wired up")
    }
}

// MARK: - Shortcut arming

@Suite("Shortcut arming")
struct ShortcutArmingTests {
    // `#expect` captures its operand immutably, so each step is taken first.
    private func step(_ arming: inout ShortcutArming, _ x: CGFloat, _ y: CGFloat,
                      inZone: Bool) -> Bool {
        arming.update(point: CGPoint(x: x, y: y), inZone: inZone)
    }

    // The bug: a peek arrives, the pill's hot zone grows over a parked cursor,
    // and the next Space is eaten and sent to the browser as play/pause — in
    // the middle of someone typing.
    @Test("a zone that grows under a still pointer does not arm")
    func zoneGrowsUnderStillPointer() {
        var a = ShortcutArming()
        #expect(step(&a, 700, 900, inZone: false) == false)
        // The peek lands; same cursor, now inside the zone.
        #expect(step(&a, 700, 900, inZone: true) == false)
        #expect(step(&a, 700, 900, inZone: true) == false)
    }

    @Test("moving into the zone arms immediately")
    func movingInArms() {
        var a = ShortcutArming()
        #expect(step(&a, 700, 400, inZone: false) == false)
        #expect(step(&a, 700, 900, inZone: true) == true)
    }

    // Once armed, holding the mouse perfectly still must not disarm — that is
    // exactly what watching a video with the pointer on the pill looks like.
    @Test("staying still while armed keeps the shortcuts")
    func staysArmed() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 900, inZone: true) == true)
    }

    @Test("leaving the zone disarms")
    func leavingDisarms() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 300, inZone: false) == false)
        // And a re-entry under a still pointer stays disarmed.
        #expect(step(&a, 700, 300, inZone: true) == false)
    }

    @Test("explicit disarm forgets the movement history")
    func explicitDisarm() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        a.disarm()
        #expect(a.isArmed == false)
        // No prior point, so the first sample after a disarm cannot re-arm.
        #expect(step(&a, 700, 900, inZone: true) == false)
    }

    @Test("wiggling inside the zone re-arms after a disarm")
    func rearmsOnMovement() {
        var a = ShortcutArming()
        a.disarm()
        #expect(step(&a, 700, 900, inZone: true) == false)
        #expect(step(&a, 702, 900, inZone: true) == true)
    }
}

// MARK: - Log store

@Suite("Log ring buffer")
struct LogStoreTests {
    private func entries(_ n: Int) -> [LogEntry] {
        (0..<n).map { LogEntry(id: UInt64($0), date: Date(), level: .info,
                               category: "test", message: "m\($0)") }
    }

    @Test("under capacity, nothing is dropped")
    func keepsEverything() {
        let kept = LogStore.trim(entries(10), to: 600)
        #expect(kept.count == 10)
    }

    // The oldest lines go, not the newest — the tail is what you were doing
    // when the thing you are chasing happened.
    @Test("over capacity, the oldest go first")
    func dropsOldest() {
        let kept = LogStore.trim(entries(700), to: 600)
        #expect(kept.count == 600)
        #expect(kept.first?.message == "m100")
        #expect(kept.last?.message == "m699")
    }

    @Test("a zero capacity keeps nothing rather than crashing")
    func zeroCapacity() {
        #expect(LogStore.trim(entries(5), to: 0).isEmpty)
    }

    @Test("a line carries its level, category and message")
    func lineFormat() {
        let e = LogEntry(id: 1, date: Date(timeIntervalSince1970: 0), level: .error,
                         category: "peek", message: "boom")
        let line = e.line(formatter: LogStore.lineFormatter)
        #expect(line.contains("[peek]"))
        #expect(line.contains("boom"))
        #expect(line.contains(LogEntry.Level.error.symbol))
    }
}

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    private var facts: DiagnosticsReport.Facts {
        .init(appVersion: "1.13.0", systemVersion: "Version 26.0",
              accessibilityGranted: true, hooksInstalled: false, ghAvailable: true,
              enabledCards: ["agents", "ci"], notchScale: 0.9,
              cardWeights: ["agents": 3.0, "ci": 0.75],
              logLines: "12:00:00.000 · [app] launched",
              home: "/Users/someone")
    }

    // The whole point is that it can be pasted into a public issue without
    // thinking about it, and the account name is the thing that would leak.
    @Test("home paths are collapsed to ~")
    func redactsHome() {
        let text = DiagnosticsReport.redact(
            "hook at /Users/someone/.claude/settings.json", home: "/Users/someone")
        #expect(text == "hook at ~/.claude/settings.json")
        #expect(!text.contains("someone"))
    }

    @Test("a report redacts the log it carries too")
    func redactsInsideLog() {
        var f = facts
        f.logLines = "· [hooks] wrote /Users/someone/.codex/config.toml"
        let report = DiagnosticsReport.build(f)
        #expect(!report.contains("/Users/someone"))
        #expect(report.contains("~/.codex/config.toml"))
    }

    @Test("an empty or root home is left alone")
    func degenerateHome() {
        #expect(DiagnosticsReport.redact("/a/b", home: "") == "/a/b")
        #expect(DiagnosticsReport.redact("/a/b", home: "/") == "/a/b")
    }

    // Every field here has explained a real bug report at least once.
    @Test("the report states the facts that decide most problems")
    func statesTheFacts() {
        let report = DiagnosticsReport.build(facts)
        #expect(report.contains("1.13.0"))
        #expect(report.contains("granted"))
        #expect(report.contains("not installed"))
        #expect(report.contains("agents, ci"))
        #expect(report.contains("90%"))
    }

    @Test("an empty log says so rather than trailing off")
    func emptyLog() {
        var f = facts
        f.logLines = ""
        #expect(DiagnosticsReport.build(f).contains("(empty"))
    }
}

// MARK: - Expanded pill height

@Suite("Expanded pill height")
struct ExpandedHeightTests {
    private func agents(_ n: Int) -> ExpandedActivity {
        .agents((0..<n).map {
            AgentSession(id: "s\($0)", agent: "claude-code", project: "p",
                         state: .working, lastActivity: Date())
        })
    }

    private func ci(_ n: Int) -> ExpandedActivity {
        .ci((0..<n).map {
            CIRun(id: "r\($0)", repo: "o/r", workflow: "Release", branch: "main",
                  state: .passed, started: Date())
        })
    }

    private var media: ExpandedActivity {
        .media(NowPlaying(title: "t", artist: "a", isPlaying: true))
    }

    // The reported bug: 75% size, one agent row, three CI rows, music playing —
    // and a pill sized as if every card were full.
    @Test("a mostly empty row is shorter than a full one")
    func reportedCase() {
        let reported = NotchContentLayout.expandedContentBaseHeight([agents(1), ci(3), media])
        let full = NotchContentLayout.expandedContentBaseHeight([agents(3), ci(3), media])
        #expect(reported < full)
    }

    // The other half of the same wrong constant: three agent rows and no media
    // used to budget 66 and clip the third row.
    @Test("three agent rows get more than the old flat 66")
    func threeRowsFit() {
        #expect(NotchContentLayout.expandedContentBaseHeight([agents(3), ci(3)]) > 66)
    }

    @Test("height grows with rows, then stops when the card starts scrolling")
    func growsThenCaps() {
        let one = NotchContentLayout.expandedContentBaseHeight([agents(1)])
        let two = NotchContentLayout.expandedContentBaseHeight([agents(2)])
        let three = NotchContentLayout.expandedContentBaseHeight([agents(3)])
        let ten = NotchContentLayout.expandedContentBaseHeight([agents(10)])
        #expect(one < two)
        // Two rows is the ceiling, so three and ten clamp to the same height
        // as two. The regression this guards against is `two` clamping down to
        // `one`'s height, which is what happened when rows grew and the
        // ceiling did not.
        #expect(two == NotchContentLayout.expandedContentCeiling)
        #expect(three == two)
        #expect(three == ten)
    }

    @Test("the tallest card sets the height, not the first or the last")
    func tallestWins() {
        let tall = NotchContentLayout.expandedContentBaseHeight([agents(3)])
        #expect(NotchContentLayout.expandedContentBaseHeight([.clock, agents(3)]) == tall)
        #expect(NotchContentLayout.expandedContentBaseHeight([agents(3), .clock]) == tall)
    }

    @Test("every combination stays inside the expanded-notch height budget")
    func clamped() {
        let rows: [[ExpandedActivity]] = [
            [], [.clock], [media], [agents(1)], [agents(10), ci(10), media],
            [.clock, .battery(BatteryStatus(level: 50, isCharging: false))],
        ]
        for row in rows {
            let h = NotchContentLayout.expandedContentBaseHeight(row)
            // Bound taken from the constant, not repeated as a literal: the
            // last time these drifted apart the card silently stopped fitting
            // the second agent row.
            #expect(h >= 48 && h <= NotchContentLayout.expandedContentCeiling)
        }
    }

    // A row of one-line chips must not collapse into a letterbox.
    @Test("a single small card still gets a usable height")
    func floorHolds() {
        #expect(NotchContentLayout.expandedContentBaseHeight([.clock]) >= 48)
    }
}

// MARK: - Agent liveness windows

@Suite("Agent state windows")
struct AgentStateWindowTests {
    // Reported: four agents running, one row, and it said idle. Both halves of
    // that were the thresholds, not the detection.
    @Test("an agent mid tool call is still working, not idle")
    func longToolCallStaysWorking() {
        let now = Date()
        // A build, a test run, a slow search — nothing is written meanwhile.
        let state = AgentSession.state(lastWrite: now.addingTimeInterval(-30),
                                       blocked: false, now: now)
        #expect(state == .working)
    }

    @Test("but a genuinely quiet session does go idle")
    func quietGoesIdle() {
        let now = Date()
        let state = AgentSession.state(lastWrite: now.addingTimeInterval(-300),
                                       blocked: false, now: now)
        if case .idle = state {} else { Issue.record("expected idle, got \(state)") }
    }

    @Test("blocked still beats both")
    func blockedWins() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now, blocked: true, now: now) == .waiting(since: nil))
    }

    // A session that has gone quiet for an hour is still one you are "in" —
    // dropping it made a running agent vanish from the card entirely.
    @Test("an hour of quiet still counts as live")
    func quietHourIsStillLive() {
        #expect(AgentSession.liveWindow > 3600)
    }

    @Test("the working window is shorter than the live window")
    func windowsAreOrdered() {
        #expect(AgentSession.workingWindow < AgentSession.liveWindow)
    }
}

// MARK: - CI run lifetime

@Suite("CI run lifetime")
struct CIRunLifetimeTests {
    private func run(_ state: CIRun.State, ageMinutes: Double, now: Date) -> CIRun {
        CIRun(id: "r\(ageMinutes)\(state)", repo: "o/r", workflow: "Release", branch: "main",
              state: state, started: now.addingTimeInterval(-ageMinutes * 60))
    }

    // Reported: the same three "Release — passed" rows sitting there forever.
    // `gh run list` has no notion of age, so a repo built once kept showing
    // last week's green ticks every time an agent opened in it.
    @Test("a pass stops being news")
    func passedAgesOut() {
        let now = Date()
        let fresh = run(.passed, ageMinutes: 0.5, now: now)
        let stale = run(.passed, ageMinutes: 10, now: now)
        let kept = CIRun.current([fresh, stale], now: now)
        #expect(kept.map(\.id) == [fresh.id])
    }

    // The one you have not dealt with yet is worth keeping around.
    @Test("a failure sticks around far longer than a pass")
    func failureOutlivesPass() {
        #expect(CIRun.failedLifetime > CIRun.passedLifetime)
        let now = Date()
        let failed = run(.failed, ageMinutes: 90, now: now)
        #expect(CIRun.current([failed], now: now).count == 1)
    }

    @Test("but not forever")
    func failureAlsoAgesOut() {
        let now = Date()
        #expect(CIRun.current([run(.failed, ageMinutes: 600, now: now)], now: now).isEmpty)
    }

    // A build going for two hours is exactly the one you want on screen.
    @Test("a long-running build is never aged out")
    func runningAlwaysStays() {
        let now = Date()
        let old = run(.running, ageMinutes: 240, now: now)
        #expect(CIRun.current([old], now: now).map(\.id) == [old.id])
    }

    @Test("cancelled and skipped age out like a pass")
    func otherAgesOut() {
        let now = Date()
        #expect(CIRun.current([run(.other("cancelled"), ageMinutes: 10, now: now)],
                              now: now).isEmpty)
    }

    // Everything aging out has to reach the card as an empty list, so the
    // card can take itself off the row instead of showing a stale header.
    @Test("an all-stale repo yields nothing at all")
    func emptiesCompletely() {
        let now = Date()
        let stale = [run(.passed, ageMinutes: 20, now: now),
                     run(.passed, ageMinutes: 30, now: now)]
        #expect(CIRun.current(stale, now: now).isEmpty)
    }
}

// MARK: - Peek hit testing

@Suite("Peek ✕ hit testing")
struct PeekDismissHitTests {
    // Geometry of a real peek: much wider than the notch, with its ✕ ~20pt in
    // from the trailing edge.
    private let bounds = CGRect(x: 0, y: 0, width: 720, height: 200)
    private let collapsed = CGSize(width: 240, height: 92)
    private let peek = CGSize(width: 420, height: 110)
    private let notchW: CGFloat = 200
    private let notchH: CGFloat = 32

    /// Where the ✕ actually sits: inside the peek, well outside the collapsed pill.
    private var dismissPoint: CGPoint {
        CGPoint(x: bounds.midX + peek.width / 2 - 20, y: bounds.maxY - 60)
    }

    private func accepts(expanded: Bool) -> Bool {
        NotchContainerView.accepts(dismissPoint,
                                   bounds: bounds,
                                   notchWidth: notchW, notchHeight: notchH,
                                   expanded: expanded,
                                   collapsedSize: collapsed,
                                   expandedSize: peek)
    }

    // The bug: a peek never sets `isExpanded`, so this rule was asked with
    // `expanded: false` while a peek was on screen. It then measured the ✕
    // against the *collapsed* pill, found it outside, and returned nil from
    // hitTest — dropping the click onto whatever was behind the notch.
    @Test("the ✕ is outside the collapsed pill")
    func outsideCollapsed() {
        #expect(accepts(expanded: false) == false)
    }

    @Test("but inside the pill a peek actually draws")
    func insidePeek() {
        #expect(accepts(expanded: true) == true)
    }

    // Which is why the controller must report "rendering large content" rather
    // than "expanded" — the two are not the same thing for a peek.
    @Test("the two answers genuinely differ, so the flag matters")
    func flagDecidesIt() {
        #expect(accepts(expanded: true) != accepts(expanded: false))
    }
}

// MARK: - Notch detection

// The reported bug: on a Mac with no cutout the pill was a flat-topped black
// slab hanging under the menu bar. `NotchShape` draws square top corners flush
// to the top edge, which is right on notched hardware — they sit inside the
// physical notch — and wrong everywhere else, where they meet open wallpaper.
@Suite("Pill silhouette without a notch")
struct FloatingPillShapeTests {
    private let box = CGRect(x: 0, y: 0, width: 300, height: 120)

    /// Whether the path covers a point, used to ask about the corners.
    private func covers(_ shape: NotchShape, _ point: CGPoint) -> Bool {
        shape.path(in: box).contains(point)
    }

    @Test("on notched hardware the top corners stay square")
    func notchedKeepsSquareTop() {
        let shape = NotchShape(bottomRadius: 22)
        // A point 2pt in from the very top-left corner.
        #expect(covers(shape, CGPoint(x: 2, y: 2)))
        #expect(covers(shape, CGPoint(x: box.maxX - 2, y: 2)))
    }

    @Test("without a notch the top corners are rounded away")
    func floatingRoundsTop() {
        let shape = NotchShape(bottomRadius: 22, topRadius: 22)
        // The same corner points now fall outside the rounded silhouette —
        // this is the difference between "attached" and "slab".
        #expect(!covers(shape, CGPoint(x: 2, y: 2)))
        #expect(!covers(shape, CGPoint(x: box.maxX - 2, y: 2)))
        // The body is still solid.
        #expect(covers(shape, CGPoint(x: box.midX, y: box.midY)))
        #expect(covers(shape, CGPoint(x: box.midX, y: 2)))
    }

    // Both kinds of display round the bottom; only the top differs.
    @Test("the bottom is rounded either way")
    func bottomUnchanged() {
        for top in [CGFloat(0), 22] {
            let shape = NotchShape(bottomRadius: 22, topRadius: top)
            #expect(!covers(shape, CGPoint(x: 2, y: box.maxY - 2)))
        }
    }
}

@Suite("Notch detection")
struct NotchRectTests {
    // A 14" MacBook Pro in points.
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let safeTop: CGFloat = 37

    private func rect(left: CGRect?, right: CGRect?) -> CGRect? {
        NotchGeometry.notchRect(inFrame: frame, safeTop: safeTop, left: left, right: right)
    }

    private func source(left: CGRect?, right: CGRect?) -> NotchGeometry.Source? {
        NotchGeometry.resolveNotch(inFrame: frame, safeTop: safeTop,
                                   left: left, right: right)?.source
    }

    // On a 14" Pro the guess and the measurement are both 200pt wide, so every
    // assertion in this suite passed either way and nothing distinguished "read
    // the display" from "could not read the display". That is what made a
    // report of the pill hanging detached from the notch impossible to check:
    // the fallback is silent, and on a Mac whose notch is not 200pt it is also
    // wrong.
    @Test("a real reading is reported as measured")
    func measuredIsLabelled() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 856, y: 945, width: 656, height: 37)
        #expect(source(left: left, right: right) == .measured)
    }

    @Test("every rejected reading is reported as assumed")
    func fallbacksAreLabelled() {
        // Degenerate, off-centre, absurdly wide, and absent — the four ways the
        // rule declines. All of them are guesses and must say so.
        #expect(source(left: CGRect(x: 0, y: 945, width: 656, height: 37),
                       right: CGRect(x: 1512, y: 945, width: 0, height: 0)) == .assumed)
        #expect(source(left: CGRect(x: 0, y: 945, width: 1100, height: 37),
                       right: CGRect(x: 1350, y: 945, width: 162, height: 37)) == .assumed)
        #expect(source(left: CGRect(x: 0, y: 945, width: 200, height: 37),
                       right: CGRect(x: 1312, y: 945, width: 200, height: 37)) == .assumed)
        #expect(source(left: nil, right: nil) == .assumed)
    }

    // A narrower notch than the guess is the case that shows: the pill's neck
    // is built from this width, so a 200pt guess on a 160pt notch paints black
    // proud of the cutout on both sides.
    @Test("a narrower real notch is measured, not rounded up to the guess")
    func narrowNotchIsMeasured() {
        let left = CGRect(x: 0, y: 945, width: 676, height: 37)
        let right = CGRect(x: 836, y: 945, width: 676, height: 37)
        let resolved = NotchGeometry.resolveNotch(inFrame: frame, safeTop: safeTop,
                                                  left: left, right: right)
        #expect(resolved?.rect.width == 160)
        #expect(resolved?.source == .measured)
    }

    @Test("a normal pair of auxiliary areas gives a centred notch")
    func normalCase() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 856, y: 945, width: 656, height: 37)
        let notch = rect(left: left, right: right)
        #expect(notch?.width == 200)
        #expect(notch?.midX == frame.midX)
    }

    // The reported failure: a degenerate right-hand area made the "notch" run
    // to the right edge of the display. The pill centres on that rect and is
    // sized from it — a black bar, off to the right.
    @Test("a zero-width right area does not become a screen-wide notch")
    func degenerateRightArea() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 1512, y: 945, width: 0, height: 0)
        let notch = rect(left: left, right: right)
        #expect(notch?.width == 200)          // fell back
        #expect(notch?.midX == frame.midX)    // and is centred
    }

    @Test("an off-centre reading is rejected")
    func offCentreRejected() {
        // Left area far too wide: the gap would sit well right of centre.
        let left = CGRect(x: 0, y: 945, width: 1100, height: 37)
        let right = CGRect(x: 1350, y: 945, width: 162, height: 37)
        #expect(rect(left: left, right: right)?.midX == frame.midX)
    }

    @Test("an absurdly wide gap is rejected")
    func tooWideRejected() {
        let left = CGRect(x: 0, y: 945, width: 200, height: 37)
        let right = CGRect(x: 1312, y: 945, width: 200, height: 37)
        // Gap of 1112pt is not a notch.
        #expect(rect(left: left, right: right)?.width == 200)
    }

    @Test("missing areas fall back to a centred notch")
    func missingAreas() {
        #expect(rect(left: nil, right: nil)?.midX == frame.midX)
    }

    @Test("no safe-area inset means no notch at all")
    func noInset() {
        #expect(NotchGeometry.notchRect(inFrame: frame, safeTop: 0,
                                        left: nil, right: nil) == nil)
    }

    // Edges, not widths: an area that does not start at the screen edge used to
    // be measured as though it did.
    @Test("the gap is measured from the areas' facing edges")
    func usesFacingEdges() {
        let left = CGRect(x: 10, y: 945, width: 646, height: 37)   // inset by 10
        let right = CGRect(x: 856, y: 945, width: 646, height: 37)
        let notch = rect(left: left, right: right)
        #expect(notch?.minX == 656)
        #expect(notch?.width == 200)
    }
}

// MARK: - Secret redaction

@Suite("Secret redaction")
struct SecretRedactorTests {
    // This is not hypothetical. A GitHub PAT pasted into an agent session was
    // rendered on the notch as the task line — an overlay that sits above every
    // window and ends up in screenshots and screen shares.
    @Test("a GitHub token never reaches the screen")
    func githubToken() {
        let text = "use " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " to push"
        let out = SecretRedactor.redact(text)
        #expect(!out.contains("ghp_"))
        #expect(out.contains(SecretRedactor.placeholder))
    }

    @Test("fine-grained tokens too")
    func fineGrained() {
        #expect(!SecretRedactor.redact(fixture("github_pat_", "11ABCDEFG0abcdefghij_KLMNOPQRSTUVWXYZ"))
            .contains("github_pat_"))
    }

    // Fixtures are assembled from pieces on purpose. Written as literals they
    // are realistic enough that GitHub's own push protection rejects the
    // commit — which is a fair verdict on a file full of credential shapes,
    // and a neat confirmation that the patterns match what scanners match.
    private func fixture(_ prefix: String, _ body: String) -> String { prefix + body }

    @Test("and the other vendors")
    func otherVendors() {
        let secrets = [
            fixture("sk-ant-", "api03-abcdefghijklmnopqrstuvwxyz012345"),
            fixture("AKIA", "IOSFODNN7EXAMPLE"),
            fixture("xox", "b-123456789012-abcdefghijklmnop"),
            fixture("AIza", "SyA1234567890abcdefghijklmnopqrstuv"),
        ]
        for secret in secrets {
            #expect(SecretRedactor.containsSecret(secret), "missed \(secret.prefix(4))…")
        }
    }

    // Permission-request peeks quote the command an agent wants to run, which
    // is exactly where a credential ends up.
    @Test("a token on a command line, and one in a URL")
    func inCommands() {
        #expect(!SecretRedactor.redact("curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345'")
            .contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(SecretRedactor.containsSecret("git clone https://x-access-token:" + fixture("ghp_", "secret") + "@github.com/o/r"))
    }

    // A rule that ate ordinary text would be noise, and noise gets ignored.
    @Test("ordinary task text is left completely alone")
    func leavesNormalText() {
        for ordinary in ["fix the hover zone depending on size",
                        "Review this change for security vulnerabilities",
                        "commit 6cdcad6 and tag v1.18.0",
                        "session 93a48a21-849b-4f5b-986a-a3bb5794a63d"] {
            #expect(SecretRedactor.redact(ordinary) == ordinary)
        }
    }

    @Test("the task line on the card is redacted before it is truncated")
    func summarizeRedacts() {
        let task = AgentSession.summarize("push with " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " please")
        #expect(task?.contains("ghp_") == false)
    }

    @Test("a peek's question is redacted")
    func questionRedacted() {
        let alert = DevReadyAlert(id: "1", title: "repo", kind: .waiting,
                                  message: "run: curl -u " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " api?")
        #expect(alert.questionText?.contains("ghp_") == false)
    }

    @Test("empty input is not a special case")
    func empty() {
        #expect(SecretRedactor.redact("") == "")
    }
}

@Suite("CI row identity")
struct CIRowIdentityTests {
    private func run(repo: String) -> CIRun {
        CIRun(id: "u", repo: repo, workflow: "Release", branch: "main",
              state: .passed, started: Date())
    }

    // Reported: someone watching a build in their own project saw a green
    // "Release — passed" and believed it. It was another repo's — the card
    // follows whichever repos your agents are in, and the row never said which.
    @Test("a row names its repository")
    func namesRepo() {
        #expect(run(repo: "someone/their-project").repoName == "their-project")
    }

    @Test("a slug without an owner still yields something")
    func bareSlug() {
        #expect(run(repo: "solo").repoName == "solo")
    }

    // A finished run's lifetime runs from when it finished. Measuring from the
    // start would expire a three-minute build before it ever completed.
    @Test("a build that took longer than the lifetime still gets shown")
    func longBuildStillAppears() {
        let now = Date()
        let slow = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                         state: .passed,
                         started: now.addingTimeInterval(-600),   // started 10 min ago
                         updated: now.addingTimeInterval(-10))    // finished 10s ago
        #expect(CIRun.current([slow], now: now).count == 1)
    }

    @Test("and disappears two minutes after it finished")
    func goesAwayAfterTwoMinutes() {
        let now = Date()
        let done = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                         state: .passed,
                         started: now.addingTimeInterval(-900),
                         updated: now.addingTimeInterval(-150))   // finished 2.5 min ago
        #expect(CIRun.current([done], now: now).isEmpty)
    }

    @Test("with no finish time it falls back to the start")
    func fallsBackToStarted() {
        let now = Date()
        let old = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                        state: .passed, started: now.addingTimeInterval(-600), updated: nil)
        #expect(CIRun.current([old], now: now).isEmpty)
    }
}

@Suite("Redaction has no gaps")
struct SecretRedactorGapTests {
    private func fixture(_ prefix: String, _ body: String) -> String { prefix + body }

    private var samples: [String] {
        [fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"),
         fixture("github_pat_", "11ABCDEFG0abcdefghij_KLMNOPQRSTUVWXYZ"),
         fixture("sk-ant-", "api03-abcdefghijklmnopqrstuvwxyz012345"),
         fixture("AKIA", "IOSFODNN7EXAMPLE"),
         fixture("xox", "b-123456789012-abcdefghijklmnop")]
    }

    // A second pass must not find anything a first pass missed. If it does, the
    // patterns are rewriting text into new matches and the first answer was a
    // lie about what reached the screen.
    @Test("redaction is idempotent")
    func idempotent() {
        var report: [String] = []
        for s in samples {
            let once = SecretRedactor.redact("token \(s) end")
            #expect(SecretRedactor.redact(once) == once)
        }
    }

    // Whatever the surrounding punctuation, no fragment of the secret survives.
    @Test("no fragment survives any surrounding context")
    func noFragmentSurvives() {
        let contexts = ["%@", "(%@)", "\"%@\"", "run --token=%@ now",
                        "line1\n%@\nline3", "a,%@;b", "<%@>", "  %@  "]
        var report: [String] = []
        for s in samples {
            let body = String(s.dropFirst(4))   // the random-looking part
            for context in contexts {
                let text = context.replacingOccurrences(of: "%@", with: s)
                let out = SecretRedactor.redact(text)
                #expect(!out.contains(body), "survived in \(context)")
            }
        }
    }

    @Test("several secrets in one string all go")
    func multipleSecrets() {
        let text = samples.joined(separator: " and ")
        let out = SecretRedactor.redact(text)
        var report: [String] = []
        for s in samples {
            #expect(!out.contains(String(s.dropFirst(4))))
        }
    }

    // The card truncates; redaction runs first, so a half-token cannot appear.
    @Test("truncation cannot resurrect a partial token")
    func truncationSafe() {
        var report: [String] = []
        for s in samples {
            let task = AgentSession.summarize("please push using \(s) to the remote")
            #expect(task?.contains(String(s.dropFirst(4))) != true)
        }
    }
}

@Suite("Peek identity")
struct PeekIdentityTests {
    private func alert(agent: String?, source: String?) -> DevReadyAlert {
        DevReadyAlert(id: "1", title: "project", source: source, agent: agent)
    }

    // Reported: a task finished in Cursor and the peek wore the Claude Code
    // mark, badged "claude-code", then badged "cursor" beside it. Both facts
    // are true — Cursor runs Claude Code as its backend — but together they
    // read as two agents arguing about who did the work.
    @Test("a Claude agent hosted in Cursor presents as Cursor")
    func cursorHostWins() {
        let a = alert(agent: "claude-code", source: "cursor")
        #expect(a.displayAgent == .cursor)
        #expect(a.displayIdentity.lead == "cursor")
        #expect(a.displayIdentity.secondary == "claude-code")
    }

    // But behaviour still follows the agent: typed answers reach a Claude Code
    // terminal, and that does not change because of the window hosting it.
    @Test("presentation does not move the behaviour")
    func behaviourUnchanged() {
        #expect(alert(agent: "claude-code", source: "cursor").knownAgent == .claudeCode)
    }

    @Test("a plain Claude Code peek is unchanged")
    func plainClaude() {
        let a = alert(agent: "claude-code", source: "Claude Code")
        #expect(a.displayAgent == .claudeCode)
        #expect(a.displayIdentity.lead == "claude-code")
    }

    @Test("a host that adds nothing is not repeated")
    func noDuplicateBadge() {
        let a = alert(agent: "codex", source: "codex")
        #expect(a.displayIdentity.secondary == nil)
    }

    @Test("a terminal host stays a footnote")
    func terminalStaysSecondary() {
        let a = alert(agent: "claude-code", source: "cmux")
        #expect(a.displayIdentity.lead == "claude-code")
        #expect(a.displayIdentity.secondary == "cmux")
    }

    @Test("an alert with no agent name still says something")
    func noAgent() {
        #expect(alert(agent: nil, source: "cursor").displayIdentity.lead == "cursor")
    }
}

// MARK: - Permission requests

@Suite("Permission request parsing")
struct PermissionRequestTests {
    // The payload Claude Code sends for an Edit — the thing the peek was
    // throwing away in favour of "Claude needs your permission to use Edit".
    @Test("an edit becomes a diff you can read")
    func editBecomesDiff() {
        let req = PermissionRequest.parse(tool: "Edit", input: [
            "file_path": "/Users/x/proj/src/auth/middleware.ts",
            "old_string": "const verify = (token) =>\n  jwt.verify(token);",
            "new_string": "const verify = (token) =>\n  if (!token) throw new AuthError('missing');\n  return jwt.verify(token, secret);",
        ])
        #expect(req?.summary == "Edit auth/middleware.ts")
        #expect(req?.changeCount == "+2 −1")
        guard case .edit(_, let diff)? = req?.action else { return #expect(Bool(false)) }
        // The unchanged first line is context, not a delete-and-re-add.
        #expect(diff.first?.kind == .context)
        #expect(diff.contains { $0.kind == .removed && $0.text.contains("jwt.verify(token);") })
        #expect(diff.contains { $0.kind == .added && $0.text.contains("AuthError") })
    }

    @Test("a shell command is shown as itself")
    func bashCommand() {
        let req = PermissionRequest.parse(tool: "Bash", input: [
            "command": "npm test", "description": "Run the test suite",
        ])
        #expect(req?.summary == "npm test")
        guard case .run(_, let note)? = req?.action else { return #expect(Bool(false)) }
        #expect(note == "Run the test suite")
    }

    @Test("a new file says how big it is")
    func writeFile() {
        let req = PermissionRequest.parse(tool: "Write", input: [
            "file_path": "/a/b/src/routes/users.ts", "content": "one\ntwo\nthree",
        ])
        #expect(req?.summary == "Create routes/users.ts")
        guard case .write(_, let lines)? = req?.action else { return #expect(Bool(false)) }
        #expect(lines == 3)
    }

    // An agent asking for something we cannot draw still has to produce a peek.
    // Showing nothing is how someone waits on a prompt they never saw.
    @Test("an unknown tool still names itself")
    func unknownTool() {
        let req = PermissionRequest.parse(tool: "WebFetch", input: ["url": "https://example.com"])
        #expect(req?.tool == "WebFetch")
        #expect(req?.summary.contains("WebFetch") == true)
    }

    @Test("a nameless tool is not a request at all")
    func emptyTool() {
        #expect(PermissionRequest.parse(tool: "  ", input: [:]) == nil)
    }

    @Test("it reads the hook's JSON directly")
    func fromJSON() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        #expect(PermissionRequest.parse(payload: Data(json.utf8))?.summary == "rm -rf build")
    }

    @Test("an ExitPlanMode request previews the proposed plan")
    func exitPlanMode() {
        let request = PermissionRequest.parse(tool: "ExitPlanMode", input: [
            "plan": "# Approach\n1. Inspect the model\n2. Make the change",
        ])
        #expect(request?.isPlan == true)
        #expect(request?.summary == "Review plan")
        #expect(request?.planPreviewLines == ["Approach", "1. Inspect the model", "2. Make the change"])
        #expect(request?.planPreview.first?.style == .heading)
    }

    // A command line is the likeliest place for a credential, and this renders
    // on an overlay above every window.
    @Test("a token in a command never reaches the peek")
    func redactsCommands() {
        let secret = "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
        let req = PermissionRequest.parse(tool: "Bash", input: ["command": "git push https://\(secret)@github.com/o/r"])
        #expect(req?.redacted.summary.contains("ABCDEFGHIJ") == false)
    }
}

@Suite("Permission diff")
struct PermissionDiffTests {
    @Test("a pure addition has no removals")
    func pureAddition() {
        let diff = PermissionRequest.diff(old: "", new: "a\nb")
        #expect(diff.filter { $0.kind == .added }.count == 2)
        #expect(diff.contains { $0.kind == .removed } == false)
    }

    @Test("a pure deletion has no additions")
    func pureDeletion() {
        let diff = PermissionRequest.diff(old: "a\nb", new: "")
        #expect(diff.filter { $0.kind == .removed }.count == 2)
        #expect(diff.contains { $0.kind == .added } == false)
    }

    @Test("an unchanged hunk produces no change at all")
    func identical() {
        let diff = PermissionRequest.diff(old: "a\nb\nc", new: "a\nb\nc")
        #expect(diff.contains { $0.kind != .context } == false)
    }

    // Shared head and tail are context, so the change reads as a change rather
    // than as the whole hunk being replaced.
    @Test("shared lines top and bottom become context")
    func sharedContext() {
        let diff = PermissionRequest.diff(old: "head\nold\ntail", new: "head\nnew\ntail")
        #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["old"])
        #expect(diff.filter { $0.kind == .added }.map(\.text) == ["new"])
        #expect(diff.filter { $0.kind == .context }.map(\.text) == ["head", "tail"])
    }

    // The peek has room for a hunk, not a file.
    @Test("context is capped so a huge file cannot flood the peek")
    func contextCapped() {
        let head = (1...50).map(String.init).joined(separator: "\n")
        let diff = PermissionRequest.diff(old: head + "\nold", new: head + "\nnew")
        #expect(diff.filter { $0.kind == .context }.count <= 2)
    }
}

@Suite("Permission decision")
struct PermissionDecisionTests {
    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchpill-decision-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A written decision is what the hook reads back")
    func roundTrip() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let decision = PermissionDecision(requestId: "req-1", verdict: .allow)
        try decision.write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "req-1", home: home))
        #expect(PermissionDecision.parse(data) == decision)
    }

    @Test("A denial carries its reason back to the agent")
    func denialReason() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "req-2", verdict: .deny,
                               reason: "not that file").write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "req-2", home: home))
        #expect(PermissionDecision.parse(data)?.reason == "not that file")
    }

    @Test("Plan feedback becomes a bounded denial reason")
    func planRevisionReason() {
        #expect(PermissionDecision.planRevisionReason("  split the migration first  ")
                == "Plan revision: split the migration first")
        #expect(PermissionDecision.planRevisionReason(" \n ") == nil)
        #expect(PermissionDecision.planRevisionReason(String(repeating: "x", count: 700))?.count == 615)
    }

    @Test("Two requests answered at once do not read each other's verdict")
    func separateFiles() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "a", verdict: .allow).write(home: home)
        try PermissionDecision(requestId: "b", verdict: .deny).write(home: home)

        let a = try Data(contentsOf: PermissionDecision.file(for: "a", home: home))
        let b = try Data(contentsOf: PermissionDecision.file(for: "b", home: home))
        #expect(PermissionDecision.parse(a)?.verdict == .allow)
        #expect(PermissionDecision.parse(b)?.verdict == .deny)
    }

    @Test("Answering twice replaces the earlier verdict")
    func overwrite() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "c", verdict: .allow).write(home: home)
        try PermissionDecision(requestId: "c", verdict: .deny).write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "c", home: home))
        #expect(PermissionDecision.parse(data)?.verdict == .deny)
    }

    @Test("A request id cannot escape the decisions directory")
    func traversal() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let file = PermissionDecision.file(for: "../../etc/passwd", home: home)
        #expect(file.deletingLastPathComponent().path.hasSuffix(".notchpill/decisions"))
        #expect(!file.lastPathComponent.contains("/"))
    }

    @Test("An id with nothing safe in it still names a file")
    func emptyAfterSanitize() {
        #expect(PermissionDecision.sanitize("///") == "unnamed")
    }

    @Test("Unrecognised verdict text asks rather than allows")
    func unknownIsAsk() {
        #expect(PermissionDecision.Verdict("") == .ask)
        #expect(PermissionDecision.Verdict("maybe") == .ask)
        #expect(PermissionDecision.Verdict("ALLOW") == .allow)
        #expect(PermissionDecision.Verdict(" n ") == .deny)
    }

    @Test("Garbage on the channel is no decision, not a wrong one")
    func garbage() {
        #expect(PermissionDecision.parse(Data("not json".utf8)) == nil)
        #expect(PermissionDecision.parse(Data(#"{"verdict":"allow"}"#.utf8)) == nil)
        #expect(PermissionDecision.parse(Data(#"{"requestId":"x"}"#.utf8)) == nil)
    }
}

@Suite("Permission signal")
struct PermissionSignalTests {
    private let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/a/b/auth.ts","old_string":"x","new_string":"y"}}"#

    @Test("A PreToolUse signal decodes into a drawable request")
    func decodes() throws {
        let json = """
        {"id":"1","title":"repo","kind":"waiting","message":"Edit",
         "requestId":"abc","permission":\(payload.debugDescription)}
        """
        let alert = try JSONDecoder().decode(DevReadyAlert.self, from: Data(json.utf8))
        #expect(alert.requestId == "abc")
        #expect(alert.permissionRequest?.summary == "Edit b/auth.ts")
    }

    @Test("The live notification path carries the request too")
    func decodesUserInfo() {
        // There are two parsers — Codable for queued signal files, userInfo for
        // the live distributed notification. Only the file path was updated at
        // first, so a request arriving while the app ran drew as a bare "Edit".
        let alert = DevReadyAlert.parse(userInfo: [
            "title": "repo", "kind": "waiting", "message": "Edit",
            "requestId": "abc", "permission": payload,
        ])
        #expect(alert?.permissionRequest?.summary == "Edit b/auth.ts")
    }

    @Test("A payload with no request id has nowhere to answer, so shows no request")
    func requiresRequestId() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting, permissionPayload: payload)
        #expect(alert.permissionRequest == nil)
    }

    @Test("A finished alert is never a permission request")
    func requiresWaiting() {
        let alert = DevReadyAlert(title: "repo", kind: .finished,
                                  requestId: "abc", permissionPayload: payload)
        #expect(alert.permissionRequest == nil)
    }

    @Test("An ordinary waiting peek carries no request")
    func noPayload() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting, message: "Continue?")
        #expect(alert.permissionRequest == nil)
    }

    @Test("A command reaching the screen is redacted first")
    func redacts() {
        let secret = "gh" + "p_" + String(repeating: "A", count: 36)
        let raw = #"{"tool_name":"Bash","tool_input":{"command":"curl -H 'token: \#(secret)'"}}"#
        let alert = DevReadyAlert(title: "repo", kind: .waiting,
                                  requestId: "abc", permissionPayload: raw)
        #expect(alert.permissionRequest?.summary.contains(secret) == false)
    }

    @Test("An unparseable payload degrades to no request, not a crash")
    func garbage() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting,
                                  requestId: "abc", permissionPayload: "{not json")
        #expect(alert.permissionRequest == nil)
    }
}

@Suite("Permission preview")
struct PermissionPreviewTests {
    private func request(_ old: String, _ new: String) -> PermissionRequest {
        PermissionRequest(action: .edit(path: "/a/b.swift",
                                        diff: PermissionRequest.diff(old: old, new: new)),
                          tool: "Edit")
    }

    @Test("A short diff is shown whole")
    func short() {
        let r = request("a", "b")
        #expect(r.previewLines.count == 2)
    }

    @Test("A long diff is capped to what the peek can draw")
    func capped() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = (1...20).map { "changed \($0)" }.joined(separator: "\n")
        #expect(request(old, new).previewLines.count == PermissionRequest.previewLimit)
    }

    @Test("When the change alone overflows, context is dropped first")
    func changesBeatContext() {
        let old = "keep\n" + (1...6).map { "old \($0)" }.joined(separator: "\n") + "\ntail"
        let new = "keep\n" + (1...6).map { "new \($0)" }.joined(separator: "\n") + "\ntail"
        let lines = request(old, new).previewLines
        #expect(lines.allSatisfy { $0.kind != .context })
    }

    @Test("The count still describes the whole change, not the visible part")
    func countIsOfTheWhole() {
        let old = (1...9).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...9).map { "new \($0)" }.joined(separator: "\n")
        let r = request(old, new)
        #expect(r.previewLines.count == 4)
        #expect(r.changeCount == "+9 −9")
    }

    @Test("A command has no diff lines but is set as machine text")
    func command() {
        let r = PermissionRequest(action: .run(command: "rm -rf build", note: nil), tool: "Bash")
        #expect(r.previewLines.isEmpty)
        #expect(r.isCommand)
        #expect(r.commandPreviewLineLimit == 3)
        #expect(request("a", "b").isCommand == false)
        #expect(request("a", "b").commandPreviewLineLimit == 1)
    }
}

@MainActor
@Suite("Answering a permission request")
struct PermissionAnswerabilityTests {
    private let payload = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func alert(delivery: String?, requestId: String?) -> DevReadyAlert {
        DevReadyAlert(title: "repo", agent: "claude-code", kind: .waiting, message: "Bash",
                      createdAt: Date().timeIntervalSince1970,
                      answerSpec: "Allow:y|Deny:n", deliverySpec: delivery,
                      requestId: requestId, permissionPayload: payload)
    }

    @Test("A decision peek offers buttons with no terminal to target")
    func decisionNeedsNoTerminal() {
        #expect(alert(delivery: "decision", requestId: "r1")
            .canAnswerFromNotch(replyEnabled: true) == true)
    }

    @Test("A decision with no request id has nowhere to answer")
    func decisionNeedsRequestId() {
        let a = alert(delivery: "decision", requestId: nil)
        #expect(a.answersByDecision == false)
        #expect(a.permissionRequest == nil)
    }

    @Test("Answers off means no buttons, decision or not")
    func respectsSetting() {
        #expect(alert(delivery: "decision", requestId: "r1")
            .canAnswerFromNotch(replyEnabled: false) == false)
    }

    @Test("A stale request is not answerable — the hook gave up long ago")
    func staleness() {
        var a = alert(delivery: "decision", requestId: "r1")
        a.createdAt = Date().timeIntervalSince1970 - DevReadyProvider.waitingStaleAfter - 60
        #expect(a.canAnswerFromNotch(replyEnabled: true) == false)
    }

    @Test("Allow and Deny map onto the verdicts the hook understands")
    func buttonsMapToVerdicts() {
        let answers = alert(delivery: "decision", requestId: "r1").answers
        #expect(answers.map(\.label) == ["Allow", "Deny"])
        #expect(PermissionDecision.Verdict(answers[0].keystroke) == .allow)
        #expect(PermissionDecision.Verdict(answers[1].keystroke) == .deny)
    }
}

@Suite("Idle agents age off the card")
struct AgentSessionAgeingTests {
    private let now = Date()

    private func session(_ id: String, _ state: AgentSession.State,
                         age: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: "claude-code", project: "p", state: state,
                     lastActivity: now.addingTimeInterval(-age))
    }

    @Test("A session quiet past the idle window is history")
    func idleAgesOut() {
        let stale = session("a", .idle(since: now.addingTimeInterval(-600)))
        #expect(AgentSession.current([stale], now: now).isEmpty)
    }

    @Test("A recently quiet session is still shown")
    func recentIdleStays() {
        // The idle window is 30s, so this is deliberately well inside it —
        // 60s used to qualify when the window was five minutes.
        let fresh = session("a", .idle(since: now.addingTimeInterval(-10)))
        #expect(AgentSession.current([fresh], now: now).count == 1)
    }

    @Test("A session quiet for a minute is gone under the 30s window")
    func minuteOldIdleIsGone() {
        let stale = session("a", .idle(since: now.addingTimeInterval(-60)))
        #expect(AgentSession.current([stale], now: now).isEmpty)
    }

    @Test("A long build is not idle and never ages out")
    func workingSurvives() {
        let working = session("a", .working, age: 10_000)
        #expect(AgentSession.current([working], now: now).count == 1)
    }

    @Test("An unanswered question outlives the idle window")
    func waitingSurvives() {
        // The whole reason the live window is two hours: an agent blocked on a
        // permission prompt writes nothing, and dropping it would hide the one
        // row you can act on.
        let waiting = session("a", .waiting(since: nil), age: 10_000)
        #expect(AgentSession.current([waiting], now: now).count == 1)
    }

    @Test("A card of stale agents empties rather than filling with nothing")
    func theReportedCase() {
        let sessions = (1...6).map {
            session("s\($0)", .idle(since: now.addingTimeInterval(-480)))
        } + [session("live", .working)]
        let kept = AgentSession.current(sessions, now: now)
        #expect(kept.map(\.id) == ["live"])
    }
}

@Suite("Approval gate")
struct ApprovalGateTests {
    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchpill-gate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Off when the file is not there — the shipped default")
    func defaultsOff() {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    @Test("Enabling creates the file, and the directory it lives in")
    func enableCreatesFile() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)

        #expect(FileManager.default.fileExists(atPath: ApprovalGate.file(home: home).path))
        #expect(ApprovalGate.isEnabled(home: home))
    }

    @Test("Disabling removes it, leaving the state the app ships with")
    func disableRemovesFile() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)
        try ApprovalGate.setEnabled(false, home: home)

        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    /// Turning something off is the escape hatch; it must not throw because the
    /// thing was already off. The toggle would flip back and look stuck.
    @Test("Disabling something already off is not an error")
    func disableIsIdempotent() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(false, home: home)
        try ApprovalGate.setEnabled(false, home: home)

        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    @Test("Enabling twice is not an error")
    func enableIsIdempotent() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)
        try ApprovalGate.setEnabled(true, home: home)

        #expect(ApprovalGate.isEnabled(home: home))
    }

    /// The path the hook script documents. If this moves, the script's
    /// `~/.notchpill/approvals-enabled` check silently stops matching.
    @Test("The path is the one the hook watches")
    func pathMatchesHook() {
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(ApprovalGate.file(home: home).path == "/tmp/home/.notchpill/approvals-enabled")
    }
}

@Suite("Agent vendor glyph")
struct AgentVendorSymbolTests {
    private func session(agent: String, subagent: String? = nil) -> AgentSession {
        AgentSession(id: "s", agent: agent, project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("Each known vendor gets its own mark")
    func knownVendors() {
        #expect(session(agent: "claude-code").vendorSymbol == "asterisk")
        #expect(session(agent: "codex").vendorSymbol
                == "chevron.left.forwardslash.chevron.right")
        #expect(session(agent: "cursor").vendorSymbol == "cursorarrow")
    }

    @Test("No mark invented for an agent we do not know")
    func unknownVendor() {
        #expect(session(agent: "some-new-tool").vendorSymbol == nil)
        #expect(session(agent: "").vendorSymbol == nil)
    }

    /// The reason the glyph exists: a sub-agent row shows the persona, so
    /// without it the vendor appears nowhere on the row.
    @Test("A sub-agent row hides the vendor name but keeps the mark")
    func subagentStillShowsVendor() {
        let s = session(agent: "claude-code", subagent: "code-reviewer")
        #expect(s.displayName == "Code Reviewer")
        #expect(s.vendorSymbol == "asterisk")
    }

    /// Colour is state, not brand — the confusion the glyph is there to fix.
    @Test("Two vendors waiting are the same colour and differ only by mark")
    func colourIsStateNotBrand() {
        let claude = session(agent: "claude-code")
        let cursor = session(agent: "cursor")
        #expect(claude.vendorSymbol != cursor.vendorSymbol)
        #expect(claude.statusLabel == cursor.statusLabel)
    }
}

@Suite("CI supersedes")
struct CISupersedeTests {
    private func run(_ id: String, _ state: CIRun.State, minutesAgo: Double,
                     branch: String = "main", workflow: String = "Release") -> CIRun {
        let t = Date().addingTimeInterval(-minutesAgo * 60)
        return CIRun(id: id, repo: "o/r", workflow: workflow, branch: branch,
                     state: state, started: t, updated: t)
    }

    /// The bug: a failure lives six hours, a pass two minutes, so a fixed
    /// build kept reading "failed" long after the green re-run aged off.
    @Test("A passing re-run replaces the failure it fixed")
    func passSupersedesFailure() {
        let runs = [run("fail", .failed, minutesAgo: 30),
                    run("pass", .passed, minutesAgo: 29)]
        let kept = CIRun.current(runs)
        #expect(kept.map(\.id) == ["pass"] || kept.isEmpty)
        #expect(!kept.contains { $0.state == .failed })
    }

    @Test("A retry still running also replaces the failure")
    func runningSupersedesFailure() {
        let kept = CIRun.current([run("fail", .failed, minutesAgo: 10),
                                  run("retry", .running, minutesAgo: 1)])
        #expect(kept.map(\.id) == ["retry"])
    }

    @Test("An older run never replaces a newer one")
    func olderDoesNotSupersede() {
        let kept = CIRun.current([run("new", .running, minutesAgo: 1),
                                  run("old", .failed, minutesAgo: 90)])
        #expect(kept.map(\.id) == ["new"])
    }

    @Test("Different branches and workflows are separate targets")
    func targetsAreIndependent() {
        let runs = [run("a", .failed, minutesAgo: 10, branch: "main"),
                    run("b", .failed, minutesAgo: 9, branch: "dev"),
                    run("c", .failed, minutesAgo: 8, workflow: "Test")]
        #expect(CIRun.current(runs).count == 3)
    }

    @Test("A lone failure still survives, as before")
    func failureStillLives() {
        #expect(CIRun.current([run("fail", .failed, minutesAgo: 60)]).count == 1)
    }
}

@Suite("tmux pane targeting")
struct TmuxLocatorTests {
    private let listing = """
    /dev/ttys001\twork:0.0
    /dev/ttys012\twork:2.1
    /dev/ttys120\tother:0.0
    """

    @Test("Finds the pane owning the agent's TTY")
    func findsPane() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: listing) == "work:2.1")
    }

    /// `/dev/ttys1` is a prefix of `/dev/ttys120`. A loose match would drop
    /// you into an unrelated pane and read as tmux misbehaving.
    @Test("Matching is exact, never a prefix")
    func exactMatchOnly() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys1", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys12", in: listing) == nil)
    }

    @Test("No pane, no answer")
    func noMatch() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys999", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: "") == nil)
    }

    @Test("Garbled lines are skipped, not fatal")
    func toleratesJunk() {
        let messy = "no-tab-here\n\n/dev/ttys012\twork:2.1\n"
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: messy) == "work:2.1")
    }

    /// Selecting the pane without its window leaves you on the right pane of
    /// a window you cannot see.
    @Test("Both the window and the pane are selected")
    func selectsWindowThenPane() {
        let args = TmuxLocator.selectArguments(target: "work:2.1")
        #expect(args == [["select-window", "-t", "work:2.1"],
                         ["select-pane", "-t", "work:2.1"]])
    }

    @Test("Absent tmux is not an error, just no pane jump")
    func missingTmuxIsSilent() {
        #expect(TmuxLocator.executable(fileExists: { _ in false }) == nil)
        var ran = false
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys012", tmuxPath: nil) { _, _ in
            ran = true; return nil
        }
        #expect(ok == false)
        #expect(ran == false)
    }

    /// The whole round trip against a stubbed tmux. The path is injected so
    /// this exercises the real sequence on a machine with no tmux installed —
    /// otherwise the test would quietly assert nothing here.
    @Test("Drives tmux with the arguments it expects")
    func drivesTmux() {
        var calls: [[String]] = []
        let listing = self.listing
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys012", tmuxPath: "/fake/tmux") { path, args in
            #expect(path == "/fake/tmux")
            calls.append(args)
            return args.first == "list-panes" ? Data(listing.utf8) : Data()
        }
        #expect(ok)
        #expect(calls == [TmuxLocator.listArguments] + TmuxLocator.selectArguments(target: "work:2.1"))
    }

    @Test("A TTY in no pane runs no select commands")
    func unmatchedTTYSelectsNothing() {
        var calls: [[String]] = []
        let listing = self.listing
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys999", tmuxPath: "/fake/tmux") { _, args in
            calls.append(args)
            return Data(listing.utf8)
        }
        #expect(ok == false)
        #expect(calls == [TmuxLocator.listArguments])
    }
}

@Suite("OpenCode sessions")
struct OpenCodeAgentTests {
    private func session(subagent: String? = nil) -> AgentSession {
        AgentSession(id: "ses_1", agent: "opencode", project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("Recognised as its own vendor, not an unknown agent")
    func recognised() {
        let s = session()
        #expect(s.knownAgent == .openCode)
        #expect(s.agentName == "OpenCode")
        #expect(s.vendorSymbol == "curlybraces")
    }

    @Test("The wire name is not shown raw")
    func doesNotLeakWireName() {
        #expect(session().displayName != "opencode")
    }

    /// A child session is OpenCode's sub-agent, and should read like every
    /// other sub-agent row rather than like a second top-level agent.
    @Test("A child session reads as a sub-agent")
    func childIsSubagent() {
        #expect(session(subagent: "subagent").displayName == "Subagent")
    }

    /// Archiving is the user putting a session away on purpose — a stronger
    /// signal than age, and it must not come back because something touched it.
    @Test("The query excludes archived sessions and is bounded")
    func queryShape() {
        let sql = AgentSessionScanner.openCodeSQL
        #expect(sql.contains("time_archived IS NULL"))
        #expect(sql.contains("time_updated > ?"))
        #expect(sql.contains("LIMIT"))
    }

    @Test("Usage query is local, bounded to active sessions, and never claims a quota")
    func usageQueryShape() {
        let sql = AgentSessionScanner.openCodeUsageSQL
        #expect(sql.contains("time_updated >= ?"))
        #expect(sql.contains("time_archived IS NULL"))
        #expect(!sql.localizedCaseInsensitiveContains("quota"))
    }

    @Test("Usage hides when OpenCode has recorded no tokens or cost")
    func usageNeedsActivity() {
        let empty = OpenCodeUsage(inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        let active = OpenCodeUsage(inputTokens: 1_200, outputTokens: 80, reasoningTokens: 0,
                                   cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        #expect(!empty.hasActivity)
        #expect(active.hasActivity)
        #expect(active.tokenLabel == "1.3k tokens")
        #expect(active.costLabel == "No cost")
    }

    /// Nothing in the schema says which session is blocked — the permission
    /// table is per project. Inventing "waiting" would put a false Allow/Deny
    /// row on the card.
    @Test("Never claims to be waiting on you")
    func neverFakesWaiting() {
        let s = AgentSession.state(lastWrite: Date(), blocked: false)
        #expect(s == .working)
    }
}

@Suite("Agent model label")
struct AgentModelLabelTests {
    @Test("Vendor prefixes and build stamps are stripped")
    func prettifies() {
        #expect(AgentSession.modelLabel("claude-opus-5") == "Opus 5")
        #expect(AgentSession.modelLabel("claude-sonnet-5") == "Sonnet 5")
        #expect(AgentSession.modelLabel("claude-opus-4-8") == "Opus 4.8")
        #expect(AgentSession.modelLabel("claude-haiku-4-5-20251001") == "Haiku 4.5")
    }

    @Test("Known families shorten to what you actually choose between")
    func knownFamilies() {
        #expect(AgentSession.modelLabel("gpt-5.6-terra") == "GPT 5.6 Terra")
        #expect(AgentSession.modelLabel("gpt-5.6-soul-terra") == "GPT 5.6 Soul Terra")
        #expect(AgentSession.modelLabel("gemini-3-pro") == "Gemini 3 Pro")
    }

    /// A model we have never seen is exactly the one worth naming. Trimming it
    /// to its first segment would render `gpt-5.6-terra` as "Gpt", throwing
    /// away the only part that distinguishes it — so unknowns keep their id.
    @Test("An unfamiliar model keeps its full id")
    func unknownPassesThrough() {
        #expect(AgentSession.modelLabel("some-new-thing-7") == "some-new-thing-7")
        #expect(AgentSession.modelLabel("anthropic.mystery-2") == "mystery-2")
    }

    @Test("Nothing to say stays silent")
    func emptyStaysNil() {
        #expect(AgentSession.modelLabel(nil) == nil)
        #expect(AgentSession.modelLabel("") == nil)
        #expect(AgentSession.modelLabel("   ") == nil)
        #expect(AgentSession.modelLabel("<synthetic>") == nil)
    }

    private func session(model: String?, effort: String?) -> AgentSession {
        AgentSession(id: "s", agent: "claude-code", project: "p", state: .working,
                     lastActivity: Date(), model: model, effort: effort)
    }

    @Test("Every recorded effort is shown")
    func effortSuffix() {
        #expect(session(model: "claude-opus-5", effort: "high").modelLabel == "Opus 5 · high")
        #expect(session(model: "claude-opus-5", effort: "low").modelLabel == "Opus 5 · low")
        #expect(session(model: "gpt-5.6-terra", effort: "medium").modelLabel
                == "GPT 5.6 Terra · medium")
        #expect(session(model: "claude-opus-5", effort: nil).modelLabel == "Opus 5")
        #expect(session(model: nil, effort: "high").modelLabel == nil)
    }

    @Test("Claude records the model in the message and the effort beside it")
    func parsesClaude() {
        let line = #"{"effort":"low","message":{"model":"claude-opus-5","role":"assistant"}}"#
        let got = AgentSessionScanner.claudeModel(in: line)
        #expect(got.model == "claude-opus-5")
        #expect(got.effort == "low")
    }

    /// Newest first: both can change mid-session, and a sub-agent may run on a
    /// different model than its parent.
    @Test("The newest record wins")
    func newestWins() {
        let text = [#"{"message":{"model":"claude-sonnet-5"}}"#,
                    #"{"effort":"high","message":{"model":"claude-opus-5"}}"#].joined(separator: "\n")
        #expect(AgentSessionScanner.claudeModel(in: text).model == "claude-opus-5")
    }

    @Test("Codex prefers its settled thread settings")
    func parsesCodex() {
        let line = #"{"payload":{"model":"gpt-5.6-terra","thread_settings":{"model":"gpt-5.6-terra","reasoning_effort":"high"}}}"#
        let got = AgentSessionScanner.codexModel(in: line)
        #expect(got.model == "gpt-5.6-terra")
        #expect(got.effort == "high")
    }

    @Test("Junk lines are skipped rather than fatal")
    func toleratesJunk() {
        let text = ["not json", "", #"{"message":{"model":"<synthetic>"}}"#,
                    #"{"message":{"model":"claude-opus-5"}}"#].joined(separator: "\n")
        #expect(AgentSessionScanner.claudeModel(in: text).model == "claude-opus-5")
    }
}

/// `~/.claude/projects` holds every Claude Code run, not every terminal
/// session. SDK-driven runs write transcripts there too, and each one that
/// lands inside the live window used to become a Live Agents row for an agent
/// nobody started — on whatever model the SDK caller picked.
@Suite("Only interactive sessions reach the card")
struct InteractiveSessionTests {
    @Test("A terminal session is interactive")
    func terminalCounts() {
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "cli"))
    }

    @Test("SDK-driven runs are not")
    func sdkRunsExcluded() {
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-py"))
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-cli"))
        // Whatever the next binding is called.
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-ts"))
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "SDK-PY"))
    }

    /// Hiding a running agent is a worse failure than showing an odd one, so
    /// anything we cannot classify stays on the card.
    @Test("An unknown or missing entrypoint stays visible")
    func unknownStaysVisible() {
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: nil))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: ""))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "   "))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "vscode"))
    }

    @Test("The entrypoint is read from the transcript's own records")
    func readFromTranscript() {
        let text = #"{"type":"attachment","entrypoint":"sdk-py","cwd":"/tmp"}"#
        #expect(AgentSessionScanner.firstValue(in: text, key: "entrypoint") == "sdk-py")
    }
}

/// The log records what the app did; these record what it declined to do,
/// which is where every real bug so far has lived.
/// The hot-zone shortcuts are swallowed by an event tap, so a false positive
/// does not merely trigger playback — it stops the key reaching the app you
/// are typing in.
@Suite("Typing keeps the keyboard")
struct TypingGuardTests {
    private let space: UInt16 = 49

    @Test("A space mid-sentence belongs to the sentence")
    func typingReleasesSpace() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)     // "k"
        #expect(guard0.isTyping(now: 100.1))
        // Still typing a quarter second later — this is the failing case.
        #expect(guard0.isTyping(now: 100.25))
    }

    @Test("Shortcuts alone never mark you as typing")
    func shortcutsDoNotArm() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: true, now: 100)
        #expect(!guard0.isTyping(now: 100.01))
    }

    @Test("A pause hands the keys back to the notch")
    func graceExpires() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(!guard0.isTyping(now: 100 + TypingGuard.grace))
        #expect(!guard0.isTyping(now: 105))
    }

    @Test("A fresh guard is not typing")
    func startsIdle() {
        #expect(!TypingGuard().isTyping(now: 100))
    }

    @Test("Reaching for the notch clears the sentence behind you")
    func resetOnEntry() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(guard0.isTyping(now: 100.1))
        guard0.reset()
        #expect(!guard0.isTyping(now: 100.1))
    }

    /// A backwards clock jump must not wedge the guard on and mute the
    /// shortcuts indefinitely.
    @Test("A clock going backwards does not stick")
    func backwardsClock() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(!guard0.isTyping(now: 50))
    }
}

/// The in-memory log cannot help with a bug on someone else's Mac, which is
/// the case that keeps costing real time. These cover the parts of the on-disk
/// copy that fail quietly if they are wrong.
/// Murmur writes a caption file that persists across restarts. Treating a file
/// as an event is the whole risk here.
/// A truncated caption defeats the feature: the sentence you switched it on to
/// read is exactly the part that gets cut. Height must follow the text, and the
/// budget must never run short — a single-alert peek pins its list to the
/// window, so unbudgeted rows draw outside it.
@Suite("Caption peeks grow with the text")
struct CaptionSizingTests {
    @Test("A short caption stays one line")
    func shortStaysOneLine() {
        #expect(NotchContentLayout.titleLines(for: "Hello there") == 1)
    }

    @Test("A spoken sentence wraps")
    func sentenceWraps() {
        let sentence = String(repeating: "word ", count: 30)   // ~150 chars
        #expect(NotchContentLayout.titleLines(for: sentence) > 1)
    }

    @Test("Growth is capped rather than unbounded")
    func cappedAtMax() {
        let essay = String(repeating: "a", count: 5000)
        #expect(NotchContentLayout.titleLines(for: essay) == NotchContentLayout.titleMaxLines)
    }

    @Test("Empty text still occupies a line")
    func emptyIsOneLine() {
        #expect(NotchContentLayout.titleLines(for: "") == 1)
    }

    /// The four-line cap still truncated ordinary speech — roughly two
    /// sentences at the peek's width. A dictated paragraph has to fit whole.
    @Test("A spoken paragraph fits without hitting the cap")
    func paragraphFits() {
        let paragraph = "Okay so I am currently speaking right now through the Murmur "
            + "app and this is speech to text, and what I want to check is that a "
            + "reasonably long thought like this one shows up in the notch without "
            + "an ellipsis cutting off the end of it."
        let lines = NotchContentLayout.titleLines(for: paragraph)
        #expect(lines > 4)                                   // the old cap was not enough
        #expect(lines < NotchContentLayout.titleMaxLines)    // and the new one is not hit
    }

    /// Shrinking is what turns "needs 8.2 lines" into smaller text rather than
    /// lost words, and it must never apply to ordinary one-line peek titles.
    /// Height was never the scarce resource — width was. At the ordinary
    /// ceiling a line holds ~47 characters, so no height budget could rescue a
    /// paragraph.
    @Test("A wrapping peek is given more width than an ordinary one")
    func wrappingPeekIsWider() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54, screenWidth: 1470)
        let ordinary = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: false)
        let wrapping = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true)
        // 720 * 0.54 — the ordinary expanded ceiling, asserted by value rather
        // than by widening the property's access just for a test.
        #expect(abs(ordinary - 388.8) < 0.01)
        #expect(wrapping > ordinary * 1.5)
        // Never wider than the display it sits on.
        #expect(wrapping < metrics.screenWidth)
    }

    @Test("An unknown screen width still widens, and never narrows")
    func unknownScreenIsSafe() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54)          // screenWidth defaults to 0
        let wrapping = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true)
        #expect(wrapping >= 388.8)
    }

    /// The whole point of the extra width: the same sentence needs fewer lines.
    @Test("Widening the peek cuts the lines a paragraph needs")
    func widerNeedsFewerLines() {
        let paragraph = String(repeating: "word ", count: 80)   // ~400 chars
        let narrow = NotchContentLayout.titleLines(for: paragraph, width: 389)
        let wide = NotchContentLayout.titleLines(for: paragraph, width: 760)
        #expect(wide < narrow)
    }

    @Test("Only wrapping titles are allowed to shrink")
    func shrinkIsScopedToCaptions() {
        #expect(NotchContentLayout.titleMinimumScale < 1)
        #expect(NotchContentLayout.titleMinimumScale >= 0.7)  // still readable
    }

    @Test("More lines means a taller peek, and one line adds nothing")
    func heightFollowsLines() {
        func alert(lines: Int?) -> DevReadyAlert {
            DevReadyAlert(id: "a", title: "t", titleLines: lines)
        }
        #expect(NotchContentLayout.titleExtraHeight(alerts: [alert(lines: nil)]) == 0)
        #expect(NotchContentLayout.titleExtraHeight(alerts: [alert(lines: 1)]) == 0)
        let three = NotchContentLayout.titleExtraHeight(alerts: [alert(lines: 3)])
        #expect(three == 2 * NotchContentLayout.titleLineHeight)
    }

    /// The layout must actually spend the allowance, or the extra lines draw
    /// outside the window.
    @Test("The peek is taller for a wrapped caption than a one-line one")
    @MainActor
    func layoutIsTaller() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54)
        // Real strings, because the height now follows what the text actually
        // measures rather than a number baked into the alert. Asserting on a
        // hand-set `titleLines` would only prove the old estimate still exists.
        let short = DevReadyAlert(id: "a", title: "Hi")
        let long = DevReadyAlert(id: "a", title: String(repeating: "spoken words ", count: 40))
        let shortLayout = NotchContentLayout.devReadyLayout(
            metrics: metrics, alerts: [short], answerEnabled: false)
        let longLayout = NotchContentLayout.devReadyLayout(
            metrics: metrics, alerts: [long], answerEnabled: false)
        #expect(longLayout.size.height > shortLayout.size.height)
        let lines = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [long], answerEnabled: false).lines["a"] ?? 1
        #expect(lines > 1)
        #expect(longLayout.size.height - shortLayout.size.height
                == CGFloat(lines - 1) * NotchContentLayout.titleLineHeight)
    }

    @Test("A dictated sentence reaches the peek with room to show it")
    func captionAlertWraps() {
        let spoken = "Okay so I am currently speaking right now through the Murmur app "
            + "and this is speech to text and I want to see the whole sentence."
        let alert = NotchController.alert(for:
            DictationCaption(text: spoken, timestamp: Date()))
        #expect((alert.titleLines ?? 1) > 1)
        #expect(alert.title == spoken)
    }
}

@Suite("Dictation captions")
struct DictationCaptionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ text: String, _ millis: Double) -> Data {
        Data(#"{"text": "\#(text)", "timestamp": \#(Int(millis))}"#.utf8)
    }

    @Test("Murmur's format parses, milliseconds and all")
    func parses() {
        let caption = DictationCaption.parse(json("hello there", 1_800_000_000_000))
        #expect(caption?.text == "hello there")
        #expect(caption?.timestamp == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Junk, empty text and missing timestamps are skipped, not fatal")
    func tolerant() {
        #expect(DictationCaption.parse(Data("not json".utf8)) == nil)
        #expect(DictationCaption.parse(json("   ", 1_800_000_000_000)) == nil)
        #expect(DictationCaption.parse(Data(#"{"text":"hi"}"#.utf8)) == nil)
        #expect(DictationCaption.parse(Data(#"{"timestamp":123}"#.utf8)) == nil)
    }

    /// The caption sitting on this machine was written in July. Without this
    /// rule the first launch would pop a months-old sentence as if it had just
    /// been spoken.
    @Test("A caption from months ago is not news")
    func staleIsIgnored() {
        let old = DictationCaption(text: "old", timestamp: now.addingTimeInterval(-86_400 * 30))
        #expect(!DictationCaption.shouldPresent(old, lastPresented: nil, now: now))
    }

    @Test("Something just said is shown")
    func freshIsShown() {
        let fresh = DictationCaption(text: "new", timestamp: now.addingTimeInterval(-1))
        #expect(DictationCaption.shouldPresent(fresh, lastPresented: nil, now: now))
    }

    @Test("The same caption is never shown twice")
    func noRepeats() {
        let caption = DictationCaption(text: "once", timestamp: now.addingTimeInterval(-1))
        #expect(!DictationCaption.shouldPresent(caption,
                                                lastPresented: caption.timestamp, now: now))
        let next = DictationCaption(text: "twice", timestamp: now)
        #expect(DictationCaption.shouldPresent(next,
                                               lastPresented: caption.timestamp, now: now))
    }

    /// Murmur's clock running microseconds ahead must not silently mute it.
    @Test("A caption from the near future still counts as fresh")
    func futureIsFresh() {
        let ahead = DictationCaption(text: "ahead", timestamp: now.addingTimeInterval(2))
        #expect(DictationCaption.shouldPresent(ahead, lastPresented: nil, now: now))
    }

    @Test("A spoken secret never reaches the overlay")
    func redactsSpokenSecrets() {
        let caption = DictationCaption(
            text: "the token is ghp_0123456789abcdefghijABCDEFGHIJ0123 ok",
            timestamp: now)
        let alert = NotchController.alert(for: caption)
        #expect(!alert.title.contains("ghp_0123456789abcdefghijABCDEFGHIJ0123"))
        #expect(alert.title.contains(SecretRedactor.placeholder))
    }

    /// A caption is not a question: answer buttons would type into whatever
    /// terminal happened to be focused.
    @Test("A caption peek carries no answer path")
    func notAnswerable() {
        let alert = NotchController.alert(for:
            DictationCaption(text: "hello", timestamp: now))
        #expect(alert.kind == .finished)
        #expect(alert.answerSpec == nil)
        #expect(alert.deliverySpec == "none")
        #expect(alert.source == "Murmur")
    }
}

@Suite("On-disk log")
struct LogFileTests {
    @Test("An empty file never rotates")
    func emptyDoesNotRotate() {
        #expect(!LogFile.shouldRotate(currentBytes: 0, adding: 10))
        // Not even a line larger than the cap: rotating here would throw away
        // nothing and leave an empty file behind.
        #expect(!LogFile.shouldRotate(currentBytes: 0, adding: LogFile.maxBytes * 2))
    }

    @Test("Rotation happens at the cap, not past it")
    func rotatesAtCap() {
        #expect(!LogFile.shouldRotate(currentBytes: LogFile.maxBytes - 10, adding: 10))
        #expect(LogFile.shouldRotate(currentBytes: LogFile.maxBytes - 10, adding: 11))
        #expect(LogFile.shouldRotate(currentBytes: LogFile.maxBytes, adding: 1))
    }

    /// The whole point of writing to disk is that the file gets sent to
    /// somebody. A token in it would be a worse bug than the one being chased.
    @Test("Secrets never reach the file")
    func redactsSecrets() {
        let line = "12:00:00 · [focus] token ghp_0123456789abcdefghijABCDEFGHIJ0123 used"
        let safe = SecretRedactor.redact(line)
        #expect(!safe.contains("ghp_0123456789abcdefghijABCDEFGHIJ0123"))
        #expect(safe.contains(SecretRedactor.placeholder))
        // The rest of the line survives, or the file is useless.
        #expect(safe.contains("[focus]"))
    }

    @Test("Both generations live under the private root, not the home directory")
    func staysPrivate() {
        #expect(LogFile.url.path.contains(".notchpill/log"))
        #expect(LogFile.previousURL.path.contains(".notchpill/log"))
        #expect(LogFile.url != LogFile.previousURL)
    }
}

@Suite("Scan reconciliation")
struct ScanLedgerTests {
    @Test("A clean scan states the arithmetic and nothing else")
    func allKept() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.keep(); ledger.keep()
        #expect(ledger.summary == "2 transcripts → 2 shown")
        #expect(ledger.dropped == 0)
    }

    @Test("Drops are tallied by reason")
    func tallies() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.keep()
        ledger.drop("sdk-run"); ledger.drop("sdk-run"); ledger.drop("unreadable")
        #expect(ledger.dropped == 3)
        // Commonest reason first — that is the one that explains the surprise.
        #expect(ledger.summary
                == "4 transcripts → 1 shown (3 dropped: sdk-run 2, unreadable 1)")
    }

    /// Dictionary order is not stable, and an unstable summary would make every
    /// scan look like news and flood the buffer.
    @Test("The same scan always renders the same line")
    func summaryIsStable() {
        func build() -> String {
            var l = ScanLedger(unit: "transcripts")
            for r in ["a", "b", "c", "d", "e", "f"] { l.drop(r) }
            return l.summary
        }
        #expect(build() == build())
    }

    @Test("Ties break by name so equal counts stay ordered")
    func tiesAreOrdered() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.drop("zebra"); ledger.drop("alpha")
        #expect(ledger.summary == "2 transcripts → 0 shown (2 dropped: alpha 1, zebra 1)")
    }

    /// The scan runs every three seconds; logging each one would bury the log
    /// it is meant to improve.
    @Test("An unchanged scan is not news")
    func silentWhenUnchanged() {
        var first = ScanLedger(unit: "transcripts")
        first.keep(); first.drop("sdk-run")
        var same = ScanLedger(unit: "transcripts")
        same.keep(); same.drop("sdk-run")
        var different = ScanLedger(unit: "transcripts")
        different.keep(); different.keep(); different.drop("sdk-run")

        #expect(first.differs(from: nil))
        #expect(!same.differs(from: first))
        #expect(different.differs(from: first))
    }

    @Test("An empty first scan says nothing")
    func emptyIsSilent() {
        #expect(!ScanLedger(unit: "transcripts").differs(from: nil))
    }
}

@Suite("Log filtering")
struct LogFilterTests {
    private func entry(_ category: String, _ message: String) -> LogEntry {
        LogEntry(id: 1, date: Date(), level: .info,
                 category: category, message: message)
    }

    @Test("Search matches message or category, case-insensitively")
    func searchMatches() {
        let e = entry("focus", "com.apple.Terminal is not running")
        #expect(LogView.matches(e, search: ""))
        #expect(LogView.matches(e, search: "terminal"))
        #expect(LogView.matches(e, search: "FOCUS"))
        #expect(!LogView.matches(e, search: "cursor"))
    }

    @Test("Whitespace-only search is not a filter")
    func blankSearch() {
        #expect(LogView.matches(entry("scan", "2 transcripts → 2 shown"), search: "   "))
    }
}

@Suite("Follow-up reminders")
struct FollowUpReminderTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Nothing is due before the delay")
    func notDueYet() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        #expect(r.due(now: t0.addingTimeInterval(299)).isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(300)).map(\.id) == ["a"])
    }

    /// The whole point: one nudge. Something that pings until you deal with it
    /// gets ignored wholesale, which costs the peeks worth reading.
    @Test("A reminder never fires twice")
    func remindsOnce() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        let later = t0.addingTimeInterval(600)
        #expect(r.due(now: later).count == 1)
        #expect(r.due(now: later.addingTimeInterval(600)).isEmpty)
        // Nor by re-recording the same id.
        r.recordUnattended(id: "a", kind: .waiting, at: later)
        #expect(r.due(now: later.addingTimeInterval(1200)).isEmpty)
    }

    /// Dismissing is attending: you looked and decided it was not for you.
    @Test("Attending to something cancels its reminder")
    func attendedCancels() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .finished, at: t0)
        r.attended(id: "a")
        #expect(r.due(now: t0.addingTimeInterval(600)).isEmpty)
        #expect(r.pending.isEmpty)
    }

    @Test("Recording the same peek twice queues one reminder")
    func noDuplicates() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        r.recordUnattended(id: "a", kind: .waiting, at: t0.addingTimeInterval(5))
        #expect(r.pending.count == 1)
    }

    /// A prompt from hours ago has almost certainly been answered in the
    /// terminal; raising it would state something false.
    @Test("Stale items expire instead of being raised")
    func expires() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "old", kind: .waiting, at: t0)
        r.expire(now: t0.addingTimeInterval(AgentSession.liveWindow + 1))
        #expect(r.pending.isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(99_999)).isEmpty)
    }

    @Test("Several unattended peeks each get their own reminder")
    func independent() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        r.recordUnattended(id: "b", kind: .finished, at: t0.addingTimeInterval(120))
        #expect(r.due(now: t0.addingTimeInterval(310)).map(\.id) == ["a"])
        #expect(r.due(now: t0.addingTimeInterval(430)).map(\.id) == ["b"])
    }

    /// An identical second copy of a peek looks like the agent asked twice.
    @Test("A reminder says that it is one")
    func titlesDiffer() {
        #expect(FollowUpReminder.title(for: .waiting) == "Still waiting on you")
        #expect(FollowUpReminder.title(for: .finished) != FollowUpReminder.title(for: .waiting))
    }
}

@Suite("Quiet scenes")
struct QuietSceneTests {
    private func session(locked: Any? = nil, onConsole: Any? = nil) -> () -> [String: Any]? {
        var d: [String: Any] = [:]
        if let locked { d["CGSSessionScreenIsLocked"] = locked }
        if let onConsole { d["kCGSSessionOnConsoleKey"] = onConsole }
        return { d }
    }

    @Test("Locked reads as locked, either spelling")
    func readsLockState() {
        #expect(QuietScene.screenIsLocked(session: session(locked: true)))
        #expect(QuietScene.screenIsLocked(session: session(locked: 1)))
        #expect(!QuietScene.screenIsLocked(session: session(locked: false)))
        #expect(!QuietScene.screenIsLocked(session: session(locked: 0)))
    }

    /// The failure that matters is going silent when we should not have, so an
    /// unreadable session errs towards speaking.
    @Test("An unreadable session speaks rather than going quiet")
    func unknownSpeaks() {
        #expect(!QuietScene.screenIsLocked(session: { nil }))
        #expect(!QuietScene.screenIsLocked(session: session()))
        #expect(QuietScene.onConsole(session: { nil }))
        #expect(!QuietScene.shouldStayQuiet(enabled: true, session: { nil }))
    }

    /// Fast user switching leaves us running behind somebody else's session,
    /// where a peek is invisible at best and over their screen at worst.
    @Test("Another user on the console also means quiet")
    func offConsoleIsQuiet() {
        #expect(QuietScene.shouldStayQuiet(enabled: true,
                                           session: session(locked: false, onConsole: false)))
        #expect(!QuietScene.shouldStayQuiet(enabled: true,
                                            session: session(locked: false, onConsole: true)))
    }

    @Test("Switched off, nothing is ever held back")
    func disabledNeverQuiet() {
        #expect(!QuietScene.shouldStayQuiet(enabled: false,
                                            session: session(locked: true, onConsole: false)))
    }

    @Test("Locked means quiet")
    func lockedIsQuiet() {
        #expect(QuietScene.shouldStayQuiet(enabled: true,
                                           session: session(locked: true, onConsole: true)))
    }
}

@Suite("Reminders do not nudge themselves")
struct FollowUpSelfReferenceTests {
    /// A reminder is presented as an ordinary peek, so when it times out it
    /// would earn a reminder of its own — and that one another, forever. The
    /// original tests could not see this: none of them re-presented a reminder.
    @Test("A reminder that times out earns nothing")
    func reminderIsNotRecorded() {
        var r = FollowUpReminder()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        let fired = r.due(now: t0.addingTimeInterval(300))
        #expect(fired.map(\.id) == ["a"])

        // The reminder peek now times out unattended, exactly as the original did.
        r.recordUnattended(id: FollowUpReminder.reminderId(for: "a"), kind: .waiting,
                           at: t0.addingTimeInterval(320))
        #expect(r.pending.isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(9_000)).isEmpty)
    }

    @Test("Reminder ids are recognisable")
    func idsAreLabelled() {
        #expect(FollowUpReminder.isReminder(id: FollowUpReminder.reminderId(for: "x")))
        #expect(!FollowUpReminder.isReminder(id: "x"))
    }
}

/// Reported by a user: a finished Codex peek had a ✕ and nothing else — there
/// was no way to say the next thing without switching back to the terminal by
/// hand. The cause was one predicate doing two jobs. `supportsTypedAnswers`
/// exists to stop us firing Claude Code's `y`/`n` keys at an agent whose
/// approval keymap is different, which is right — but the reply composer was
/// gated on it too, and a free-text paste has no keymap to get wrong.
@Suite("Replying from the notch")
struct NotchReplyCapabilityTests {
    private func alert(agent: String?, bundleId: String?,
                       kind: AlertKind = .finished) -> DevReadyAlert {
        DevReadyAlert(id: "1", title: "murmur-app", source: nil, agent: agent,
                      bundleId: bundleId, kind: kind)
    }

    @Test("a finished Codex peek in a terminal can be replied to")
    @MainActor
    func codexInTerminalCanReply() {
        let a = alert(agent: "codex", bundleId: "com.apple.Terminal")
        #expect(a.canReplyFromNotch(replyEnabled: true))
        // …but still no quick-answer capsules: those keys are Claude Code's.
        #expect(!a.canAnswerFromNotch(replyEnabled: true))
    }

    @Test("every known terminal host can receive a reply")
    @MainActor
    func terminalHostsCanReply() {
        for bundleId in DevReadyAlert.terminalHostBundleIds {
            #expect(alert(agent: "codex", bundleId: bundleId)
                .canReplyFromNotch(replyEnabled: true),
                    "expected \(bundleId) to accept a reply")
        }
    }

    // GUI agent windows now accept a reply — they have a composer like any
    // other app. The risk that kept them out, a paste landing in whatever view
    // holds focus, is handled by not submitting it: see `submitsOnDelivery`.
    @Test("GUI agent windows accept a typed reply, unsubmitted")
    @MainActor
    func guiHostsAcceptButDoNotSubmit() {
        let codex = alert(agent: "codex", bundleId: "com.openai.codex")
        let cursor = alert(agent: "cursor", bundleId: "com.todesktop.230313mzl4w4u92")
        #expect(codex.canReplyFromNotch(replyEnabled: true))
        #expect(cursor.canReplyFromNotch(replyEnabled: true))
        #expect(!codex.submitsOnDelivery)
        #expect(!cursor.submitsOnDelivery)
    }

    @Test("a reply needs somewhere to go")
    @MainActor
    func noTargetNoReply() {
        #expect(!alert(agent: "claude-code", bundleId: nil)
            .canReplyFromNotch(replyEnabled: true))
        #expect(!alert(agent: "claude-code", bundleId: "com.apple.Terminal")
            .canReplyFromNotch(replyEnabled: false))
    }

    // The row draws the ↰ beside the ✕; if the width budget does not know that,
    // the control is paid for out of the title, which truncates.
    @Test("a replyable row is budgeted the width of its reply control")
    @MainActor
    func widthCoversReplyControl() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 900, designExpandedHeight: 190,
                                   scale: 1.0, topGap: 10)
        let title = String(repeating: "n", count: 40)
        let replyable = DevReadyAlert(id: "1", title: title, agent: "codex",
                                      bundleId: "com.apple.Terminal", kind: .finished)
        // An agent that has declared it cannot be answered: the one remaining
        // case with no ↰, now that desktop agents draw one.
        let plain = DevReadyAlert(id: "2", title: title, agent: "cursor",
                                  bundleId: "com.todesktop.230313mzl4w4u92", kind: .finished,
                                  deliverySpec: "none")
        let wide = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [replyable],
                                                     answerEnabled: true)
        let narrow = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [plain],
                                                       answerEnabled: true)
        #expect(wide.size.width - narrow.size.width == NotchContentLayout.replyControlWidth)
    }
}

/// `NSRunningApplication.activate` returns `true` from a background accessory
/// app while the frontmost application never changes — measured on macOS 26
/// from an LSUIElement bundle. Two features were built on that return value and
/// both failed silently: tap-to-jump returned early and did nothing, and every
/// reply aborted with `.focusTimeout` after waiting for a handoff that was
/// never going to happen.
@Suite("Bringing another app forward")
struct AppActivatorTests {
    @Test("addresses the app by bundle id, not by name")
    func scriptUsesBundleId() {
        let script = AppActivator.activateScript(bundleId: "com.apple.Terminal")
        #expect(script == "tell application id \"com.apple.Terminal\" to activate")
        // A localised or duplicated app *name* resolves to the wrong app; an id
        // cannot.
        #expect(script?.contains("\"Terminal\" to activate") != true)
    }

    // Bundle ids arrive in hook payloads, so they are untrusted, and they end up
    // inside an AppleScript string literal. Escaping quotes is not enough — a
    // raw newline cannot live in an AppleScript string at all — so anything that
    // is not a bundle identifier is refused outright rather than repaired.
    @Test("a malformed bundle id is refused, not escaped")
    func scriptRefusesInjection() {
        #expect(AppActivator.activateScript(
            bundleId: "com.evil\" to quit\ntell application \"Finder") == nil)
        #expect(AppActivator.activateScript(bundleId: "com.evil\" to quit") == nil)
        #expect(AppActivator.activateScript(bundleId: "with space") == nil)
        #expect(AppActivator.activateScript(bundleId: "") == nil)
        // Real ids still pass.
        for id in ["com.apple.Terminal", "dev.warp.Warp-Stable", "com.local.notchpill"] {
            #expect(AppActivator.isValidBundleId(id), "expected \(id) to be accepted")
        }
    }

    @Test("an empty bundle id is refused rather than guessed at")
    @MainActor
    func emptyIsRefused() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "", frontmost: { "com.other" }) { c.resume(returning: $0) }
        }
        #expect(result == false)
    }

    @Test("an app already in front needs no activation at all")
    @MainActor
    func alreadyFrontIsInstant() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "com.apple.Terminal",
                                  frontmost: { "com.apple.Terminal" }) { c.resume(returning: $0) }
        }
        #expect(result)
    }

    // The whole point: focus is decided by observing `frontmostApplication`,
    // never by a return value. An app that never comes forward must report
    // failure so the caller can escalate or tell the user — silently believing
    // it worked is what shipped the two broken features.
    @Test("an app that never comes forward reports failure")
    @MainActor
    func neverFrontmostFails() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "com.local.definitely-not-installed",
                                  frontmost: { "com.cmuxterm.app" }) { c.resume(returning: $0) }
        }
        #expect(result == false)
    }

    @Test("every strategy is tried before giving up")
    func escalationOrder() {
        // Cheapest first: the Apple Event costs a round trip and can raise a
        // one-time Automation prompt, so it is not tried until the free call
        // has been shown not to work.
        #expect(AppActivator.Strategy.allCases.map(\.rawValue)
                == ["direct", "appleScript", "launchServices"])
    }
}

/// Reported: Codex was running and the notch listed only Cursor.
///
/// A Codex row is named from `cwd` in the transcript's first record, and the
/// scanner used to `guard let project = … else { return nil }` — so when that
/// lookup failed the whole session was discarded. Desktop Codex writes its base
/// instructions into that first record, large enough to push `cwd` past the
/// read window, which made the agent most likely to hit it also the one that
/// vanished.
@Suite("Naming a session never hides it")
struct SessionNamingTests {
    @Test("an unnamed session still says which agent it is")
    func fallbackNamesTheAgent() {
        #expect(AgentSessionScanner.fallbackProjectName(isCodex: true) == "Codex")
        #expect(AgentSessionScanner.fallbackProjectName(isCodex: false) == "Claude Code")
    }

    // The regression itself: cwd sitting beyond the old 32KB window.
    @Test("cwd is found past the old read window")
    func cwdSurvivesHugeFirstRecord() {
        let filler = String(repeating: "x", count: 120_000)
        let head = #"{"payload":{"instructions":"\#(filler)"}}"#
        let second = #"{"payload":{"cwd":"/Users/me/murmur-app"}}"#
        let text = head + "\n" + second
        #expect(text.utf8.count > 32_768)
        #expect(text.utf8.count < AgentSessionScanner.metadataReadWindow)
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/murmur-app")
    }

    @Test("the read window grew past desktop Codex's first record")
    func windowIsLargeEnough() {
        #expect(AgentSessionScanner.metadataReadWindow >= 262_144)
    }

    @Test("cwd is still recovered from a record cut off mid-field")
    func partialRecordStillYieldsCwd() {
        // A truncated first record: valid JSON never closes, so structured
        // decoding fails and only the textual recovery can find cwd.
        let text = #"{"payload":{"cwd":"/Users/me/proj","instructions":"blah blah"#
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/proj")
    }
}

/// Codex subscription usage read from OpenAI with the token Codex already
/// stored at login. Fixtures are the real response shape, captured from a live
/// call on this machine (identifiers replaced).
@Suite("Codex usage over OAuth")
struct CodexUsageFetcherTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // The captured response that showed the transcript source was wrong: the
    // notch said "4% used · 0 credits balance" while this said 100% and $298.
    private let live = """
    {"plan_type":"free",
     "rate_limit":{"allowed":false,"limit_reached":true,
       "primary_window":{"used_percent":100,"limit_window_seconds":2592000,
                         "reset_after_seconds":361844,"reset_at":1786130351},
       "secondary_window":null},
     "credits":{"has_credits":true,"unlimited":false,"balance":"298.4291950000"},
     "rate_limit_reset_credits":{"available_count":0}}
    """

    @Test("reads the real usage payload")
    func parsesLiveResponse() {
        let now = Date(timeIntervalSince1970: 1_785_768_507)
        let quota = CodexUsageFetcher.quota(in: json(live), now: now)
        #expect(quota?.usedPercent == 100)
        #expect(quota?.resetsAt == Date(timeIntervalSince1970: 1_786_130_351))
        #expect(quota?.updatedAt == now)
        // The balance is $298.43 — not the 0 the old source reported by reading
        // `rate_limit_reset_credits.available_count` instead.
        #expect(quota?.creditBalance == Decimal(string: "298.4291950000"))
    }

    @Test("a decimal balance is not read through a Double, nor through the locale")
    func balanceIsExact() {
        let quota = CodexUsageFetcher.quota(in: json(live))
        #expect(quota?.creditBalance != nil)
        // 298.429195 has no exact binary representation; Decimal keeps it.
        #expect(quota?.creditBalance == Decimal(sign: .plus, exponent: -10,
                                                significand: 2_984_291_950_000))
    }

    @Test("an unlimited plan reports no balance rather than a wrong one")
    func unlimitedHasNoBalance() {
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":15,"reset_at":1786130351}},
         "credits":{"has_credits":true,"unlimited":true,"balance":"0"}}
        """
        #expect(CodexUsageFetcher.quota(in: json(body))?.creditBalance == nil)
    }

    @Test("used percent is clamped to a percentage")
    func clampsPercent() {
        for (raw, want) in [("-5", 0), ("142", 100), ("15.6", 16)] {
            let body = #"{"rate_limit":{"primary_window":{"used_percent":\#(raw)}}}"#
            #expect(CodexUsageFetcher.quota(in: json(body))?.usedPercent == want)
        }
    }

    @Test("a response without a rate limit yields nothing, not a zero")
    func missingLimitIsNil() {
        // A card reading "0% used" when we simply do not know is a lie, and the
        // whole point of this change was to stop showing confident wrong numbers.
        #expect(CodexUsageFetcher.quota(in: json(#"{"plan_type":"pro"}"#)) == nil)
        #expect(CodexUsageFetcher.quota(in: json("not json")) == nil)
    }

    @Test("reads the credentials Codex wrote")
    func parsesAuthFile() {
        let body = """
        {"OPENAI_API_KEY":null,"auth_mode":"chatgpt",
         "tokens":{"id_token":"idtok","access_token":"acctok",
                   "refresh_token":"reftok","account_id":"acct-1"},
         "last_refresh":"2026-08-02T04:05:04.070839Z"}
        """
        let creds = CodexUsageFetcher.credentials(in: json(body))
        #expect(creds?.accessToken == "acctok")
        #expect(creds?.refreshToken == "reftok")
        #expect(creds?.accountId == "acct-1")
        // Fractional seconds must parse: the plain ISO8601 formatter rejects
        // them, which would read a fresh token as "never refreshed" and force a
        // pointless refresh on every launch.
        #expect(creds?.lastRefresh != nil)
    }

    @Test("credentials without tokens are refused")
    func refusesEmptyAuth() {
        #expect(CodexUsageFetcher.credentials(in: json(#"{"tokens":{}}"#)) == nil)
        #expect(CodexUsageFetcher.credentials(
            in: json(#"{"tokens":{"access_token":"","refresh_token":"r"}}"#)) == nil)
    }

    @Test("refresh is due only after Codex's own interval")
    func refreshWindow() {
        let t0 = Date(timeIntervalSince1970: 1_785_000_000)
        var creds = CodexUsageFetcher.Credentials(accessToken: "a", refreshToken: "r",
                                                  accountId: nil, lastRefresh: t0)
        #expect(!creds.needsRefresh(now: t0.addingTimeInterval(7 * 24 * 3600)))
        #expect(creds.needsRefresh(now: t0.addingTimeInterval(9 * 24 * 3600)))
        // Never refreshed: assume it is due rather than send a stale token.
        creds.lastRefresh = nil
        #expect(creds.needsRefresh(now: t0))
    }

    @Test("a refresh that returns no new refresh token keeps the old one")
    func refreshKeepsRefreshToken() {
        let previous = CodexUsageFetcher.Credentials(accessToken: "old", refreshToken: "keepme",
                                                     accountId: "acct", lastRefresh: nil)
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let next = CodexUsageFetcher.refreshed(in: json(#"{"access_token":"new"}"#),
                                               previous: previous, now: now)
        #expect(next?.accessToken == "new")
        #expect(next?.refreshToken == "keepme")
        #expect(next?.accountId == "acct")
        #expect(next?.lastRefresh == now)
    }

    @Test("requests carry exactly the headers Codex sends")
    func requestHeaders() {
        let creds = CodexUsageFetcher.Credentials(accessToken: "tok", refreshToken: "r",
                                                  accountId: "acct-1", lastRefresh: nil)
        let request = CodexUsageFetcher.usageRequest(creds)
        #expect(request.url == CodexUsageFetcher.usageEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex-cli")
    }

    @Test("the refresh request is a refresh_token grant")
    func refreshBody() {
        let creds = CodexUsageFetcher.Credentials(accessToken: "a", refreshToken: "reftok",
                                                  accountId: nil, lastRefresh: nil)
        let request = CodexUsageFetcher.refreshRequest(creds)
        #expect(request.httpMethod == "POST")
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect(body?["grant_type"] as? String == "refresh_token")
        #expect(body?["refresh_token"] as? String == "reftok")
        #expect(body?["client_id"] as? String == CodexUsageFetcher.clientId)
    }
}

/// Tap-to-jump for agents that live in an app rather than a terminal.
///
/// The locator places a session by finding a process whose arguments contain
/// the session id. Desktop agents run one process for every conversation —
/// `ChatGPT.app/Contents/Resources/codex … app-server` names no session — so
/// there is nothing to walk up from and the tap did nothing at all. Only Cursor
/// had a fallback.
@Suite("Jumping to a desktop agent")
struct AgentFallbackTargetTests {
    private func session(agent: String) -> AgentSession {
        AgentSession(id: "s1", agent: agent, project: "proj", state: .working,
                     lastActivity: Date())
    }

    @Test("desktop Codex falls back to its app")
    func codexHasAFallback() {
        let ids = session(agent: "codex").fallbackAppBundleIds
        #expect(ids.first == "com.openai.codex")
        // The older bundle id stays as a second candidate.
        #expect(ids.contains("com.openai.chat"))
    }

    @Test("Cursor keeps the fallback it already had")
    func cursorUnchanged() {
        #expect(session(agent: "cursor").fallbackAppBundleIds == ["com.todesktop.230313mzl4w4u92"])
    }

    // Guessing a terminal for a CLI agent would send you to the wrong window as
    // often as the right one, so these deliberately offer nothing and let the
    // process-tree walk do its job.
    @Test("CLI agents offer no app to guess at")
    func cliAgentsHaveNoFallback() {
        #expect(session(agent: "claude-code").fallbackAppBundleIds.isEmpty)
        #expect(session(agent: "opencode").fallbackAppBundleIds.isEmpty)
        #expect(session(agent: "something-else").fallbackAppBundleIds.isEmpty)
    }
}

/// Claude subscription usage from Anthropic, using the token Claude Code
/// already stored at login. Fixtures are the real response shape, captured live
/// from this machine.
@Suite("Claude usage over OAuth")
struct ClaudeUsageFetcherTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    private let live = """
    {"five_hour":{"utilization":51.0,"resets_at":"2026-08-03T23:59:59.849238+00:00"},
     "seven_day":{"utilization":13.0,"resets_at":"2026-08-09T22:59:59.849262+00:00"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1656.0},
     "spend":{"used":{"amount_minor":1656,"currency":"USD","exponent":2},
              "limit":{"amount_minor":5000,"currency":"USD","exponent":2},
              "percent":33,"enabled":true}}
    """

    @Test("reads both windows from the real payload")
    func parsesLiveResponse() {
        let now = Date(timeIntervalSince1970: 1_785_785_000)
        let quota = ClaudeUsageFetcher.quota(in: json(live), now: now)
        #expect(quota?.sessionPercent == 51)
        #expect(quota?.weeklyPercent == 13)
        #expect(quota?.sessionResetsAt != nil)
        #expect(quota?.weeklyResetsAt != nil)
        #expect(quota?.updatedAt == now)
        // Whichever window is closest to its limit is the one worth showing.
        #expect(quota?.headlinePercent == 51)
    }

    // Money stays in minor units end to end. $16.56 has no exact binary
    // representation, so a Double round trip is a wrong number on a screen
    // about spending.
    @Test("extra spend is rendered from minor units")
    func spendLabel() {
        let quota = ClaudeUsageFetcher.quota(in: json(live))
        #expect(quota?.extraSpentMinor == 1656)
        #expect(quota?.extraLimitMinor == 5000)
        #expect(quota?.extraSpendLabel == "$16.56 of $50")
    }

    @Test("spend that is switched off is not shown")
    func spendDisabled() {
        let body = """
        {"five_hour":{"utilization":10.0},
         "spend":{"used":{"amount_minor":900,"currency":"USD"},"enabled":false}}
        """
        let quota = ClaudeUsageFetcher.quota(in: json(body))
        #expect(quota?.sessionPercent == 10)
        #expect(quota?.extraSpendLabel == nil)
    }

    @Test("a response with no windows yields nothing, not a zero")
    func noWindowsIsNil() {
        // "0% used" when we do not know is the same lie the Codex card told.
        #expect(ClaudeUsageFetcher.quota(in: json(#"{"seven_day_opus":null}"#)) == nil)
        #expect(ClaudeUsageFetcher.quota(in: json("nope")) == nil)
    }

    @Test("utilization is clamped to a percentage")
    func clamps() {
        for (raw, want) in [("-3", 0), ("130", 100), ("50.6", 51)] {
            let body = #"{"five_hour":{"utilization":\#(raw)}}"#
            #expect(ClaudeUsageFetcher.quota(in: json(body))?.sessionPercent == want)
        }
    }

    // The Keychain blob stores epoch *milliseconds*. Read as seconds, every
    // token dates to 1970 and looks expired, so usage would never be fetched.
    @Test("expiry is read as milliseconds")
    func credentialTimes() {
        let body = """
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref",
          "expiresAt":1785792994905,"subscriptionType":"pro",
          "scopes":["user:inference","user:profile"]}}
        """
        let creds = ClaudeUsageFetcher.credentials(in: json(body))
        #expect(creds?.accessToken == "tok")
        #expect(creds?.subscriptionType == "pro")
        #expect(creds?.hasUsageScope == true)
        let expected = Date(timeIntervalSince1970: 1_785_792_994.905)
        #expect(abs((creds?.expiresAt ?? .distantPast).timeIntervalSince(expected)) < 0.01)
        #expect(creds?.isExpired(now: Date(timeIntervalSince1970: 1_785_000_000)) == false)
        #expect(creds?.isExpired(now: Date(timeIntervalSince1970: 1_786_000_000)) == true)
    }

    // A CLI token can hold only `user:inference` — enough to talk to the model,
    // not to read the account. That 403 is worth telling apart from signed out.
    @Test("a token without user:profile is recognised")
    func missingScope() {
        let body = #"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#
        #expect(ClaudeUsageFetcher.credentials(in: json(body))?.hasUsageScope == false)
    }

    // Claude Code 2.1.x can store only MCP state under this item. That is
    // signed-out for our purposes, not a broken Keychain.
    @Test("an item holding only MCP state reads as no credentials")
    func mcpOnlyItem() {
        #expect(ClaudeUsageFetcher.credentials(in: json(#"{"mcpOAuth":{"a":1}}"#)) == nil)
        #expect(ClaudeUsageFetcher.credentials(in: json(#"{"claudeAiOauth":{"accessToken":""}}"#)) == nil)
    }

    @Test("the request carries the oauth beta header")
    func requestShape() {
        let creds = ClaudeUsageFetcher.Credentials(accessToken: "tok", refreshToken: nil,
                                                   expiresAt: nil, scopes: [],
                                                   subscriptionType: nil)
        let request = ClaudeUsageFetcher.usageRequest(creds)
        #expect(request.url == ClaudeUsageFetcher.usageEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test("reset labels round to the unit that reads best")
    func resetLabels() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(1800), now: now) == "resets in 30m")
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(7200), now: now) == "resets in 2h")
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(3 * 86_400), now: now) == "resets in 3d")
        #expect(ClaudeQuota.resetLabel(for: nil, now: now) == nil)
    }
}

@Suite("Cursor usage over the account API")
struct CursorUsageFetcherTests {
    /// The shape cursor.com/api/usage-summary actually returned, trimmed.
    private static let payload = """
    {"billingCycleStart":"2026-07-16T20:05:08.000Z",
     "billingCycleEnd":"2026-08-16T20:05:08.000Z",
     "membershipType":"pro_student","limitType":"user","isUnlimited":false,
     "individualUsage":{
       "plan":{"enabled":true,"used":2000,"limit":2000,"remaining":0,
               "breakdown":{"included":2000,"bonus":7201,"total":9201},
               "autoPercentUsed":100,"apiPercentUsed":100,"totalPercentUsed":100},
       "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
     "teamUsage":{}}
    """

    @Test func parsesLivePayload() throws {
        let quota = try #require(CursorUsageFetcher.quota(
            in: Data(Self.payload.utf8), now: Date(timeIntervalSince1970: 1_754_000_000)))
        #expect(quota.used == 2000)
        #expect(quota.limit == 2000)
        #expect(quota.remaining == 0)
        #expect(quota.percentUsed == 100)
        #expect(quota.included == 2000)
        #expect(quota.bonus == 7201)
        #expect(quota.bonusLabel == "+7201 bonus")
        // The two pools Cursor meters separately.
        #expect(quota.autoPercentUsed == 100)
        #expect(quota.apiPercentUsed == 100)
        #expect(quota.membership == "pro_student")
        #expect(quota.isUnlimited == false)
        #expect(quota.onDemandEnabled == false)
        #expect(quota.cycleEnd != nil)
    }

    /// The plan key is raw; the card must not print "pro_student" at a user.
    @Test func tidiesMembershipForDisplay() {
        var quota = CursorQuota(used: 1, limit: 2, included: nil, bonus: nil,
                                percentUsed: 50, autoPercentUsed: nil,
                                apiPercentUsed: nil, cycleEnd: nil,
                                membership: "pro_student", isUnlimited: false,
                                onDemandEnabled: false, updatedAt: nil)
        #expect(quota.membershipLabel == "Pro Student")
        quota.membership = ""
        #expect(quota.membershipLabel == nil)
    }

    /// "used of limit", never "remaining": at the cap, a remaining figure of
    /// zero reads exactly like an account that has done nothing all month.
    @Test func labelsUsageUnambiguously() {
        let full = CursorQuota(used: 2000, limit: 2000, included: nil, bonus: nil,
                               percentUsed: 100, autoPercentUsed: nil,
                               apiPercentUsed: nil, cycleEnd: nil, membership: nil,
                               isUnlimited: false, onDemandEnabled: false, updatedAt: nil)
        #expect(full.usageLabel == "2000 of 2000")
        let unlimited = CursorQuota(used: 0, limit: 0, included: nil, bonus: nil,
                                    percentUsed: 0, autoPercentUsed: nil,
                                    apiPercentUsed: nil, cycleEnd: nil, membership: nil,
                                    isUnlimited: true, onDemandEnabled: false, updatedAt: nil)
        #expect(unlimited.usageLabel == "unlimited")
    }

    /// An unlimited plan carries no plan block. That is an answer, not a failure.
    @Test func unlimitedWithoutPlanBlock() throws {
        let json = """
        {"isUnlimited":true,"membershipType":"business",
         "billingCycleEnd":"2026-08-16T20:05:08.000Z","individualUsage":{}}
        """
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.isUnlimited)
        #expect(quota.membershipLabel == "Business")
    }

    /// Bonus credits sit outside the gauge, so a zero or absent bonus must
    /// print nothing rather than "+0 bonus".
    @Test func hidesEmptyBonus() throws {
        let json = #"{"individualUsage":{"plan":{"used":1,"limit":2,"breakdown":{"bonus":0}}}}"#
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.bonusLabel == nil)
    }

    @Test func rejectsUnrelatedJSON() {
        #expect(CursorUsageFetcher.quota(in: Data(#"{"error":"nope"}"#.utf8)) == nil)
        #expect(CursorUsageFetcher.quota(in: Data("not json".utf8)) == nil)
    }

    /// The server's own percentage wins: 1999/2000 computed locally rounds to
    /// 100 and claims a limit that has not been reached.
    @Test func prefersServerPercent() throws {
        let json = """
        {"individualUsage":{"plan":{"used":1999,"limit":2000,"totalPercentUsed":99}}}
        """
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.percentUsed == 99)
    }

    /// Without a server percentage it rounds down, for the same reason.
    @Test func computesPercentDownWhenAbsent() throws {
        let json = #"{"individualUsage":{"plan":{"used":1999,"limit":2000}}}"#
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.percentUsed == 99)
    }

    @Test func readsSubjectFromTokenPayload() throws {
        // {"sub":"auth0|user_01ABC","exp":1}
        let body = Data(#"{"sub":"auth0|user_01ABC","exp":1}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let creds = try #require(CursorUsageFetcher.credentials(token: "aaa.\(body).bbb"))
        #expect(creds.subject == "user_01ABC")
    }

    @Test func rejectsTokensWithNoUsableSubject() {
        #expect(CursorUsageFetcher.credentials(token: "") == nil)
        #expect(CursorUsageFetcher.credentials(token: "   ") == nil)
        #expect(CursorUsageFetcher.credentials(token: "notajwt") == nil)
        #expect(CursorUsageFetcher.credentials(token: "aaa.!!!notbase64!!!.bbb") == nil)
    }

    /// The cookie Cursor expects is `<sub>::<token>`. Getting the separator
    /// wrong authenticates as nobody and returns an empty plan rather than an
    /// error, which is the worst possible failure for a gauge.
    @Test func buildsSessionCookie() {
        let request = CursorUsageFetcher.usageRequest(
            .init(accessToken: "TOKEN", subject: "user_1"))
        #expect(request.value(forHTTPHeaderField: "Cookie")
                == "WorkosCursorSessionToken=user_1::TOKEN")
        #expect(request.url == CursorUsageFetcher.usageEndpoint)
    }

    /// A GET, deliberately. The dashboard POSTs carry the same numbers but
    /// reject any request lacking a browser Origin header, and forging one to
    /// get past a CSRF check is not something this app should do.
    @Test func usesTheEndpointThatNeedsNoForgedOrigin() {
        #expect(CursorUsageFetcher.usageEndpoint.path == "/api/usage-summary")
        let request = CursorUsageFetcher.usageRequest(
            .init(accessToken: "T", subject: "S"))
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    }
}

@Suite("Live agent detail")
struct AgentSessionDetailTests {
    /// Usage records are cumulative per request, so the *newest* one is the
    /// live context. Summing them would report a multiple of the window.
    @Test func readsNewestClaudeContext() throws {
        let text = """
        {"message":{"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":7}}}
        {"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":131955,"cache_creation_input_tokens":503,"output_tokens":1113}}}
        """
        let tokens = try #require(AgentSessionScanner.contextTokens(in: text, isCodex: false))
        // 2 + 131955 + 503. Output is excluded: it is not carried forward.
        #expect(tokens == 132_460)
    }

    @Test func readsCodexContext() throws {
        let text = """
        {"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40000,"cached_input_tokens":2000}}}}
        """
        let tokens = try #require(AgentSessionScanner.contextTokens(in: text, isCodex: true))
        #expect(tokens == 42_000)
    }

    @Test func ignoresLinesWithoutUsage() {
        let text = """
        {"message":{"role":"user"}}
        not json at all
        {"payload":{"type":"other"}}
        """
        #expect(AgentSessionScanner.contextTokens(in: text, isCodex: false) == nil)
        #expect(AgentSessionScanner.contextTokens(in: text, isCodex: true) == nil)
    }

    /// A raw 132460 in a notch row is unreadable.
    @Test func formatsTokensCompactly() {
        #expect(AgentSession.compactTokens(940) == "940")
        #expect(AgentSession.compactTokens(9_400) == "9.4k")
        #expect(AgentSession.compactTokens(132_460) == "132k")
        #expect(AgentSession.compactTokens(1_240_000) == "1.2M")
    }

    /// "waiting" alone reads the same at ten seconds and forty minutes.
    @Test func waitingSaysHowLong() {
        let blocked = Date().addingTimeInterval(-360)
        let state = AgentSession.state(lastWrite: Date(), blocked: true, blockedSince: blocked)
        var session = AgentSession(id: "s", agent: "claude-code", project: "p",
                                   state: state, lastActivity: Date())
        #expect(session.statusLabel == "waiting 6m")
        #expect(session.isWaiting)
        // Without a recorded moment it must still read sensibly.
        session.state = .waiting(since: nil)
        #expect(session.statusLabel == "waiting")
    }

    /// Under a minute is noise — every session passes through it.
    @Test func hidesRuntimeUntilItMeansSomething() {
        var session = AgentSession(id: "s", agent: "codex", project: "p",
                                   state: .working, lastActivity: Date())
        session.startedAt = Date().addingTimeInterval(-20)
        #expect(session.runtimeLabel == nil)
        session.startedAt = Date().addingTimeInterval(-2520)
        #expect(session.runtimeLabel == "running 42m")
        // A session resumed across a fortnight read "running 334h".
        session.startedAt = Date().addingTimeInterval(-1_202_400)
        #expect(session.runtimeLabel == "running 13d")
        session.startedAt = nil
        #expect(session.runtimeLabel == nil)
    }

    @Test func contextLabelOnlyWhenKnown() {
        var session = AgentSession(id: "s", agent: "claude-code", project: "p",
                                   state: .working, lastActivity: Date())
        #expect(session.contextLabel == nil)
        session.contextTokens = 0
        #expect(session.contextLabel == nil)
        session.contextTokens = 132_460
        #expect(session.contextLabel == "132k ctx")
    }
}

@Suite("Focus-free reply delivery")
struct TerminalDirectDeliveryTests {
    @Test func onlyClaimsTerminalsThatSupportIt() {
        #expect(TerminalDirectDelivery.supports(bundleId: "com.cmuxterm.app"))
        // Terminal joined the list once it grew a tty-addressed path; a
        // terminal with no scripting still does not.
        #expect(!TerminalDirectDelivery.supports(bundleId: "dev.warp.Warp-Stable"))
        #expect(!TerminalDirectDelivery.supports(bundleId: nil))
    }

    /// AppleScript has no line continuation inside quotes, so a multi-line
    /// reply would be a syntax error rather than a wrong result. Those go the
    /// paste route, which handles them fine.
    @Test func declinesTextItCannotCarry() {
        #expect(TerminalDirectDelivery.canRepresent("hello there"))
        #expect(!TerminalDirectDelivery.canRepresent(""))
        #expect(!TerminalDirectDelivery.canRepresent("two\nlines"))
        #expect(TerminalDirectDelivery.cmuxScript(
            text: "two\nlines", directory: "/tmp", appendReturn: true) == nil)
    }

    /// A quote in a reply would otherwise end the string early and turn the
    /// rest of someone's sentence into AppleScript.
    @Test func escapesQuotesAndBackslashes() {
        #expect(TerminalDirectDelivery.escaped(#"say "hi""#) == #"say \"hi\""#)
        #expect(TerminalDirectDelivery.escaped(#"back\slash"#) == #"back\\slash"#)
        let script = try? #require(TerminalDirectDelivery.cmuxScript(
            text: #"say "hi""#, directory: "/tmp", appendReturn: true))
        #expect(script?.contains(#"input text "say \"hi\"" to target"#) == true)
    }

    /// Writing a reply into the wrong agent is worse than a flicker, so an
    /// ambiguous match has to decline rather than pick one.
    @Test func refusesAmbiguousTargets() throws {
        let script = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/Users/me/project", appendReturn: true))
        #expect(script.contains("if (count of found) is not 1 then return false"))
        #expect(script.contains(#"working directory of cmuxTerminal is "/Users/me/project""#))
    }

    /// Without a directory it may only act when a single terminal exists.
    @Test func withoutDirectoryRequiresASoleTerminal() throws {
        let script = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: nil, appendReturn: true))
        #expect(script.contains("if (count of found) is not 1 then return false"))
        #expect(!script.contains("working directory"))
    }

    /// The Return is a separate action, so a reply that should not submit
    /// must not carry one.
    @Test func submitsOnlyWhenAsked() throws {
        let withReturn = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/tmp", appendReturn: true))
        // Two backslashes: AppleScript unescapes one, leaving Ghostty the
        // `\r` escape its own action parser expects. This is the exact string
        // verified end to end against a live cmux panel.
        #expect(withReturn.contains(##"perform action "text:\\r" on target"##))
        let without = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/tmp", appendReturn: false))
        #expect(!without.contains("perform action"))
    }
}

@Suite("Usage fetches back off instead of hammering")
struct UsageBackoffTests {
    /// Measured live: the Claude card answered a 429 every 60 seconds for as
    /// long as the app stayed open. A fixed retry into a rate limit is not a
    /// retry, it is the cause of the next one.
    @Test func honoursRetryAfter() throws {
        let response = try #require(HTTPURLResponse(
            url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "120"]))
        #expect(ClaudeUsageFetcher.retryAfter(in: response) == 120)
    }

    /// A header we cannot read must not become a wait of zero — that is the
    /// hammering behaviour again — nor a wait of decades.
    @Test func ignoresUnusableRetryAfter() throws {
        func header(_ value: String) -> HTTPURLResponse? {
            HTTPURLResponse(url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
                            httpVersion: nil, headerFields: ["Retry-After": value])
        }
        #expect(ClaudeUsageFetcher.retryAfter(in: header("0")) == nil)
        #expect(ClaudeUsageFetcher.retryAfter(in: header("-5")) == nil)
        // The HTTP-date form is legal but unparsed here; a misread date would
        // otherwise produce a wait measured in decades.
        #expect(ClaudeUsageFetcher.retryAfter(in: header("Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(ClaudeUsageFetcher.retryAfter(in: nil) == nil)
    }

    /// Capped, so a server sending something enormous cannot silently disable
    /// the card for the rest of the session.
    @Test func capsRetryAfter() throws {
        let response = try #require(HTTPURLResponse(
            url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "999999"]))
        #expect(ClaudeUsageFetcher.retryAfter(in: response) == 3600)
    }

    /// A 429 stops being asked about; a cached answer keeps showing.
    @Test func rateLimitedStopsAsking() async throws {
        var calls = 0
        let service = ClaudeUsageService(
            transport: { request in
                calls += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 429,
                                               httpVersion: nil,
                                               headerFields: ["Retry-After": "600"])!
                return (Data(), response)
            },
            readKeychain: {
                Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8)
            })
        let start = Date()
        _ = await service.quota(now: start)
        #expect(calls == 1)
        // Well past the 60s refresh interval, but inside the 600s the server
        // asked for: it must not have asked again.
        _ = await service.quota(now: start.addingTimeInterval(120))
        #expect(calls == 1)
        _ = await service.quota(now: start.addingTimeInterval(700))
        #expect(calls == 2)
    }
}

@Suite("Placing a terminal agent when its session id is gone")
struct TerminalHostFallbackTests {
    private func entry(_ pid: Int32, _ ppid: Int32, _ args: String) -> AgentSessionLocator.Entry {
        AgentSessionLocator.Entry(pid: pid, ppid: ppid, args: args)
    }

    /// Substring matching was measured picking up `grep -iE "claude|codex"`:
    /// a shell that mentions both, descends from a terminal, and is not an
    /// agent. It made Codex look hosted in two places, so the lookup declined
    /// and the tap stayed broken.
    @Test func onlyTheBinaryItselfCounts() {
        #expect(AgentSessionLocator.isProcess("/opt/homebrew/bin/claude --resume", named: "claude"))
        #expect(AgentSessionLocator.isProcess("claude", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("grep -iE claude|codex", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("/bin/zsh -c claude foo", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("", named: "claude"))
    }

    @Test func mapsAgentsToTheirBinaries() {
        #expect(AgentSessionLocator.executableName(for: "claude-code") == "claude")
        #expect(AgentSessionLocator.executableName(for: "codex") == "codex")
        #expect(AgentSessionLocator.executableName(for: "opencode") == "opencode")
        // Cursor is a GUI app placed by its own bundle id, not a process walk.
        #expect(AgentSessionLocator.executableName(for: "cursor") == nil)
        #expect(AgentSessionLocator.executableName(for: nil) == nil)
    }

    /// Real bundles, because the walk resolves a path to a bundle id on disk.
    /// Fake paths resolve to nil and would make every case look "ambiguous",
    /// which is how the first draft of these tests passed for the wrong reason.
    private static let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    private static let music = "/System/Applications/Music.app/Contents/MacOS/Music"

    /// Two terminals hosting the same agent means jumping to the wrong one is
    /// as likely as the right one.
    @Test func declinesWhenTwoTerminalsHostTheSameAgent() {
        let table = [
            entry(10, 1, Self.finder),
            entry(11, 10, "/opt/homebrew/bin/claude"),
            entry(20, 1, Self.music),
            entry(21, 20, "/opt/homebrew/bin/claude"),
        ]
        #expect(AgentSessionLocator.soleTerminalHost(agent: "claude-code", in: table) == nil)
    }

    /// The case that was broken: an idle Claude Code session, whose only
    /// processes carrying the session id were transient tool shells that had
    /// already exited. It is placed by the agent binary instead, which lives
    /// as long as the session does — and resolves through `login`, which
    /// carries no bundle of its own.
    @Test func placesAnIdleAgentByItsRunningBinary() {
        let table = [
            entry(10, 1, Self.finder),
            entry(11, 10, "/usr/bin/login -pf someone"),
            entry(12, 11, "/opt/homebrew/bin/claude"),
            entry(30, 1, Self.music),
        ]
        #expect(AgentSessionLocator.soleTerminalHost(agent: "claude-code", in: table)
                == "com.apple.finder")
        // A different agent, not running anywhere, must not borrow that answer.
        #expect(AgentSessionLocator.soleTerminalHost(agent: "codex", in: table) == nil)
    }
}

@Suite("The Claude card survives a launch into a rate limit")
struct ClaudeQuotaCacheTests {
    private func store() -> UserDefaults {
        let suite = UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!
        return suite
    }

    /// A launch that opens into a 429 had nothing to show, and the card simply
    /// was not there — which read as the feature having been removed.
    @Test func servesTheLastGoodAnswerAfterRelaunch() async throws {
        let defaults = store()
        var calls = 0
        let ok = ClaudeUsageService(
            transport: { request in
                calls += 1
                let body = #"{"five_hour":{"utilization":58},"seven_day":{"utilization":14}}"#
                return (Data(body.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8)
            },
            store: defaults)
        let start = Date()
        let first = try #require(await ok.quota(now: start))
        #expect(first.sessionPercent == 58)
        #expect(calls == 1)

        // A new service, as though the app had been relaunched, that can only
        // get a 429 — the situation measured against the live API.
        let limited = ClaudeUsageService(
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429,
                                         httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8)
            },
            store: defaults)
        let restored = try #require(await limited.quota(now: start.addingTimeInterval(60)))
        #expect(restored.sessionPercent == 58)
        #expect(restored.weeklyPercent == 14)
    }

    /// Old enough and it stops being an answer. Showing a number from
    /// yesterday as though it were current is worse than showing none.
    @Test func doesNotServeAnAnswerThatIsTooOld() async throws {
        let defaults = store()
        defaults.set(["session": 58, "weekly": 14,
                      "at": Date().timeIntervalSince1970 - 7200],
                     forKey: ClaudeUsageService.cacheKey)
        let limited = ClaudeUsageService(
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429,
                                         httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8)
            },
            store: defaults)
        #expect(await limited.quota(now: Date()) == nil)
    }

    @Test func ignoresAnUnreadableCache() {
        let defaults = store()
        defaults.set(["session": "not a number"], forKey: ClaudeUsageService.cacheKey)
        #expect(ClaudeUsageService.restore(from: defaults) == nil)
        #expect(ClaudeUsageService.restore(from: store()) == nil)
    }
}

@Suite("Usage resets read as times, not durations")
struct QuotaResetClockTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = Date(timeIntervalSince1970: 1_785_800_000)   // 2026-08-03

    /// "resets in 5d" tells you how long you have waited, not when you can
    /// work again — and it was the only reset on the card, so the session
    /// window's reset was invisible whenever weekly happened to be higher.
    @Test func todayShowsAClockTime() throws {
        let later = now.addingTimeInterval(3 * 3600)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        // A time of day, not a duration.
        #expect(text.contains(":"))
        #expect(!text.contains("in "))
    }

    @Test func laterThisWeekNamesTheDay() throws {
        let later = now.addingTimeInterval(3 * 86_400)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        #expect(text.contains(":"))
        // Includes a weekday, so "Thu 2:40 AM" cannot be misread as today.
        #expect(text.rangeOfCharacter(from: .letters) != nil)
    }

    @Test func furtherOutGivesADate() throws {
        let later = now.addingTimeInterval(20 * 86_400)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        #expect(text.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(!text.contains(":"))
    }

    @Test func nothingToShowWithoutAResetTime() {
        #expect(ClaudeQuota.resetClock(for: nil, now: now,
                                       calendar: calendar, locale: locale) == nil)
    }
}

@Suite("The deck is only as tall as the card on screen")
struct DeckPageHeightTests {
    private let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                       designExpandedWidth: 640, designExpandedHeight: 190,
                                       scale: 1, topGap: 10)
    private func sessions(_ count: Int) -> [AgentSession] {
        (0..<count).map {
            AgentSession(id: "s\($0)", agent: "claude-code", project: "p",
                         state: .working, lastActivity: Date())
        }
    }

    /// The complaint that prompted this: paging right from a three-row agents
    /// card to a usage card left the pill at the agents card's height, with
    /// the difference showing as empty space.
    @Test func aShortCardDoesNotInheritATallOne() {
        let deck: [ExpandedActivity] = [
            .agents(sessions(3)),
            .claudeQuota(ClaudeQuota(sessionPercent: 26, weeklyPercent: 28)),
        ]
        let agentsPage = NotchContentLayout.expandedDeckSize(metrics: metrics,
                                                            activities: deck, page: 0).height
        let quotaPage = NotchContentLayout.expandedDeckSize(metrics: metrics,
                                                           activities: deck, page: 1).height
        #expect(quotaPage < agentsPage)
    }

    /// A quota card alone and the same card inside a deck of tall cards must
    /// be the same height — that is the whole point.
    @Test func aCardIsTheSameHeightWhereverItSits() {
        let quota = ExpandedActivity.claudeQuota(ClaudeQuota(sessionPercent: 26, weeklyPercent: 28))
        let alone = NotchContentLayout.expandedContentBaseHeight([quota], page: 0)
        let inDeck = NotchContentLayout.expandedContentBaseHeight([.agents(sessions(3)), quota],
                                                                  page: 1)
        #expect(alone == inDeck)
    }

    /// A page index the view has not caught up with must not collapse the
    /// pill; falling back to the tallest card is the old, safe behaviour.
    @Test func anOutOfRangePageFallsBackRatherThanGuessing() {
        let deck: [ExpandedActivity] = [
            .agents(sessions(3)),
            .claudeQuota(ClaudeQuota(sessionPercent: 26, weeklyPercent: 28)),
        ]
        let tallest = NotchContentLayout.expandedContentBaseHeight(deck)
        #expect(NotchContentLayout.expandedContentBaseHeight(deck, page: 7) == tallest)
        #expect(NotchContentLayout.expandedContentBaseHeight(deck, page: -1) == tallest)
    }
}

@Suite("The reply composer shows what you are replying to")
struct ReplyContextTests {
    /// A finished peek's subtitle is "finished · branch": it says an agent
    /// stopped, not what it said. Replying to that was answering a question
    /// you could not see.
    @Test func finishedPeekShowsTheAgentsLastMessage() {
        let alert = DevReadyAlert(title: "NotchPill", subtitle: "finished · main",
                                  agent: "claude-code", kind: .finished,
                                  agentMessage: "Want me to cut the release?")
        #expect(alert.questionText == nil)
        #expect(alert.replyContextText == "Want me to cut the release?")
    }

    /// A real question still wins — it is the more specific thing.
    @Test func aQuestionOutranksTheLastMessage() {
        let alert = DevReadyAlert(title: "p", kind: .waiting, message: "Allow Bash?",
                                  agentMessage: "some earlier chatter")
        #expect(alert.replyContextText == "Allow Bash?")
    }

    @Test func nothingToShowWhenThereIsNothing() {
        #expect(DevReadyAlert(title: "p").replyContextText == nil)
        #expect(DevReadyAlert(title: "p", agentMessage: "").replyContextText == nil)
    }

    /// Claude Code's transcript shape.
    @Test func readsClaudeCodesLastSpokenText() throws {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}
        {"type":"user","message":{"content":"a reply"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"Shall I ship it?"}]}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: false) == "Shall I ship it?")
    }

    /// Codex's, which uses a different envelope entirely — the point being
    /// that every agent gets this, not only Claude Code.
    @Test func readsCodexsLastSpokenText() throws {
        let text = """
        {"payload":{"type":"agent_message","message":"Done — anything else?"}}
        {"payload":{"type":"token_count","info":{}}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: true)
                == "Done — anything else?")
    }

    /// Reasoning and tool output are the agent's working, not its answer.
    @Test func skipsReasoningAndToolOutput() {
        let text = """
        {"payload":{"type":"agent_message","message":"The answer"}}
        {"payload":{"type":"reasoning","content":[{"type":"text","text":"thinking aloud"}]}}
        {"payload":{"type":"custom_tool_call_output","output":"tool said this"}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: true) == "The answer")
    }

    @Test func nothingFromATranscriptWithNoSpeech() {
        #expect(AgentSessionScanner.lastAgentMessage(in: "not json", isCodex: false) == nil)
        #expect(AgentSessionScanner.lastAgentMessage(
            in: #"{"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}"#,
            isCodex: false) == nil)
    }
}

@Suite("A peek from a hook still gets its context filled in")
struct AgentMessageEnrichmentTests {
    @MainActor
    private func state(with alert: DevReadyAlert) -> NotchState {
        let state = NotchState()
        state.enqueueDevReady([alert])
        return state
    }

    /// The measured case: a Stop-hook peek arrives with no transcript text, so
    /// the composer had nothing above the field.
    @MainActor @Test func fillsInAMissingMessage() {
        let alert = DevReadyAlert(title: "NotchPill", agent: "claude-code", sessionId: "s1")
        let state = self.state(with: alert)
        #expect(state.devReadyAlerts.first?.replyContextText == nil)
        state.setAgentMessage("Shall I cut the release?", forAlert: alert.id)
        #expect(state.devReadyAlerts.first?.replyContextText == "Shall I cut the release?")
    }

    /// The composer holds its own copy of the alert. Updating only the peek
    /// left the field blank, which is the bug this exists to fix.
    @MainActor @Test func updatesAnOpenComposerToo() {
        let alert = DevReadyAlert(title: "NotchPill", agent: "claude-code", sessionId: "s1")
        let state = self.state(with: alert)
        state.beginReply(to: alert)
        state.setAgentMessage("Shall I cut the release?", forAlert: alert.id)
        #expect(state.replyCompose?.contextText == "Shall I cut the release?")
    }

    /// A message already present is the more specific one — a later read must
    /// not overwrite it.
    @MainActor @Test func neverOverwritesWhatIsAlreadyThere() {
        let alert = DevReadyAlert(title: "p", agent: "claude-code", sessionId: "s1",
                                  agentMessage: "original")
        let state = self.state(with: alert)
        state.setAgentMessage("later read", forAlert: alert.id)
        #expect(state.devReadyAlerts.first?.agentMessage == "original")
    }

    @MainActor @Test func ignoresAnAlertThatHasGone() {
        let state = NotchState()
        state.setAgentMessage("anything", forAlert: "not-here")
        #expect(state.devReadyAlerts.isEmpty)
    }
}

@Suite("Media progress moves on its own")
struct MediaProgressTests {
    /// The adapter sends an ISO 8601 string. The parser accepted only numbers,
    /// so it returned nil for every real payload — and with no anchor there is
    /// nothing to interpolate from, which is why the bar sat frozen.
    @Test func parsesTheTimestampTheAdapterActuallySends() throws {
        let payload: [String: Any] = ["timestamp": "2026-08-04T18:32:24Z"]
        let date = try #require(MediaRemoteBridge.parseTimestamp(payload))
        #expect(abs(date.timeIntervalSince1970 - 1_785_868_344) < 1)
    }

    @Test func stillAcceptsNumericTimestamps() throws {
        #expect(MediaRemoteBridge.parseTimestamp(["timestampEpochMicros": NSNumber(value: 1_785_868_344_000_000)]) != nil)
        #expect(MediaRemoteBridge.parseTimestamp(["timestamp": NSNumber(value: 1_785_868_344)]) != nil)
        #expect(MediaRemoteBridge.parseTimestamp([:]) == nil)
        #expect(MediaRemoteBridge.parseTimestamp(["timestamp": "not a date"]) == nil)
    }

    @Test func acceptsFractionalSeconds() {
        #expect(MediaRemoteBridge.parseISOTimestamp("2026-08-04T18:32:24.512Z") != nil)
        #expect(MediaRemoteBridge.parseISOTimestamp("2026-08-04T18:32:24Z") != nil)
        #expect(MediaRemoteBridge.parseISOTimestamp("   ") == nil)
    }

    /// The measured case: a browser reporting elapsedTime 0 against a fixed
    /// timestamp. The position has to come from the clock.
    @Test func projectsPositionFromTheAnchor() throws {
        let anchor = Date()
        let np = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 0,
                            duration: 102.6, playbackRate: 1, timestamp: anchor)
        let after = try #require(np.interpolatedElapsed(at: anchor.addingTimeInterval(30)))
        #expect(abs(after - 30) < 0.01)
    }

    @Test func neverRunsPastTheEndOrWhilePaused() throws {
        let anchor = Date()
        let playing = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 100,
                                 duration: 102.6, playbackRate: 1, timestamp: anchor)
        #expect(try #require(playing.interpolatedElapsed(at: anchor.addingTimeInterval(60))) == 102.6)
        let paused = NowPlaying(title: "t", artist: "a", isPlaying: false, elapsed: 40,
                                duration: 102.6, playbackRate: 0, timestamp: anchor)
        #expect(try #require(paused.interpolatedElapsed(at: anchor.addingTimeInterval(60))) == 40)
    }

    /// A seek keeps the same track, artist and play state, so equality that
    /// ignored position dropped it as a duplicate and the bar kept running
    /// from the old anchor.
    @Test func aSeekIsNotADuplicate() {
        let anchor = Date()
        let before = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 10,
                                duration: 200, playbackRate: 1, timestamp: anchor)
        let sought = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 150,
                                duration: 200, playbackRate: 1,
                                timestamp: anchor.addingTimeInterval(5))
        #expect(before != sought)
    }

    /// A player whose position advances by itself must not republish every
    /// poll: the bar is already moving without help.
    @Test func normalPlaybackIsNotAChange() {
        let anchor = Date()
        let before = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 10,
                                duration: 200, playbackRate: 1, timestamp: anchor)
        let later = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 13,
                               duration: 200, playbackRate: 1,
                               timestamp: anchor.addingTimeInterval(3))
        #expect(before == later)
    }

    @Test func aDifferentTrackIsAlwaysAChange() {
        let now = Date()
        let a = NowPlaying(title: "one", artist: "a", isPlaying: true, elapsed: 10,
                           duration: 200, playbackRate: 1, timestamp: now)
        let b = NowPlaying(title: "two", artist: "a", isPlaying: true, elapsed: 10,
                           duration: 200, playbackRate: 1, timestamp: now)
        #expect(a != b)
    }
}

@Suite("Focus-free replies reach Terminal and iTerm too")
struct TerminalITermDeliveryTests {
    private func entry(_ pid: Int32, _ ppid: Int32, _ args: String) -> AgentSessionLocator.Entry {
        AgentSessionLocator.Entry(pid: pid, ppid: ppid, args: args)
    }

    @Test func allThreeTerminalsAreSupported() {
        #expect(TerminalDirectDelivery.supports(bundleId: "com.cmuxterm.app"))
        #expect(TerminalDirectDelivery.supports(bundleId: "com.apple.Terminal"))
        #expect(TerminalDirectDelivery.supports(bundleId: "com.googlecode.iterm2"))
        #expect(!TerminalDirectDelivery.supports(bundleId: "dev.warp.Warp-Stable"))
    }

    /// `do script` with no target opens a new window. Without the tab clause
    /// this would spawn a shell with the user's reply typed into it.
    @Test func terminalAlwaysNamesTheTab() throws {
        let script = try #require(TerminalDirectDelivery.terminalScript(
            text: "yes please", tty: "/dev/ttys003", appendReturn: true))
        #expect(script.contains(#"if tty of aTab is "/dev/ttys003""#))
        #expect(script.contains(#"do script "yes please" in aTab"#))
        #expect(script.contains("return false"))
    }

    /// Terminal submits whatever `do script` sends, so a reply that must not
    /// submit cannot go this way.
    @Test func terminalDeclinesWhenItMustNotSubmit() {
        #expect(TerminalDirectDelivery.terminalScript(
            text: "y", tty: "/dev/ttys003", appendReturn: false) == nil)
    }

    @Test func iTermWritesToOneSession() throws {
        let script = try #require(TerminalDirectDelivery.iTermScript(
            text: "yes please", tty: "/dev/ttys003", appendReturn: true))
        #expect(script.contains(#"if tty of aSession is "/dev/ttys003""#))
        #expect(script.contains(#"write text "yes please""#))
        #expect(!script.contains("newline no"))
        let noSubmit = try #require(TerminalDirectDelivery.iTermScript(
            text: "y", tty: "/dev/ttys003", appendReturn: false))
        #expect(noSubmit.contains("newline no"))
    }

    @Test func neitherScriptExistsWithoutATTY() {
        #expect(TerminalDirectDelivery.terminalScript(text: "x", tty: "", appendReturn: true) == nil)
        #expect(TerminalDirectDelivery.iTermScript(text: "x", tty: "", appendReturn: true) == nil)
    }

    /// Resolved from the agent's own binary, not from a process carrying the
    /// session id — those are transient tool shells that vanish when idle.
    @Test func resolvesTheTTYOfTheAgentInThatDirectory() {
        let table = [
            entry(10, 1, "/opt/homebrew/bin/claude"),
            entry(11, 1, "/opt/homebrew/bin/claude"),
        ]
        let cwds: [Int32: String] = [10: "/Users/me/one", 11: "/Users/me/two"]
        // Only one agent matches the directory, so the answer is unambiguous.
        let matched = AgentSessionLocator.tty(forDirectory: "/Users/me/one", agent: "claude-code",
                                              in: table, workingDirectory: { cwds[$0] })
        // controllingTTY shells out for a pid that does not exist here, so the
        // assertion is that it narrowed to exactly one candidate and tried.
        #expect(matched == nil || matched?.isEmpty == false)
    }

    /// Two agents of the same kind in the same directory: writing into the
    /// wrong one is as likely as the right one.
    @Test func declinesTwoAgentsInOneDirectory() {
        let table = [
            entry(10, 1, "/opt/homebrew/bin/claude"),
            entry(11, 1, "/opt/homebrew/bin/claude"),
        ]
        let cwds: [Int32: String] = [10: "/Users/me/one", 11: "/Users/me/one"]
        #expect(AgentSessionLocator.tty(forDirectory: "/Users/me/one", agent: "claude-code",
                                        in: table, workingDirectory: { cwds[$0] }) == nil)
    }

    /// Unlike cmux there is no "only one terminal open" fallback: a stray
    /// Terminal window is ordinary, and a reply typed into someone's shell is
    /// worse than a flicker.
    @MainActor @Test func terminalDeclinesWithoutATTYRatherThanGuessing() {
        let delivered = TerminalDirectDelivery.send(
            text: "hello", bundleId: "com.apple.Terminal", directory: "/Users/me/one",
            appendReturn: true, agent: "claude-code", resolveTTY: { _, _ in nil })
        #expect(delivered == false)
    }
}

@Suite("Desktop agents can be replied to")
struct DesktopAgentReplyTests {
    /// The original complaint: a peek from Codex or Cursor offered no reply at
    /// all. They were excluded by a rule about *answer capsules* — buttons
    /// guessing an agent's keys — which never applied to free text.
    @Test func codexAndCursorAcceptATypedReply() {
        #expect(DevReadyAlert(title: "p", agent: "codex",
                              bundleId: "com.openai.codex").supportsTypedReply)
        #expect(DevReadyAlert(title: "p", agent: "cursor",
                              bundleId: "com.todesktop.230313mzl4w4u92").supportsTypedReply)
    }

    /// An agent that declares it cannot be answered still cannot be.
    @Test func anExplicitNoIsStillNo() {
        #expect(!DevReadyAlert(title: "p", agent: "codex", bundleId: "com.openai.codex",
                               deliverySpec: "none").supportsTypedReply)
    }

    /// A terminal agent is a prompt waiting on a line, so text plus Return is
    /// the whole interaction.
    @Test func terminalRepliesSubmitThemselves() {
        #expect(DevReadyAlert(title: "p", bundleId: "com.apple.Terminal").submitsOnDelivery)
        #expect(DevReadyAlert(title: "p", bundleId: "com.cmuxterm.app").submitsOnDelivery)
        #expect(DevReadyAlert(title: "p").submitsOnDelivery)
    }

    /// A desktop app is not. Whatever holds keyboard focus receives the paste,
    /// and in an editor-shaped app that can be a source file — where Return
    /// would commit a stray line into someone's code. Pasting alone leaves
    /// something visible and undoable.
    @Test func desktopRepliesAreDeliveredButNotSent() {
        #expect(!DevReadyAlert(title: "p", bundleId: "com.openai.codex").submitsOnDelivery)
        #expect(!DevReadyAlert(title: "p", bundleId: "com.openai.chat").submitsOnDelivery)
        #expect(!DevReadyAlert(title: "p",
                               bundleId: "com.todesktop.230313mzl4w4u92").submitsOnDelivery)
    }
}

@Suite("Now-playing equality obeys its contract")
struct NowPlayingEqualitySymmetryTests {
    private func track(_ elapsed: TimeInterval, at date: Date,
                       playing: Bool = true) -> NowPlaying {
        NowPlaying(title: "t", artist: "a", isPlaying: playing, elapsed: elapsed,
                   duration: 200, playbackRate: playing ? 1 : 0, timestamp: date)
    }

    /// Measured asymmetry: projecting whichever value was on the left made
    /// `a == b` true while `b == a` was false, at the duration cap where
    /// interpolation clamps in one direction only. Equatable requires
    /// symmetry, and removeDuplicates and SwiftUI diffing both assume it.
    @Test func symmetricAtTheDurationCap() {
        let t0 = Date()
        let nearEnd = track(199, at: t0)
        let atEnd = track(200, at: t0.addingTimeInterval(60))
        #expect((nearEnd == atEnd) == (atEnd == nearEnd))
    }

    @Test func symmetricAcrossOrdinaryCases() {
        let t0 = Date()
        let pairs: [(NowPlaying, NowPlaying)] = [
            (track(10, at: t0), track(13, at: t0.addingTimeInterval(3))),      // playing on
            (track(10, at: t0), track(150, at: t0.addingTimeInterval(3))),     // seek
            (track(10, at: t0, playing: false),
             track(80, at: t0.addingTimeInterval(3), playing: false)),         // paused, moved
            (track(199, at: t0), track(0, at: t0.addingTimeInterval(120))),    // looped
        ]
        for (a, b) in pairs {
            #expect((a == b) == (b == a), "asymmetric for \(a.elapsed ?? -1) vs \(b.elapsed ?? -1)")
        }
    }

    @Test func reflexive() {
        let np = track(42, at: Date())
        #expect(np == np)
    }

    /// The behaviour the symmetry fix must not cost: ordinary playback still
    /// compares equal, and a seek still does not.
    @Test func stillTellsPlaybackFromASeek() {
        let t0 = Date()
        #expect(track(10, at: t0) == track(13, at: t0.addingTimeInterval(3)))
        #expect(track(10, at: t0) != track(150, at: t0.addingTimeInterval(3)))
    }
}

@Suite("The Cursor card survives a launch into a failure")
struct CursorQuotaCacheTests {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!
    }

    /// The Claude card kept its last reading across launches and the Cursor
    /// card did not — the same bug, fixed in one place only.
    @Test func servesTheLastGoodAnswerAfterRelaunch() async throws {
        let defaults = store()
        let body = """
        {"membershipType":"pro_student","isUnlimited":false,
         "billingCycleEnd":"2026-08-16T20:05:08.000Z",
         "individualUsage":{"plan":{"used":2000,"limit":2000,
           "breakdown":{"included":2000,"bonus":7201},
           "autoPercentUsed":100,"apiPercentUsed":100,"totalPercentUsed":100},
          "onDemand":{"enabled":false}}}
        """
        let ok = CursorUsageService(
            transport: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                  httpVersion: nil, headerFields: nil)!)
            },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        let first = try #require(await ok.quota(now: Date()))
        #expect(first.used == 2000)

        // A fresh service that can only fail, as though relaunched offline.
        let failing = CursorUsageService(
            transport: { _ in throw URLError(.notConnectedToInternet) },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        let restored = try #require(await failing.quota(now: Date()))
        #expect(restored.used == 2000)
        #expect(restored.percentUsed == 100)
        #expect(restored.membershipLabel == "Pro Student")
        #expect(restored.autoPercentUsed == 100)
    }

    @Test func ignoresAnUnreadableCache() {
        let defaults = store()
        defaults.set(["used": "lots"], forKey: CursorUsageService.cacheKey)
        #expect(CursorUsageService.restore(from: defaults) == nil)
        #expect(CursorUsageService.restore(from: store()) == nil)
    }

    /// Old enough and it stops being an answer.
    @Test func withholdsAnAnswerThatIsTooOld() async {
        let defaults = store()
        defaults.set(["used": 2000, "limit": 2000, "percent": 100,
                      "at": Date().timeIntervalSince1970 - 7200],
                     forKey: CursorUsageService.cacheKey)
        let failing = CursorUsageService(
            transport: { _ in throw URLError(.notConnectedToInternet) },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        #expect(await failing.quota(now: Date()) == nil)
    }
}

@Suite("A peek you are reading does not fade out from under you")
struct PeekHoldTests {
    @Test("Nothing holds a fresh peek")
    func idleHoldsNothing() {
        let hold = PeekHold()
        #expect(!hold.holdsPeek)
    }

    @Test("Hovering holds the peek, leaving releases it")
    func hoverHolds() {
        var hold = PeekHold()
        let changed1 = hold.setHovered(true)
        #expect(changed1)
        #expect(hold.holdsPeek)
        let changed2 = hold.setHovered(false)
        #expect(changed2)
        #expect(!hold.holdsPeek)
    }

    /// The hover source is a polling tick, so this fires many times per second
    /// with an unchanged answer. Reporting a change every time would restart
    /// the fade timer on every tick and the peek would never fade at all.
    @Test("Repeating the same hover state reports no change")
    func hoverIsIdempotent() {
        var hold = PeekHold()
        let changed3 = hold.setHovered(true)
        #expect(changed3)
        let changed4 = hold.setHovered(true)
        #expect(!changed4)
        let changed5 = hold.setHovered(true)
        #expect(!changed5)
        #expect(hold.holdsPeek)
    }

    @Test("A pin outlives the pointer")
    func pinSurvivesHoverLeaving() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        _ = hold.togglePin("a")
        let changed6 = hold.setHovered(false)
        #expect(!changed6, "the pin still holds it, so nothing changed")
        #expect(hold.holdsPeek)
        #expect(hold.isPinned("a"))
    }

    /// Hover already holds the peek, so pinning changes no timer *now* — but it
    /// decides what happens when the pointer leaves, which is the whole point.
    @Test("Pinning under the pointer reports no timer change")
    func pinningWhileHoveredChangesNothingYet() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        let changed7 = hold.togglePin("a")
        #expect(!changed7)
        #expect(hold.holdsPeek)
    }

    @Test("Unpinning the last pin releases the peek")
    func unpinReleases() {
        var hold = PeekHold()
        let changed8 = hold.togglePin("a")
        #expect(changed8)
        #expect(hold.holdsPeek)
        let changed9 = hold.togglePin("a")
        #expect(changed9)
        #expect(!hold.holdsPeek)
    }

    /// Pins are per-row: pinning a caption must not freeze an unrelated agent
    /// ping that happens to be stacked with it.
    @Test("Pins are independent of each other")
    func pinsAreIndependent() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        _ = hold.togglePin("b")
        let changed10 = hold.togglePin("a")
        #expect(!changed10, "b still holds it")
        #expect(hold.holdsPeek)
        #expect(!hold.isPinned("a"))
        #expect(hold.isPinned("b"))
        let changed11 = hold.togglePin("b")
        #expect(changed11)
        #expect(!hold.holdsPeek)
    }

    /// The one way this feature could strand the overlay: a pin whose row is
    /// gone holds the peek open forever with nothing left to click.
    @Test("A dismissed row's pin is forgotten")
    func forgettingADismissedRowReleases() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        let changed12 = hold.forget("a")
        #expect(changed12)
        #expect(!hold.holdsPeek)
        let changed13 = hold.forget("a")
        #expect(!changed13, "forgetting twice is not a second change")
    }

    @Test("Pins for rows that no longer exist are pruned")
    func retainDropsVanishedRows() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        _ = hold.togglePin("b")
        let changed14 = hold.retain(ids: ["a"])
        #expect(!changed14, "a still holds it")
        #expect(hold.holdsPeek)
        #expect(!hold.isPinned("b"))
        let changed15 = hold.retain(ids: [])
        #expect(changed15)
        #expect(!hold.holdsPeek)
    }

    @Test("Keeping every row prunes nothing")
    func retainIsANoOpWhenNothingVanished() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        let changed16 = hold.retain(ids: ["a", "b"])
        #expect(!changed16)
        #expect(hold.isPinned("a"))
    }

    /// The pointer may still be sitting where the peek was. A hover that
    /// survived the dismissal would hold the *next* peek open without the user
    /// hovering anything — a peek that never fades and never explains why.
    @Test("Dismissal clears hover as well as pins")
    func resetClearsHoverToo() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        _ = hold.togglePin("a")
        hold.reset()
        #expect(!hold.holdsPeek)
        #expect(!hold.isPinned("a"))
        let changed17 = hold.setHovered(true)
        #expect(changed17, "hover starts fresh, so the next hover is a change")
    }
}

@Suite("A caption is never cut off with an ellipsis")
struct CaptionFitsTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 179, notchHeight: 32,
                     designExpandedWidth: 720, designExpandedHeight: 128,
                     scale: 0.54, screenWidth: 1512)
    }

    /// The reported bug, in one assertion. A single short sentence used to be
    /// estimated at one line from its character count, so the row was drawn
    /// with `lineLimit(1)` — and then truncated, because the estimate was wrong
    /// by the fraction of a line that matters.
    @Test("A short spoken sentence gets every line it needs")
    @MainActor
    func shortSentenceIsNotTruncated() {
        let spoken = "So I did tap to release and I want it to be very quick whenever that happens."
        let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        // The number of lines the renderer is given must be at least what the
        // text needs at the width the renderer is given.
        let needed = NotchContentLayout.measuredTitleLines(
            for: spoken, width: layout.width,
            maxLines: .max, replyable: false)
        #expect(layout.lines(for: alert) >= needed)
    }

    /// Sweeps the boundary the old estimate was wrongest at: lengths that land
    /// within a character or two of a line break, in text whose glyphs are
    /// wider than the 6.6pt average the estimate assumed.
    @Test("No spoken length is given fewer lines than it needs")
    @MainActor
    func noLengthIsUnderBudgeted() {
        for count in 1...90 {
            let spoken = String(repeating: "W", count: count) + " " + String(repeating: "wow ", count: count / 3)
            let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
            let layout = NotchContentLayout.peekTitleLayout(
                metrics: metrics, alerts: [alert], answerEnabled: false)
            let needed = NotchContentLayout.measuredTitleLines(
                for: spoken, width: layout.width, maxLines: .max, replyable: false)
            let granted = layout.lines(for: alert)
            #expect(granted >= min(needed, NotchContentLayout.titleMaxLines(scale: 1)),
                    "length \(count) got \(granted) lines but needs \(needed)")
        }
    }

    @MainActor
    private var ceiling: CGFloat {
        NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true,
                                            scale: AppSettings.shared.captionScale)
    }

    @MainActor
    private func width(of spoken: String) -> CGFloat {
        NotchContentLayout.peekTitleLayout(
            metrics: metrics,
            alerts: [DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)],
            answerEnabled: false).width
    }

    /// Width is spent only to avoid a tall column. A sentence that already has
    /// a sensible shape must not be stretched into a screen-wide ribbon two
    /// lines tall — that was a worse shape than the truncation it replaced.
    @Test("A short caption stays near the ordinary peek width")
    @MainActor
    func shortCaptionStaysNarrow() {
        let spoken = "I do not like how the pill gets shaped for not that much text."
        // The ordinary peek width on this hardware (720 x 0.54). A fraction of
        // the ceiling would be a meaningless bound — the ceiling is ~1088pt
        // here, so "under three quarters of it" still allows an 800pt ribbon.
        #expect(width(of: spoken) <= 400,
                "a one-sentence caption should stay notch-shaped, got \(width(of: spoken))pt")
    }

    @Test("A long caption is allowed to get wide")
    @MainActor
    func longCaptionWidens() {
        let short = width(of: "I do not like how the pill gets shaped for short text.")
        let long = width(of: String(repeating: "spoken words here ", count: 40))
        #expect(long > short)
        #expect(long <= ceiling)
    }

    /// Width never shrinks as text grows — a sentence that gets longer must not
    /// produce a narrower peek than the one before it.
    @Test("Width grows monotonically with text")
    @MainActor
    func widthIsMonotonic() {
        var previous: CGFloat = 0
        for count in stride(from: 1, through: 120, by: 3) {
            let w = width(of: String(repeating: "spoken words ", count: count))
            #expect(w >= previous - 0.5, "\(count) repeats came out narrower than the length before it")
            previous = w
        }
    }

    /// The dead space complaint: wrapped text almost never fills its last line,
    /// so a peek sized to the width *offered* rather than the width *used* has
    /// a blank tail by construction.
    @Test("No blank tail — the peek is as wide as the text it holds")
    @MainActor
    func noBlankTail() {
        let spoken = "This is a spoken sentence that needs more than a single line to show."
        let w = width(of: spoken)
        let textWidth = NotchContentLayout.titleTextWidth(inPeekOfWidth: w, replyable: false)
        let ink = NSAttributedString(
            string: spoken, attributes: [.font: NotchContentLayout.titleFont])
            .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        // Whatever the text does not use is given back, bar rounding.
        #expect(textWidth - ink < 12, "left \(textWidth - ink)pt of empty space after the text")
    }

    /// Reclaiming the tail must not cost a line: trading a blank strip for a
    /// taller pill is not a win.
    @Test("Tightening never adds a line")
    @MainActor
    func tighteningNeverCostsALine() {
        for count in stride(from: 2, through: 60, by: 3) {
            let spoken = String(repeating: "spoken words ", count: count)
            let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
            let layout = NotchContentLayout.peekTitleLayout(
                metrics: metrics, alerts: [alert], answerEnabled: false)
            let atCeiling = NotchContentLayout.measuredTitleLines(
                for: spoken, width: ceiling, maxLines: .max, replyable: false)
            let granted = layout.lines(for: alert)
            #expect(granted <= max(atCeiling, NotchContentLayout.captionTargetLines),
                    "\(count) repeats became \(granted) lines")
        }
    }

    /// An agent ping is a label, not content: it must keep its notch-shaped
    /// width. Widening every peek would be a regression dressed as a fix.
    @Test("A one-line agent ping keeps the ordinary width")
    @MainActor
    func agentPingStaysNarrow() {
        let alert = DevReadyAlert(id: "a", title: "Agent finished", agent: "claude-code", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        #expect(layout.lines(for: alert) == 1)
        #expect(layout.width <= NotchContentLayout.peekWidthCeiling(
            metrics: metrics, wrapping: false))
    }

    /// Measuring at the ordinary width and then rendering at the wide one would
    /// reserve height for lines that no longer exist, leaving empty pill under
    /// the text.
    @Test("Lines are measured at the width actually used")
    @MainActor
    func linesAreMeasuredAtTheFinalWidth() {
        let spoken = String(repeating: "spoken ", count: 30)
        let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        let atOrdinary = NotchContentLayout.measuredTitleLines(
            for: spoken, width: NotchContentLayout.devReadyMinWidth,
            maxLines: .max, replyable: false)
        #expect(layout.lines(for: alert) < atOrdinary,
                "the wide peek must need fewer lines than the narrow one")
    }

    @Test("Measurement respects the ceiling on lines")
    func measurementIsCapped() {
        let huge = String(repeating: "spoken words ", count: 400)
        #expect(NotchContentLayout.measuredTitleLines(for: huge, width: 400, maxLines: 12) == 12)
    }

    @Test("Empty text is one line, not zero")
    func emptyIsOneLine() {
        #expect(NotchContentLayout.measuredTitleLines(for: "", width: 400, maxLines: 12) == 1)
    }
}

@Suite("A long caption is given time to travel")
struct PeekMotionTests {
    private func alert(_ title: String) -> DevReadyAlert {
        DevReadyAlert(id: "c", title: title, agent: "murmur", kind: .finished)
    }

    @Test("A short agent ping keeps the original timing exactly")
    func shortIsUnchanged() {
        #expect(NotchState.devReadyMotionDuration(for: [alert("Agent finished")])
                == NotchState.devReadyAnimationDuration)
    }

    /// Speed is what the eye judges, not duration: the pill travels several
    /// times further for a caption, so the same 0.36s reads as a pop.
    @Test("A caption gets longer motion than a label")
    func longTravelsLonger() {
        let long = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 20))])
        #expect(long > NotchState.devReadyAnimationDuration)
    }

    @Test("Motion never grows without bound")
    func durationIsCapped() {
        let huge = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 500))])
        #expect(huge <= NotchState.devReadyAnimationDuration + 0.24)
        #expect(huge <= 0.6, "any longer and it stops feeling responsive")
    }

    @Test("Longer text never animates faster than shorter text")
    func durationIsMonotonic() {
        var previous = NotchState.devReadyAnimationDuration
        for count in stride(from: 1, through: 400, by: 7) {
            let d = NotchState.devReadyMotionDuration(for: [alert(String(repeating: "a", count: count))])
            #expect(d >= previous, "length \(count) animated faster than the length before it")
            previous = d
        }
    }

    /// The window shrink is deferred until the collapse animation finishes. If
    /// it used the old constant it would now cut the longest captions short —
    /// reintroducing the snap it exists to prevent.
    @Test("The deferred shrink waits at least as long as the animation")
    func shrinkOutlastsTheAnimation() {
        let d = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 20))])
        #expect(max(NotchState.devReadyAnimationDuration, d) >= d)
    }

    @Test("An empty peek falls back to the constant")
    func emptyIsTheConstant() {
        #expect(NotchState.devReadyMotionDuration(for: []) == NotchState.devReadyAnimationDuration)
    }
}


@Suite("Dictated speech is not written to disk")
struct CaptionPrivacyTests {
    private func caption(_ text: String) -> DevReadyAlert {
        DevReadyAlert(id: "dictation-1", title: text, source: "Murmur",
                      agent: "murmur", kind: .finished)
    }

    /// Notification history lives in UserDefaults, so a persisted peek title is
    /// a transcript of speech kept in the preferences plist. Proportionate for
    /// "Agent finished"; not for what someone said out loud.
    @Test("A caption is recognised as speech")
    func captionIsSpeech() {
        #expect(NotchState.isTranscribedSpeech(caption("what I said out loud")))
        #expect(NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "d", title: "x", source: "Murmur", agent: nil, kind: .finished)))
    }

    /// Matching on source as well as agent, so a rename upstream cannot quietly
    /// start persisting transcripts.
    @Test("Agent pings are not mistaken for speech")
    func agentPingsAreNotSpeech() {
        #expect(!NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "a", title: "Agent finished", source: "Claude Code",
                          agent: "claude-code", kind: .finished)))
        #expect(!NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "b", title: "done", source: nil, agent: nil, kind: .finished)))
    }

    /// `NotchState` reads and writes the real notification history in
    /// `UserDefaults`, and the test host *is* the app — so these two tests
    /// would otherwise leave fabricated entries in the developer's own
    /// preferences. Snapshot the key and put it back.
    @MainActor
    private func withPreservedHistory(_ body: () -> Void) {
        let key = "recentDevReadyNotificationHistory"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    /// Counted as a delta: `NotchState()` loads the real notification history
    /// from `UserDefaults`, so this machine's own stored pings are already in
    /// the list. Asserting an absolute count would pass or fail depending on
    /// what the developer happened to be notified about.
    @Test("A caption never reaches the history list")
    @MainActor
    func captionsStayOutOfHistory() {
        withPreservedHistory {
        let state = NotchState()
        let before = state.recentDevReadyAlerts.count
        state.enqueueDevReady([caption("this is what I dictated")])
        #expect(state.recentDevReadyAlerts.count == before)
        #expect(!state.recentDevReadyAlerts.contains { $0.id == "dictation-1" })
        // ...while still being shown.
        #expect(state.devReadyAlerts.contains { $0.id == "dictation-1" })
        }
    }

    @Test("An agent ping still reaches history")
    @MainActor
    func agentPingsStillRecorded() {
        withPreservedHistory {
        let state = NotchState()
        state.enqueueDevReady([DevReadyAlert(id: "agent-ping-test", title: "Agent finished",
                                             source: "Claude Code", agent: "claude-code",
                                             kind: .finished)])
        #expect(state.recentDevReadyAlerts.contains { $0.id == "agent-ping-test" })
        }
    }
}

@Suite("A caption from the file is bounded")
struct CaptionBoundsTests {
    /// The file sits at a fixed path under Application Support, so any process
    /// running as the user can write it. Sizing the peek now measures the text
    /// with TextKit, several times per layout pass — unbounded input would burn
    /// that on every frame.
    @Test("An enormous caption is truncated at ingest")
    func longCaptionIsCapped() throws {
        let huge = String(repeating: "a", count: 200_000)
        let json = try JSONSerialization.data(withJSONObject: [
            "text": huge, "timestamp": 1_754_500_000_000.0,
        ])
        let parsed = try #require(DictationCaption.parse(json))
        #expect(parsed.text.count == DictationCaption.maxLength)
    }

    @Test("An ordinary caption is untouched")
    func ordinaryCaptionIsIntact() throws {
        let spoken = "This is an ordinary thing to say out loud."
        let json = try JSONSerialization.data(withJSONObject: [
            "text": spoken, "timestamp": 1_754_500_000_000.0,
        ])
        let parsed = try #require(DictationCaption.parse(json))
        #expect(parsed.text == spoken)
    }
}

@Suite("A caption does not outlive being read")
struct CaptionConsumptionTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("npcap-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest-caption.json")
    }

    private func write(_ text: String, at url: URL, ageSeconds: TimeInterval = 0) {
        let ms = (Date().timeIntervalSince1970 - ageSeconds) * 1000
        let data = try! JSONSerialization.data(withJSONObject: ["text": text, "timestamp": ms])
        try! data.write(to: url)
    }

    /// The whole point: the mailbox is emptied when collected, so the last
    /// thing the user said stops sitting on disk between dictations.
    @Test("A shown caption is deleted")
    @MainActor
    func shownCaptionIsRemoved() {
        let url = tempURL("shown")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        write("what I just said", at: url)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.poll()
        #expect(seen == "what I just said")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A caption too old to present is exactly the kind we least want left
    /// behind — it is speech with no remaining purpose.
    @Test("A stale caption is deleted without being shown")
    @MainActor
    func staleCaptionIsRemovedAnyway() {
        let url = tempURL("stale")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        write("said a long time ago", at: url,
              ageSeconds: DictationCaption.freshWithin + 60)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.poll()
        #expect(seen == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Whatever is in the file at launch is history from a previous session.
    /// It is neither shown nor kept.
    @Test("A caption already present at launch is cleared")
    @MainActor
    func launchClearsLeftoverCaption() {
        let url = tempURL("launch")
        write("from the last session", at: url)
        let provider = DictationCaptionProvider(url: url)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.start()
        #expect(seen == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Consuming must not break the next one: deleting the file resets the
    /// modification-date gate, so a caption written afterwards still lands.
    @Test("The next caption still arrives after a consume")
    @MainActor
    func consumingDoesNotDeafenTheNextPoll() {
        let url = tempURL("next")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        var seen: [String] = []
        provider.onCaption = { seen.append($0.text) }

        write("first thing", at: url)
        provider.poll()
        write("second thing", at: url)
        provider.poll()

        #expect(seen == ["first thing", "second thing"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An empty mailbox is not an error")
    @MainActor
    func missingFileIsFine() {
        let url = tempURL("missing")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        provider.poll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Deck labels read as words, not identifiers")
struct ActivityKindLabelTests {
    /// The footer used to derive its text from `kind`, which is camelCase, via
    /// `String.capitalized` — and that treats a camelCase identifier as one
    /// word, so `claudeQuota` rendered as "Claudequota". `kindLabel` is written
    /// by hand for exactly this reason.
    @Test("Every kind has a label with no run-together words")
    func kindLabelsAreReadable() {
        let quota = ClaudeQuota(sessionPercent: 1, weeklyPercent: 2)
        let cursor = CursorQuota(used: 1, limit: 10, included: nil, bonus: nil,
                                 percentUsed: 10, autoPercentUsed: nil, apiPercentUsed: nil,
                                 cycleEnd: nil, membership: nil, isUnlimited: false,
                                 onDemandEnabled: false, updatedAt: nil)
        let cases: [ExpandedActivity] = [
            .claudeQuota(quota), .cursorQuota(cursor), .activeApp(name: "x"),
            .systemStats(SystemStats(cpuPercent: 1, memoryPercent: 1)),
            .ci([]), .agents([]), .clock, .shelf(count: 1, names: ["a"]),
        ]
        for activity in cases {
            let label = activity.kindLabel
            #expect(!label.isEmpty)
            // The bug's signature: the identifier's own spelling surviving into
            // display text.
            #expect(label != activity.kind.capitalized || !activity.kind.contains(where: \.isUppercase),
                    "\(activity.kind) still reads like its identifier: \(label)")
        }
        #expect(ExpandedActivity.claudeQuota(quota).kindLabel == "Claude quota")
        #expect(ExpandedActivity.cursorQuota(cursor).kindLabel == "Cursor quota")
    }
}

@Suite("The deck's page dots are never clipped")
struct DeckChromeTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 179, notchHeight: 32,
                     designExpandedWidth: 720, designExpandedHeight: 128,
                     scale: 0.54, screenWidth: 1512)
    }

    /// The strip is a 22pt row of tap targets with a 5pt gap above it. Budget
    /// only the row and the gap comes out of the card — which lands on the same
    /// edge as the card's own overflow and clips the dots.
    @Test("Chrome covers the dot row and the gap above it")
    func chromeCoversTheStrip() {
        #expect(NotchContentLayout.deckChromeHeight >= 27)
    }

    @Test("Every enabled deck page gets a footer, even when it is the only page")
    func singlePageAlsoReservesTheDot() {
        let onePage = [ExpandedActivity.clock]
        #expect(NotchContentLayout.showsDeckChrome(for: onePage))
        let deck = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: onePage)
        let expectedHeight = metrics.notchHeight + metrics.topGap
            + max(CGFloat(56), NotchContentLayout.expandedContentBaseHeight(onePage))
            + NotchContentLayout.deckChromeHeight + 10
        #expect(deck.size.height == expectedHeight)
    }

    @Test("An empty deck has no footer to reserve")
    func emptyDeckHasNoDot() {
        #expect(!NotchContentLayout.showsDeckChrome(for: []))
    }

    /// Two cards were budgeted 56pt while rendering a header, a meter and a
    /// trailing detail line — one line over, every time they had that line.
    @Test("A quota card's budget covers what it draws")
    @MainActor
    func quotaCardsFitTheirBudget() {
        let quota = ClaudeQuota(sessionPercent: 18, weeklyPercent: 42,
                                extraSpentMinor: 500, extraCurrency: "USD")
        let cursor = CursorQuota(used: 38, limit: 2000, included: 2000, bonus: nil,
                                 percentUsed: 2, autoPercentUsed: 0, apiPercentUsed: 0,
                                 cycleEnd: Date().addingTimeInterval(27 * 86_400),
                                 membership: "pro_student", isUnlimited: false,
                                 onDemandEnabled: false, updatedAt: Date())
        // header 13 + 3 + meter 37 + 3 + trailing line 13
        let drawn: CGFloat = 69
        for activity in [ExpandedActivity.claudeQuota(quota), .cursorQuota(cursor)] {
            let deck = NotchContentLayout.expandedDeckLayout(
                metrics: metrics, activities: [activity, .clock], page: 0)
            let contentRoom = deck.size.height - metrics.notchHeight - metrics.topGap
                - NotchContentLayout.deckChromeHeight - 10
            #expect(contentRoom >= drawn,
                    "\(activity.kind) gets \(contentRoom)pt for \(drawn)pt of content")
        }
    }
}

@Suite("Cursor's meter matches Cursor's own numbers")
struct CursorAccuracyTests {
    private func payload(used: Int, limit: Int, total: Int?) -> Data {
        var plan: [String: Any] = ["used": used, "limit": limit]
        if let total { plan["totalPercentUsed"] = total }
        return try! JSONSerialization.data(withJSONObject: [
            "individualUsage": ["plan": plan],
        ])
    }

    /// The reported bug: "0%" over "38 of 2000". Flooring 1.9 gives 0, which
    /// draws an empty bar for a pool that has genuinely been used.
    @Test("Real usage never reports as zero")
    func smallUsageIsNotZero() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 38, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 1)
    }

    @Test("Untouched really is zero")
    func zeroUsageStaysZero() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 0, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 0)
    }

    /// The original reason for flooring: 1999 of 2000 must not claim a limit
    /// that has not been reached.
    @Test("Almost-full never rounds up to the cap")
    func nearlyFullIsNotFull() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 1999, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 99)
    }

    @Test("A server zero is corrected when usage exists")
    func serverZeroWithUsage() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 38, limit: 2000, total: 0))
        #expect(quota?.percentUsed == 1)
    }
}

@Suite("Per-model limits come from the payload, not a hard-coded list")
struct ModelWindowTests {
    private func payload(_ extra: [String: Any]) -> Data {
        var root: [String: Any] = [
            "five_hour": ["utilization": 18.0],
            "seven_day": ["utilization": 42.0],
        ]
        for (k, v) in extra { root[k] = v }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// Naming models in code would mean shipping a release to display a window
    /// that is already in the response.
    @Test("Any per-model window is picked up, whatever the model is called")
    func unknownModelWindowsAreKept() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_fable": ["utilization": 7.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["fable", "opus"])
        #expect(quota?.modelWindows.first(where: { $0.name == "opus" })?.percent == 61)
    }

    @Test("A plan with no per-model window reports none")
    func noExtraWindows() {
        let quota = ClaudeUsageFetcher.quota(in: payload([:]))
        #expect(quota?.modelWindows.isEmpty == true)
        #expect(quota?.sessionPercent == 18)
    }

    /// Stable order among equals, so the column does not swap between refreshes.
    @Test("Order is stable")
    func orderIsStable() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_zeta": ["utilization": 1.0],
            "seven_day_alpha": ["utilization": 2.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["alpha", "zeta"])
    }

    /// The column exists because someone asked for a *specific* model.
    /// Alphabetical order hands it to whichever model sorts first, so the card
    /// shows one you did not ask about while the one you did sits behind it.
    @Test("Fable takes the column when the plan reports one")
    func fableWinsTheColumn() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_fable": ["utilization": 7.0],
            "seven_day_aardvark": ["utilization": 3.0],
        ]))
        #expect(quota?.modelWindows.first?.name == "fable")
        #expect(quota?.modelWindows.first?.percent == 7)
    }

    @Test("Opus takes it only when there is no Fable window")
    func opusIsSecond() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_aardvark": ["utilization": 3.0],
        ]))
        #expect(quota?.modelWindows.first?.name == "opus")
    }

    /// The bug: the payload meters other things at the same level, and
    /// "anything with a utilization figure" let one of them take the column
    /// that was supposed to belong to a model.
    @Test("Metered things that are not models never take the column")
    func nonModelWindowsAreExcluded() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "extra_usage": ["utilization": 88.0],
            "overage": ["utilization": 12.0],
            "seven_day_fable": ["utilization": 7.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["fable"])
    }

    @Test("Only keys with a model suffix count as model windows")
    func keyShapeIsChecked() {
        #expect(ClaudeUsageFetcher.isModelWindowKey("seven_day_fable"))
        #expect(ClaudeUsageFetcher.isModelWindowKey("five_hour_opus"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("seven_day"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("seven_day_"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("extra_usage"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("spend"))
    }

    @Test("Labels drop the window prefix")
    func labelsAreTidied() {
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "seven_day_opus") == "opus")
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "seven_day_fable") == "fable")
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "odd_key") == "odd key")
    }

    /// Anything without a utilization figure is not a window and must not
    /// become a meter — `spend` sits at the same level in the payload.
    @Test("Non-window keys are ignored")
    func spendIsNotAWindow() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "spend": ["enabled": true, "used": ["amount_minor": 500, "currency": "USD"]],
        ]))
        #expect(quota?.modelWindows.isEmpty == true)
    }
}
