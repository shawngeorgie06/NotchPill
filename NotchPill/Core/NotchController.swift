import AppKit
import SwiftUI
import Combine

/// Owns the overlay window, its placement over the physical notch, hover-driven
/// expand/collapse with a grace delay, multi-display handling, and the wiring
/// of every data provider into the single `NotchState`.
@MainActor
final class NotchController {
    private let state = NotchState()
    private let shelf = ShelfStore()
    private var window: NotchWindow?
    private var container: NotchContainerView?
    private var metrics = NotchMetrics(notchWidth: 200, notchHeight: 32,
                                       designExpandedWidth: NotchGeometry.expandedWidth,
                                       designExpandedHeight: NotchGeometry.expandedHeight,
                                       scale: NotchGeometry.expandedScale,
                                       topGap: NotchGeometry.contentTopGap)

    // Providers.
    private let nowPlaying = NowPlayingProvider()
    private let volume = VolumeProvider()
    private let brightness = BrightnessProvider()
    private let microphone = MicrophoneProvider()
    private let calendar = CalendarProvider()
    private let airDrop = AirDropProvider()
    private let appSwitch = AppSwitchProvider()
    private let systemStats = SystemStatsProvider()
    private let battery = BatteryProvider()
    private let devReady = DevReadyProvider()
    private let transcripts = AgentTranscriptProvider()
    private let cursorActivity = CursorActivityProvider()
    private let agentSessions = AgentSessionsProvider()
    private let ciStatus = CIStatusProvider()
    private var ciTimer: Timer?
    private let replyHotKey = GlobalHotKey()
    /// Most-recent finished-agent alert, kept so the reply hotkey can target it
    /// even after its peek has auto-dismissed.
    private var lastFinishedAlert: DevReadyAlert?

    // Hover.
    private var collapseWorkItem: DispatchWorkItem?
    private let collapseGrace: TimeInterval = 0.16
    private let hotZoneKeys = HotZoneKeyMonitor()
    private var arming = ShortcutArming()
    private let hoverMonitor = HoverMonitor()
    var keyMonitor: HotZoneKeyMonitor { hotZoneKeys }

    /// Screen-space hover targets derived from NotchGeometry (not view layout).
    private var collapsedHotZone: CGRect = .zero
    private var expandedHotZone: CGRect = .zero

    /// Screen-space menu bar strip on the built-in display, if present.
    private var menuBarStrip: CGRect = .zero
    private var geometry: NotchGeometry?

    private var expandWorkItem: DispatchWorkItem?
    /// Stays expanded while the pointer is over the pill or the user just clicked it.
    private var pillEngaged = false
    /// Delay before expanding so quick mouse moves (e.g. to browser tabs) don't trigger it.
    private let hoverExpandDelay: TimeInterval = 0.03

    private var devReadyDismissItem: DispatchWorkItem?
    private var devReadyCoalesceItem: DispatchWorkItem?
    private var pendingDevReadyAlerts: [DevReadyAlert] = []
    private var devReadyDedup = DevReadyDedup()
    /// Escape-key monitors, installed only while a peek is showing.
    private var peekEscapeMonitors: [Any] = []
    /// Ages out on-screen waiting peeks; runs only while one is up.
    private var waitingStaleTimer: Timer?

    private var cancellables = Set<AnyCancellable>()

    func start() {
        replyHotKey.onPressed = { [weak self] in self?.openReplyForLatest() }
        replyHotKey.register()
        hotZoneKeys.onTogglePlayPause = { [weak self] in self?.nowPlaying.togglePlayPause() }
        hotZoneKeys.onNext = { [weak self] in self?.nowPlaying.next() }
        hotZoneKeys.onPrevious = { [weak self] in self?.nowPlaying.previous() }
        hotZoneKeys.onVolumeUp = { [weak self] in self?.volume.volumeUp() }
        hotZoneKeys.onVolumeDown = { [weak self] in self?.volume.volumeDown() }
        hotZoneKeys.pointerInHotZone = { [weak self] in
            self?.refreshShortcutArming() ?? false
        }
        hotZoneKeys.start()

        hoverMonitor.onEnter = { [weak self] in
            self?.hotZoneKeys.updatePointerInHotZone(true)
            self?.pointerEnteredHot()
        }
        hoverMonitor.onExit = { [weak self] in
            self?.hotZoneKeys.updatePointerInHotZone(false)
            self?.pointerExitedHot()
        }
        hoverMonitor.onTick = { [weak self] _ in
            self?.handleHoverTick()
        }
        hoverMonitor.expandZoneScreenRect = { [weak self] in self?.expandHoverScreenRect() ?? .zero }
        hoverMonitor.pointBlocksHover = { [weak self] point in
            guard let self else { return false }
            // Only block hover-to-expand over browser tabs — never while expanded/engaged.
            if self.state.isExpanded || self.pillEngaged { return false }
            return self.isPointerInBrowserFlank(point)
        }
        hoverMonitor.start()

        rebuildForCurrentDisplays()
        wireProviders()

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        NotificationCenter.default.addObserver(
            self, selector: #selector(testDevReadyFromSettings),
            name: .notchPillTestDevReady, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(testMultipleDevReadyFromSettings),
            name: .notchPillTestMultipleDevReady, object: nil)

        // Resize window and refresh hover when expansion or chip content changes.
        state.$isExpanded
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.applyWindowFrame(animated: true)
                self?.container?.refreshTracking()
            }
            .store(in: &cancellables)

        Publishers.MergeMany(
            state.$nowPlaying.map { _ in () }.eraseToAnyPublisher(),
            state.$nextEvent.map { _ in () }.eraseToAnyPublisher(),
            state.$appSwitchHint.map { _ in () }.eraseToAnyPublisher(),
            state.$systemStats.map { _ in () }.eraseToAnyPublisher(),
            state.$battery.map { _ in () }.eraseToAnyPublisher(),
            AppSettings.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            shelf.$items.map { _ in () }.eraseToAnyPublisher(),
            TimerStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
            state.$devReadyAlerts.map { _ in () }.eraseToAnyPublisher(),
            state.$agentSessions.map { _ in () }.eraseToAnyPublisher(),
            state.$ciRuns.map { _ in () }.eraseToAnyPublisher(),
            state.$updateProgress.map { _ in () }.eraseToAnyPublisher(),
            state.$replyCompose.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            // Defer so @Published settings and state are committed before relayout.
            DispatchQueue.main.async {
                self?.refreshOverlayContent(animated: true)
                self?.syncPeekEscapeMonitors()
                self?.syncWaitingStaleTimer()
            }
        }
        .store(in: &cancellables)

        // The pill's size is baked into `metrics`, which is only built when the
        // display layout changes — so a size change has to force that rebuild or
        // it would not take effect until you unplugged a monitor.
        AppSettings.shared.$notchScale
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildForCurrentDisplays() }
            .store(in: &cancellables)

        // Mirror live update progress into state so the overlay shows a bar.
        UpdateProgressStore.shared.$progress
            .receive(on: RunLoop.main)
            .sink { [weak self] progress in self?.state.updateProgress = progress }
            .store(in: &cancellables)

        // Pause auto-dismiss and take key focus while the reply composer is open.
        state.$replyCompose
            .receive(on: RunLoop.main)
            .sink { [weak self] compose in
                guard let self else { return }
                // Suspend hot-zone key shortcuts so space/arrows type into the
                // composer instead of toggling media / skipping tracks.
                self.hotZoneKeys.suspended = compose != nil
                if compose != nil {
                    self.devReadyDismissItem?.cancel()      // hold the peek open
                    self.window?.makeKeyAndOrderFront(nil)  // accept typing (nonactivating panel → no app switch)
                } else {
                    // Don't call resignKey() directly (system-owned). On send,
                    // performReply activates the terminal which takes key away;
                    // on cancel the nonactivating panel simply stops needing key.
                    // Only finished peeks fade; a waiting-only peek must not have
                    // a dismiss timer re-armed behind it.
                    if self.state.devReadyAlerts.contains(where: { $0.kind == .finished }) {
                        self.scheduleDevReadyDismiss()      // resume normal timeout
                    }
                }
            }
            .store(in: &cancellables)
    }

    func testSystemVolumeUp() {
        volume.volumeUp()
    }

    func testDevReadyPing() {
        presentDevReady(DevReadyAlert(
            title: "Agent finished",
            subtitle: "Review the changes",
            source: "Cursor",
            agent: "Composer",
            bundleId: Bundle.main.bundleIdentifier
        ))
    }

    func testMultipleDevReadyPings() {
        presentDevReady(DevReadyAlert(
            title: "Refactor complete",
            subtitle: "3 files changed",
            source: "Cursor",
            agent: "Composer",
            bundleId: "com.todesktop.230313mzl4w4u92"
        ))
        presentDevReady(DevReadyAlert(
            title: "Tests passed",
            subtitle: "All green",
            source: "Terminal",
            agent: "claude-code",
            bundleId: "com.apple.Terminal"
        ))
        presentDevReady(DevReadyAlert(
            title: "Build finished",
            subtitle: "Ready to ship",
            source: "Windsurf",
            agent: "Cascade",
            bundleId: nil
        ))
    }

    private func makeRootView() -> NotchRootView {
        let actions = NotchActions(
            togglePlayPause: { [weak self] in self?.nowPlaying.togglePlayPause() },
            next: { [weak self] in self?.nowPlaying.next() },
            previous: { [weak self] in self?.nowPlaying.previous() },
            focusApp: { [weak self] bundleId in self?.focusSourceApp(bundleId: bundleId) },
            dismissDevReady: { [weak self] id in self?.dismissDevReady(id: id) },
            dismissPeek: { [weak self] id in self?.dismissPeek(id: id) },
            beginReply: { [weak self] alert in self?.state.beginReply(to: alert) },
            sendReply: { [weak self] alert, text in self?.performReply(alert: alert, text: text) },
            beginPlanRevision: { [weak self] alert in self?.state.beginPlanRevision(for: alert) },
            submitPlanRevision: { [weak self] alert, text in self?.performPlanRevision(alert: alert, feedback: text) },
            answer: { [weak self] alert, ans in self?.performAnswer(alert: alert, answer: ans) },
            clearRecentActivity: { [weak self] in self?.state.clearRecentDevReady() },
            focusAgentSession: { [weak self] session in self?.focusAgentSession(session) },
            openURL: { url in
                guard let u = URL(string: url) else { return }
                NSWorkspace.shared.open(u)
            }
        )
        return NotchRootView(state: state, shelf: shelf, timer: TimerStore.shared, metrics: metrics, actions: actions)
    }

    private func refreshOverlayContent(animated: Bool) {
        guard window != nil else { return }
        applyWindowFrame(animated: animated)
        container?.refreshTracking()
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        hoverMonitor.stop()
        hotZoneKeys.stop()
        nowPlaying.stop(); calendar.stop(); airDrop.stop(); appSwitch.stop()
        systemStats.stop(); battery.stop(); devReady.stop(); brightness.stop(); microphone.stop()
        replyHotKey.unregister()
        peekEscapeMonitors.forEach(NSEvent.removeMonitor)
        peekEscapeMonitors = []
        waitingStaleTimer?.invalidate()
        waitingStaleTimer = nil
        window?.orderOut(nil)
    }

    /// Opens the reply composer for the agent peek currently on screen, or — when
    /// nothing is showing — the most-recent *finished* agent (whose peek has since
    /// auto-dismissed). Bound to the ⌥⌘R global hotkey.
    private func openReplyForLatest() {
        guard AppSettings.shared.agentReplyEnabled else { return }
        guard let alert = state.devReadyAlerts.last ?? lastFinishedAlert,
              TerminalReplyInjector.canTarget(alert) else { return }
        state.beginReply(to: alert)
    }

    // MARK: - Providers

    private func wireProviders() {
        nowPlaying.onUpdate = { [weak self] np in self?.state.notifyMediaChanged(np) }
        calendar.onUpdate = { [weak self] event in self?.state.nextEvent = event }
        airDrop.onUpdate = { [weak self] status in self?.state.airDrop = status }
        appSwitch.onFrontmostApp = { [weak self] name, icon in self?.state.setFrontmostApp(name, icon: icon) }
        appSwitch.onSwitch = { [weak self] name, icon in self?.state.notifyAppSwitched(name, icon: icon) }
        systemStats.onUpdate = { [weak self] stats in self?.state.updateSystemStats(stats) }
        battery.onUpdate = { [weak self] status in self?.state.updateBattery(status) }

        nowPlaying.start(); appSwitch.start()
        volume.start()
        if let level = volume.currentVolume() { state.refreshSystemVolume(level) }
        volume.onVolumeChanged = { [weak self] level in self?.state.showVolume(level) }
        brightness.onBrightnessChanged = { [weak self] level in self?.state.showBrightness(level) }
        microphone.onMuteChanged = { [weak self] muted in self?.state.showMicrophoneMuted(muted) }
        brightness.start()
        microphone.start()
        devReady.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "signal") }
        // Hookless finished peeks. Emits the same title/subtitle/sessionId as the
        // hooks, so DevReadyDedup collapses the pair when both are active.
        transcripts.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "transcript") }
        transcripts.start()
        cursorActivity.onDevReady = { [weak self] alert in self?.presentDevReady(alert, origin: "cursordb") }
        cursorActivity.start()
        agentSessions.onUpdate = { [weak self] sessions in
            self?.state.agentSessions = sessions
            self?.refreshCI(for: sessions)
        }
        agentSessions.start()
        devReady.start()

        // Secondary providers can warm up after the notch is on screen.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.calendar.start()
            self.airDrop.start()
            self.systemStats.start()
            self.battery.start()
        }

        state.$isExpanded
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self, let level = self.volume.currentVolume() else { return }
                self.state.refreshSystemVolume(level)
            }
            .store(in: &cancellables)
    }

    // MARK: - Display handling

    @objc private func displaysChanged() {
        rebuildForCurrentDisplays()
    }

    @objc private func testDevReadyFromSettings() {
        testDevReadyPing()
    }

    @objc private func testMultipleDevReadyFromSettings() {
        testMultipleDevReadyPings()
    }

    /// Shows the overlay only on a built-in notched display. On external-only /
    /// clamshell / no-notch arrangements, the window is hidden and disabled.
    private func rebuildForCurrentDisplays() {
        guard let geometry = NotchGeometry.current() else {
            // No notched display any more — clamshell, or the lid closed while
            // docked. Hiding the window is not enough: everything that decides
            // hover, click passthrough and browser-flank exclusion reads
            // `self.geometry`, so leaving the old screen behind means those keep
            // computing against a display that is gone, and the hot zones sit at
            // coordinates nothing can reach.
            self.geometry = nil
            collapsedHotZone = .zero
            expandedHotZone = .zero
            menuBarStrip = .zero
            pillEngaged = false
            state.setExpanded(false)
            window?.orderOut(nil)
            return
        }

        self.geometry = geometry

        metrics = NotchMetrics(notchWidth: geometry.notchRect.width,
                               notchHeight: geometry.notchRect.height,
                               designExpandedWidth: NotchGeometry.expandedWidth,
                               designExpandedHeight: NotchGeometry.expandedHeight,
                               scale: NotchGeometry.expandedScale
                                   * CGFloat(AppSettings.shared.notchScale),
                               topGap: NotchGeometry.contentTopGap,
                               userScale: CGFloat(AppSettings.shared.notchScale))

        let root = makeRootView()

        if window == nil {
            let initialFrame = geometry.windowFrame(
                expanded: state.isExpanded,
                collapsedContentSize: collapsedContentSize(),
                expandedContentSize: expandedContentSize()
            )
            let win = NotchWindow(contentRect: initialFrame)
            let container = NotchContainerView(metrics: metrics)
            // `rendersLargeContent`, not `isExpanded`. A peek never sets
            // `isExpanded`, so this fed `false` into the hit test while a peek
            // was on screen — the rule then measured against the *collapsed*
            // rect, decided the ✕ was outside the pill, and returned nil, so
            // the click went to whatever was behind it. This is the layer that
            // actually decides; the passthrough flag and `acceptsFirstMouse`
            // are both upstream of it and could not save a click it rejected.
            container.isExpandedProvider = { [weak self] in self?.rendersLargeContent ?? false }
            container.collapsedContentSizeProvider = { [weak self] in self?.collapsedContentSize() ?? .zero }
            container.expandedContentSizeProvider = { [weak self] in self?.expandedContentSize() ?? .zero }
            container.onSpacePressed = { [weak self] in self?.nowPlaying.togglePlayPause() }
            container.onPillEngaged = { [weak self] in self?.engagePill() }
            container.onDropFiles = { [weak self] urls in self?.shelf.add(urls: urls) }
            container.onDragTargetingChanged = { [weak self] targeting in
                guard let self else { return }
                self.shelf.isDropTargeted = targeting
                // Keep the pill open while a drag hovers; collapse (with grace)
                // when it leaves, mirroring hover behavior.
                targeting ? self.pointerEnteredHot() : self.pointerExitedHot()
            }

            let hosting = PassthroughHostingView(rootView: root)
            hosting.acceptsScreenPoint = { [weak self] point in
                self?.container?.isPointOnInteractivePill(point) ?? false
            }
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            win.contentView = container
            self.window = win
            self.container = container
        } else {
            container?.metrics = metrics
            container?.collapsedContentSizeProvider = { [weak self] in self?.collapsedContentSize() ?? .zero }
            container?.expandedContentSizeProvider = { [weak self] in self?.expandedContentSize() ?? .zero }
            if let hosting = container?.subviews.first as? PassthroughHostingView<NotchRootView> {
                hosting.rootView = root
                hosting.acceptsScreenPoint = { [weak container] point in
                    container?.isPointOnInteractivePill(point) ?? false
                }
            }
        }

        applyWindowFrame(animated: false)
        window?.orderFrontRegardless()
        container?.refreshTracking()
        updateMousePassthrough(pointerInHotZone: expandHoverScreenRect().contains(NSEvent.mouseLocation))

        // Screenshot/inspection aid: start expanded so the pill is visible.
        if Diagnostics.forceExpand { state.setExpanded(true) }
        Diagnostics.seedShelfIfRequested(shelf)
    }

    private func collapsedContentSize() -> CGSize {
        let chips = NotchContentSnapshot.collapsedChips(
            state: state, shelf: shelf, timer: TimerStore.shared, settings: AppSettings.shared
        )
        if chips.isEmpty { return metrics.collapsedSize }
        return NotchContentLayout.collapsedSize(metrics: metrics, chips: chips)
    }

    private func expandedContentSize() -> CGSize {
        if state.updateProgress != nil { return NotchContentLayout.updateLayout(metrics: metrics).size }
        if let compose = state.replyCompose {
            return NotchContentLayout.replyComposeLayout(
                metrics: metrics,
                hasQuestion: compose.contextText != nil
            ).size
        }
        if !state.devReadyAlerts.isEmpty { return devReadyContentSize() }
        let activities = NotchContentSnapshot.expandedActivities(
            state: state, shelf: shelf, timer: TimerStore.shared, settings: AppSettings.shared
        )
        return NotchContentLayout.expandedSize(metrics: metrics, activities: activities)
    }

    private func devReadyContentSize() -> CGSize {
        guard !state.devReadyAlerts.isEmpty else {
            return CGSize(width: metrics.notchWidth + 96, height: metrics.notchHeight + metrics.topGap + 54)
        }
        if state.devReadyAlerts.contains(where: { $0.kind == .waiting }) {
            return NotchContentLayout.waitingLayout(metrics: metrics, alerts: state.devReadyAlerts).size
        }
        return NotchContentLayout.devReadyLayout(metrics: metrics, alerts: state.devReadyAlerts).size
    }

    private func applyWindowFrame(animated: Bool) {
        guard let geometry, let window else { return }
        // `replyCompose` must be here: the SwiftUI tree and `contentLayout` both
        // size for the composer, so omitting it hands them a collapsed window and
        // clips the composer to nothing. Reachable whenever a late send error
        // reopens the composer after the pill has already collapsed.
        let expanded = state.isExpanded || !state.devReadyAlerts.isEmpty
            || state.updateProgress != nil || state.replyCompose != nil
        let frame = geometry.windowFrame(
            expanded: expanded,
            collapsedContentSize: collapsedContentSize(),
            expandedContentSize: expandedContentSize()
        )
        updateHotZones(geometry: geometry, windowFrame: frame)
        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
        updateMousePassthrough(pointerInHotZone: expandHoverScreenRect().contains(NSEvent.mouseLocation))
    }

    // MARK: - Hover logic

    private static let logHover = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    private func handleHoverTick() {
        let mouse = NSEvent.mouseLocation
        let overPill = isPointerOverPill(mouse)

        if isPointerInBrowserFlank(mouse), !overPill, !state.isExpanded, !pillEngaged {
            expandWorkItem?.cancel()
            expandWorkItem = nil
            arming.disarm()
            hotZoneKeys.updatePointerInHotZone(false)
            updateMousePassthrough(pointerInHotZone: false)
            return
        }

        // Clicks follow geometry — someone can click the pill without wiggling
        // the mouse first. Keys follow the movement latch, so a peek that grew
        // under a parked cursor can't eat the Space of whoever is typing.
        let inZone = shouldArmShortcuts(at: mouse)
        hotZoneKeys.updatePointerInHotZone(arming.update(point: mouse, inZone: inZone))
        updateMousePassthrough(pointerInHotZone: inZone)
    }

    private func engagePill() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        expandWorkItem?.cancel()
        expandWorkItem = nil
        pillEngaged = true
        state.setExpanded(true)
        hotZoneKeys.updatePointerInHotZone(true)
        hotZoneKeys.ensureShortcutCaptureReady()
        applyWindowFrame(animated: true)
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    /// True whenever the pill is drawn at its larger size — hovered, engaged,
    /// or showing something that took over the window on its own.
    ///
    /// A peek is the case that mattered: it never sets `isExpanded`, so click
    /// targeting fell back to the *collapsed* rect while a 380pt-wide peek was
    /// on screen. Its ✕ sits past the right edge of that rect, so the window
    /// declared itself click-through and the press went to whatever was
    /// underneath. Intermittent, because the container's own tracking rects
    /// covered it whenever they had been refreshed in time.
    var rendersLargeContent: Bool {
        state.isExpanded
            || pillEngaged
            || !state.devReadyAlerts.isEmpty
            || state.replyCompose != nil
            || state.updateProgress != nil
    }

    private func isPointerOverPill(_ point: NSPoint) -> Bool {
        if container?.isPointOnInteractivePill(point) == true { return true }
        guard geometry != nil else { return false }
        let large = rendersLargeContent
        let pad: CGFloat = large ? 16 : 10
        let rect = large ? expandedInteractionRect() : collapsedInteractionRect()
        return rect.insetBy(dx: -pad, dy: -pad).contains(point)
    }

    /// Live answer for the key tap: geometry *and* the movement latch. Called
    /// on the main thread, both from the hover tick and synchronously from the
    /// event tap at key-press time.
    @discardableResult
    private func refreshShortcutArming(at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        arming.update(point: point, inZone: shouldArmShortcuts(at: point))
    }

    private func shouldArmShortcuts(at point: NSPoint = NSEvent.mouseLocation) -> Bool {
        if state.isExpanded {
            if pillEngaged { return true }
            return isPointerOverPill(point)
        }
        if isPointerInBrowserFlank(point) { return false }
        return collapsedInteractionRect().insetBy(dx: -12, dy: -10).contains(point)
            || geometry?.notchRect.insetBy(dx: -10, dy: -8).contains(point) == true
    }

    private func isPointerInBrowserFlank(_ point: NSPoint) -> Bool {
        guard let screen = geometry?.screen else { return false }
        return NotchGeometry.pointIsInBrowserFlank(point, on: screen)
    }

    private func pointerEnteredHot() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        expandWorkItem?.cancel()
        hotZoneKeys.updatePointerInHotZone(true)
        hotZoneKeys.ensureShortcutCaptureReady()
        if Self.logHover { print("HOVER enter -> expand in \(hoverExpandDelay)s") }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            guard !self.isPointerInBrowserFlank(mouse) else { return }
            guard self.expandHoverScreenRect().insetBy(dx: -6, dy: -4).contains(mouse) else {
                return
            }
            self.activateExpandedHotZone()
        }
        expandWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverExpandDelay, execute: item)
    }

    private func activateExpandedHotZone() {
        expandWorkItem = nil
        guard !isPointerInBrowserFlank(NSEvent.mouseLocation) else { return }
        if Self.logHover { print("HOVER expand @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
        state.setExpanded(true)
        hotZoneKeys.updatePointerInHotZone(true)
        hotZoneKeys.ensureShortcutCaptureReady()
        applyWindowFrame(animated: true)
        window?.orderFrontRegardless()
    }

    private func pointerExitedHot() {
        let mouse = NSEvent.mouseLocation
        if isPointerOverPill(mouse) {
            return
        }
        if pillEngaged, expandedInteractionRect().insetBy(dx: -14, dy: -12).contains(mouse) {
            return
        }
        // Leaving is judged more tightly than arriving. The entry zone is
        // padded, and that padding *grows* as the pill shrinks (a smaller pill
        // needs a relatively bigger target) — so at 75% the old exit test held
        // the pill open for roughly 27pt past its own edge, which reads as the
        // notch refusing to go away. Proper hysteresis keeps the generous zone
        // for arriving and uses the pill itself, already padded by
        // `isPointerOverPill`, for leaving.
        if expandHoverScreenRect().contains(mouse) {
            return
        }
        if isPointerInBrowserFlank(mouse) {
            expandWorkItem?.cancel()
            expandWorkItem = nil
            return
        }

        expandWorkItem?.cancel()
        expandWorkItem = nil
        collapseWorkItem?.cancel()
        // Genuinely left the pill: the next Space belongs to whatever the
        // person is actually typing in.
        arming.disarm()
        if Self.logHover { print("HOVER exit -> collapse in \(collapseGrace)s") }
        // 0.35 was tuned to stop the pill flickering shut on a mouse crossing
        // it, but the exit test is tighter now, so the grace no longer has to
        // carry that on its own — and a third of a second after you have
        // already looked away is long enough to notice.
        let grace = state.isExpanded ? 0.18 : collapseGrace
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let mouse = NSEvent.mouseLocation
            if self.isPointerOverPill(mouse) {
                return
            }
            if self.pillEngaged,
               self.expandedInteractionRect().insetBy(dx: -14, dy: -12).contains(mouse) {
                return
            }
            if self.isPointerInBrowserFlank(mouse) {
                return
            }
            if Self.logHover { print("HOVER collapse fired @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
            self.pillEngaged = false
            self.state.setExpanded(false)
            self.applyWindowFrame(animated: true)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + grace, execute: item)
    }

    /// Hover target — wider while expanded so clicks and shortcuts stay active.
    ///
    /// The padding is divided by the user's size setting. It used to be a flat
    /// 14/10pt at every size, which meant shrinking the pill shrank the target
    /// *and* left the same absolute slack — so the forgiveness you actually feel
    /// got smaller twice over, and the pointer slipped out while reaching for a
    /// control. Dividing keeps the margin constant relative to the pill.
    private func expandHoverScreenRect() -> CGRect {
        guard let geometry else { return .zero }

        let pad = Self.hoverPadding(forUserScale: metrics.userScale)

        if state.isExpanded || pillEngaged {
            return expandedInteractionRect().insetBy(dx: -pad.x, dy: -pad.y)
        }

        let notch = geometry.notchRect.insetBy(dx: -pad.collapsedX, dy: -pad.collapsedY)
        let pillSize = collapsedContentSize()
        let belowHeight = max(0, pillSize.height - geometry.notchRect.height)
        guard belowHeight > 0 else { return notch }

        let belowBody = CGRect(
            x: geometry.notchRect.midX - pillSize.width / 2,
            y: geometry.screen.frame.maxY - pillSize.height,
            width: pillSize.width,
            height: belowHeight
        )
        return notch.union(belowBody)
    }

    /// Hover slack for a given size. Never *less* than the original padding —
    /// enlarging the pill should not make it fussier to hover than it was.
    nonisolated static func hoverPadding(forUserScale scale: CGFloat)
        -> (x: CGFloat, y: CGFloat, collapsedX: CGFloat, collapsedY: CGFloat) {
        let s = min(1, max(0.5, scale))     // guard a corrupt or huge setting
        return (14 / s, 10 / s, 10 / s, 6 / s)
    }

    private func collapsedInteractionRect() -> CGRect {
        guard let geometry else { return .zero }
        let size = collapsedContentSize()
        let width = max(size.width, geometry.notchRect.width + 48)
        let height = max(size.height, geometry.notchRect.height + 60)
        return CGRect(
            x: geometry.notchRect.midX - width / 2,
            y: geometry.screen.frame.maxY - height,
            width: width,
            height: height
        )
    }

    private func expandedInteractionRect() -> CGRect {
        guard let geometry else { return .zero }
        let size = expandedContentSize()
        return CGRect(
            x: geometry.notchRect.midX - size.width / 2,
            y: geometry.screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    private func updateHotZones(geometry: NotchGeometry, windowFrame: CGRect) {
        menuBarStrip = NotchGeometry.menuBarStrip(for: geometry.screen)
        collapsedHotZone = collapsedInteractionRect()
        expandedHotZone = expandedInteractionRect()

        if Self.logHover {
            print("HOTZONE collapsed=\(collapsedHotZone) expanded=\(expandedHotZone) menuBar=\(menuBarStrip)")
        }
    }

    /// Collapsed: pass all clicks through to apps below (Brave tabs, etc.).
    /// Expanded: capture clicks only over the pill body — never over browser tab flanks.
    private func updateMousePassthrough(pointerInHotZone: Bool) {
        guard let window, let container, let geometry else {
            return
        }

        let mouse = NSEvent.mouseLocation

        // Browser tab flanks — pass through unless clicking the pill itself.
        //
        // "Itself" has to include a peek. A peek is far wider than the notch,
        // so its right-hand controls — the ✕ and the reply button — sit out in
        // the flank, and asking only the container's tracking rects (which a
        // just-arrived peek may not be in yet) declared them click-through.
        // That is the whole of "the ✕ doesn't work sometimes".
        if NotchGeometry.pointIsInBrowserFlank(mouse, on: geometry.screen),
           container.isPointOnInteractivePill(mouse) == false,
           !isPointerOverPill(mouse) {
            window.ignoresMouseEvents = true
            return
        }

        // Menu bar strip always passes through (clock, Wi‑Fi, NotchPill icon, etc.).
        if menuBarStrip.contains(mouse), !isPointerOverPill(mouse) {
            window.ignoresMouseEvents = true
            return
        }

        if !rendersLargeContent {
            let overPill = isPointerOverPill(mouse)
            window.ignoresMouseEvents = !overPill
            return
        }

        // Same rule as `isPointerOverPill`: the container's tracking rects are
        // authoritative when they are current, but a peek that has just
        // appeared may not be in them yet, and a click-through ✕ is the result.
        let overPill = container.isPointOnInteractivePill(mouse) || isPointerOverPill(mouse)
        window.ignoresMouseEvents = !overPill
    }

    // MARK: - Dev ready pings

    /// Bring forward whatever app a session is running in.
    ///
    /// Cursor carries its own bundle id; a terminal agent has none on disk, so
    /// the process tree is walked instead — see `AgentSessionLocator`. Collapse
    /// the pill either way: leaving it hovering over the window you just asked
    /// to see defeats the purpose.
    private func focusAgentSession(_ session: AgentSession) {
        let fallback = session.knownAgent == .cursor ? "com.todesktop.230313mzl4w4u92" : nil
        AgentSessionLocator.focus(sessionId: session.locatorId ?? session.id,
                                  fallbackBundleId: fallback)
        pillEngaged = false
        state.setExpanded(false)
    }

    /// The repos to watch come from wherever agents are working, so the card
    /// follows you rather than needing configuration.
    private func refreshCI(for sessions: [AgentSession]) {
        guard AppSettings.shared.showExpandedCI else {
            if !state.ciRuns.isEmpty { state.ciRuns = [] }
            return
        }
        // Deliberately called even with no directories: the provider remembers
        // repos for an hour, so CI outlives the session that introduced it.
        let dirs = sessions.compactMap(\.directory)
        Task { [weak self] in
            guard let self else { return }
            // Filter again on the way out. The provider only ages runs when it
            // fetches, once every 45s, and a two-minute lifetime cannot afford
            // to overshoot by most of a poll interval.
            let runs = CIRun.current(await ciStatus.runs(forDirectories: dirs))
            await MainActor.run {
                if runs.count != self.state.ciRuns.count {
                    LogStore.log("ci", "\(runs.count) run(s) from \(dirs.count) agent director"
                        + (dirs.count == 1 ? "y" : "ies"))
                }
                self.state.ciRuns = runs
            }
        }
    }

    private func presentDevReady(_ alert: DevReadyAlert, origin: String = "?") {
        guard AppSettings.shared.showDevReadyPings else {
            LogStore.log("peek", "suppressed (peeks are switched off) from=\(origin)", level: .warn)
            return
        }
        Self.logPeek(alert, origin: origin)
        // Branding, not content: which agent it claims to be and whether we
        // recognised it is what every mislabelled-peek report has turned on.
        LogStore.log("peek", "\(alert.kind) from=\(origin) agent=\(alert.agent ?? "-") "
            + "shows=\(alert.knownAgent.map(String.init(describing:)) ?? "unknown") "
            + "session=\(alert.sessionId?.prefix(8) ?? "-")")
        // A pending prompt is never written to a transcript, so the sessions
        // list cannot see "waiting" on its own for the terminal agents. The
        // peek is the only carrier of that fact.
        agentSessions.noteWaiting(sessionId: alert.sessionId, waiting: alert.kind == .waiting)

        // Waiting alerts have their own lifecycle and must not touch the finished
        // path: the finished fingerprint is `title|subtitle`, which for waiting
        // alerts is project|branch — identical for every question from the same
        // session, so the dedup window would silently drop the second question and
        // leave the agent hanging. They also must not be batched into the
        // auto-dismiss timer (a blocked agent stays blocked past 13s) and must not
        // become `lastFinishedAlert`.
        if alert.kind == .waiting {
            state.enqueueWaiting(alert)   // replace-per-session, no fingerprint dedup
            engagePill()
            if AppSettings.shared.devReadyPlaySound {
                NSSound(named: "Glass")?.play()
            }
            applyWindowFrame(animated: true)
            return
        }

        if devReadyDedup.shouldSuppress(alert) { return }

        lastFinishedAlert = alert
        pendingDevReadyAlerts.append(alert)
        devReadyCoalesceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushDevReadyBatch() }
        devReadyCoalesceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func flushDevReadyBatch() {
        devReadyCoalesceItem = nil
        guard !pendingDevReadyAlerts.isEmpty else { return }
        let batch = pendingDevReadyAlerts
        pendingDevReadyAlerts = []
        state.enqueueDevReady(batch)
        engagePill()
        if AppSettings.shared.devReadyPlaySound {
            NSSound(named: "Glass")?.play()
        }
        scheduleDevReadyDismiss()
    }

    private func scheduleDevReadyDismiss() {
        devReadyDismissItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismissDevReady() }
        devReadyDismissItem = item
        let delay = AppSettings.shared.devReadyDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Auto-dismiss / explicit dismiss. Only `.finished` peeks are swept: a
    /// `.waiting` peek represents a still-blocked agent and clears only when it is
    /// answered, superseded, or removed as stale. With no waiting alerts present
    /// this is byte-for-byte the v1.3.0 finished behaviour.
    private func dismissDevReady(id: String? = nil) {
        // "The ✕ doesn't work sometimes" was invisible from outside: a
        // click-through press and a press that landed both end with the peek
        // gone, one on its own timer. This says which happened.
        LogStore.log("peek", id == nil ? "dismissed (fade timer)" : "dismissed (single)")
        if let id {
            state.removeDevReady(id: id)
            if !state.devReadyAlerts.isEmpty {
                if state.devReadyAlerts.contains(where: { $0.kind == .finished }) {
                    scheduleDevReadyDismiss()
                } else {
                    // Waiting-only remainder: never re-arm the fade timer.
                    devReadyDismissItem?.cancel()
                    devReadyDismissItem = nil
                }
                applyWindowFrame(animated: true)
                return
            }
        }

        guard !state.devReadyAlerts.isEmpty else { return }
        devReadyDismissItem?.cancel()
        devReadyDismissItem = nil
        state.clearFinishedDevReady()

        guard state.devReadyAlerts.isEmpty else {
            // Waiting peeks survive; keep the pill open and just resize.
            applyWindowFrame(animated: true)
            return
        }

        let mouse = NSEvent.mouseLocation
        if isPointerOverPill(mouse) || expandHoverScreenRect().insetBy(dx: -8, dy: -6).contains(mouse) {
            applyWindowFrame(animated: true)
            return
        }

        pillEngaged = false
        state.setExpanded(false)
        applyWindowFrame(animated: true)
    }

    /// Explicit dismissal of one peek (its ✕). Unlike tapping the row this does
    /// not focus the terminal, and unlike the fade timer it will clear a
    /// `.waiting` peek — which otherwise has no way to go away.
    private func dismissPeek(id: String) {
        LogStore.log("peek", "dismissed by ✕")
        state.removeDevReady(id: id)
        guard state.devReadyAlerts.isEmpty else {
            if !state.devReadyAlerts.contains(where: { $0.kind == .finished }) {
                devReadyDismissItem?.cancel()
                devReadyDismissItem = nil
            }
            applyWindowFrame(animated: true)
            return
        }
        collapseAfterDevReady()
    }

    /// Explicit user dismissal of everything — Escape. Clears **every** peek
    /// including `.waiting`, which the auto-dismiss path deliberately spares.
    private func dismissAllDevReady() {
        guard !state.devReadyAlerts.isEmpty else { return }
        state.clearAllDevReady()
        collapseAfterDevReady()
    }

    /// Cancels the fade timer and collapses the pill, unless the pointer is still
    /// on it (in which case hover keeps it open and we only resize).
    private func collapseAfterDevReady() {
        devReadyDismissItem?.cancel()
        devReadyDismissItem = nil

        let mouse = NSEvent.mouseLocation
        if isPointerOverPill(mouse) || expandHoverScreenRect().insetBy(dx: -8, dy: -6).contains(mouse) {
            applyWindowFrame(animated: true)
            return
        }
        pillEngaged = false
        state.setExpanded(false)
        applyWindowFrame(animated: true)
    }

    /// Escape-to-dismiss, live **only** while a peek is actually on a rendered
    /// notch — the monitors are torn down the moment the last peek clears, so
    /// this is never a standing system-wide key watcher.
    /// Runs a slow sweep while any `.waiting` peek is up, so one that outlives its
    /// question loses its answer buttons instead of offering to type into a
    /// terminal that has moved on. Stops as soon as no waiting peek remains.
    private func syncWaitingStaleTimer() {
        let wantsTimer = state.devReadyAlerts.contains { $0.kind == .waiting }
        guard wantsTimer != (waitingStaleTimer != nil) else { return }

        guard wantsTimer else {
            waitingStaleTimer?.invalidate()
            waitingStaleTimer = nil
            return
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.demoteStaleWaiting()
                self.syncWaitingStaleTimer()
            }
        }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        waitingStaleTimer = timer
    }

    private func syncPeekEscapeMonitors() {
        // `window == nil` on an external-only/clamshell setup: the peek is
        // enqueued but never rendered and never fades, so without this the
        // monitors would stay installed forever with nothing to dismiss.
        let wantsMonitors = !state.devReadyAlerts.isEmpty && window != nil
        guard wantsMonitors != !peekEscapeMonitors.isEmpty else { return }

        guard wantsMonitors else {
            peekEscapeMonitors.forEach(NSEvent.removeMonitor)
            peekEscapeMonitors = []
            return
        }
        // Escape belongs to the composer whenever one is open (it cancels the
        // reply); only take it for the peek when no composer has it.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            guard let self, self.state.replyCompose == nil else { return }
            // Escape in *another* app is that app's key, not ours — and in Claude
            // Code's own permission prompt it means "reject". Swallowing every
            // peek because the user rejected a prompt in the terminal would
            // destroy other sessions' still-blocked questions, which nothing else
            // records. So require the pointer near the notch — but use the same
            // generous zone hover-collapse uses, not the bare pill rect: aiming
            // at a 200pt strip before hitting Escape is not a real affordance.
            let mouse = NSEvent.mouseLocation
            guard self.isPointerOverPill(mouse)
                    || self.expandHoverScreenRect().insetBy(dx: -8, dy: -6).contains(mouse)
            else { return }
            self.dismissAllDevReady()
        }) {
            peekEscapeMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53, let self,
                  self.state.replyCompose == nil,
                  !self.state.devReadyAlerts.isEmpty else { return event }
            // Local monitors are app-wide, not window-scoped: without this,
            // Escape in the Preferences window (or a sheet it opens) would be
            // consumed here instead of closing it.
            guard event.window === self.window else { return event }
            self.dismissAllDevReady()
            return nil
        }) {
            peekEscapeMonitors.append(local)
        }
    }

    private func focusSourceApp(bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?
            .activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }

    /// Renders a `ReplyError` into the composer's error line. The two call sites
    /// pass their own copy — the reply wording is v1.3.0's verbatim and must not
    /// drift, so it isn't derived from a shared verb.
    private func showReplyError(_ err: ReplyError, alert: DevReadyAlert,
                                grantCopy: String, failCopy: String) {
        let terminal = alert.source ?? "Terminal"
        switch err {
        case .accessibilityDenied:
            state.setReplyError(grantCopy)
            AccessibilityAuthorization.requestSystemPrompt()
        case .targetNotRunning:
            state.setReplyError("\(terminal) isn't running")
        case .focusTimeout:
            state.setReplyError("Couldn't focus \(terminal) — nothing was sent")
        case .emptyText, .noTarget:
            state.setReplyError(failCopy)
        }
    }

    private func performReply(alert: DevReadyAlert, text: String) {
        let late: (ReplyError?) -> Void = { [weak self] err in
            guard let self, let err else { return }
            // The composer was closed optimistically on the synchronous accept —
            // reopen it with the draft restored so the failure is visible and
            // the user can retry rather than assume the reply landed.
            self.state.beginReply(to: alert)
            self.state.updateReplyDraft(text)
            self.showReplyError(err, alert: alert,
                                grantCopy: "Grant Accessibility to send replies",
                                failCopy: "Couldn't send reply")
        }
        if let err = TerminalReplyInjector.send(text: text, bundleId: alert.bundleId,
                                                completion: late) {
            showReplyError(err, alert: alert,
                           grantCopy: "Grant Accessibility to send replies",
                           failCopy: "Couldn't send reply")
            return
        }
        // Success: close composer and dismiss that agent's peek.
        state.cancelReply()
        dismissDevReady(id: alert.id)
    }

    private func performAnswer(alert: DevReadyAlert, answer: AgentAnswer) {
        TerminalReplyInjector.log("performAnswer tapped: \(answer.label) -> "
            + "\(answer.keystroke.debugDescription) for alert=\(alert.title) "
            + "kind=\(alert.kind) bundleId=\(alert.bundleId ?? "nil")")
        // A `PreToolUse` request is answered by handing the blocked hook a
        // verdict, not by typing at a terminal. No focus to steal, no
        // Accessibility grant needed, and it reaches agents that have no
        // terminal window to type into at all.
        if alert.answersByDecision, let requestId = alert.requestId {
            let verdict = PermissionDecision.Verdict(answer.keystroke)
            do {
                try PermissionDecision(requestId: requestId, verdict: verdict,
                                       reason: "\(answer.label) from NotchPill").write()
                LogStore.log("permission", "\(verdict.rawValue) \(requestId)")
            } catch {
                // The hook times out on its own and falls back to Claude's
                // prompt, so a failure here costs one ordinary prompt.
                LogStore.log("permission", "could not answer: \(error)", level: .warn)
            }
            dismissDevReady(id: alert.id)
            return
        }
        // A tapped answer has no open composer; open one so an error is visible
        // and the user can retry by typing. Mirrors performReply's error surface.
        let surface: (ReplyError) -> Void = { [weak self] err in
            guard let self else { return }
            self.state.beginReply(to: alert)
            self.showReplyError(err, alert: alert,
                                grantCopy: "Grant Accessibility to answer",
                                failCopy: "Couldn't send answer")
        }
        // Key events by default: a TUI permission prompt selects on keypress, and
        // a bracketed paste lands in its composer instead. An agent that wants
        // otherwise says so in the signal (`delivery=paste`).
        if let err = TerminalReplyInjector.send(text: answer.keystroke,
                                                bundleId: alert.bundleId,
                                                appendReturn: answer.appendsReturn,
                                                delivery: alert.answerDelivery,
                                                completion: { err in if let err { surface(err) } }) {
            surface(err)
            return
        }
        dismissDevReady(id: alert.id)   // dismiss the answered waiting peek
    }

    /// Sends plan feedback over the same file-backed verdict channel as Allow.
    /// A plan is not terminal input: Claude's hook is still waiting, so this
    /// reaches the precise process even if no terminal app is open.
    private func performPlanRevision(alert: DevReadyAlert, feedback: String) {
        guard alert.permissionRequest?.isPlan == true, let requestId = alert.requestId else {
            state.setReplyError("This plan is no longer waiting")
            return
        }
        guard let reason = PermissionDecision.planRevisionReason(feedback) else {
            state.setReplyError("Add what you want changed")
            return
        }
        do {
            try PermissionDecision(requestId: requestId, verdict: .deny, reason: reason).write()
            LogStore.log("permission", "plan revision " + requestId)
            state.cancelReply()
            dismissDevReady(id: alert.id)
        } catch {
            // The hook's timeout falls back to Claude's normal prompt, which is
            // safer than claiming the feedback reached a process that never got it.
            LogStore.log("permission", "could not revise plan: \(error)", level: .warn)
            state.setReplyError("Couldn't send revision")
        }
    }

    /// Appends one line per peek to `~/.notchpill/peeks.log`.
    ///
    /// Mislabelled peeks ("Cursor finished" arriving as Claude Code) are the
    /// hardest thing to chase here, because by the time you notice one the
    /// evidence is a rectangle that already faded. Reading the hook scripts is
    /// not enough — the label can come from a queued payload written minutes
    /// earlier, or from a hook the app never installed. So every peek records
    /// the fields that decide its branding, and the log is capped so it can be
    /// left on permanently.
    private static let peekLogging = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_PEEKS"] == "1"

    private static func logPeek(_ alert: DevReadyAlert, origin: String) {
        // Off by default: these lines carry project names and the text of
        // whatever an agent asked, which is not something to write to disk on
        // every machine. Turn it on only while chasing a peek.
        guard peekLogging else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchpill")
        let url = dir.appendingPathComponent("peeks.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) from=\(origin) kind=\(alert.kind) agent=\(alert.agent ?? "-") "
            + "source=\(alert.source ?? "-") bundle=\(alert.bundleId ?? "-") "
            + "shows=\(alert.knownAgent.map(String.init(describing:)) ?? "unknown") "
            + "title=\(alert.title.prefix(60).replacingOccurrences(of: "\n", with: " ")) "
            + "subtitle=\((alert.subtitle ?? "-").prefix(60).replacingOccurrences(of: "\n", with: " ")) "
            + "session=\(alert.sessionId ?? "-")\n"
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            // Keep the tail, not the head — a runaway log would otherwise fill
            // the disk of anyone who installs this and forgets about it.
            if (try? handle.seekToEnd()) ?? 0 > 512_000 {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                try? data.write(to: url)
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Short suppression window for repeated "finished" pings, keyed on
/// `title|subtitle|sessionId`. Extracted from `NotchController` so the routing
/// rule is unit-testable without an NSWindow.
///
/// The session id is part of the key because `title|subtitle` is project|branch:
/// two agent sessions working the same branch produce byte-identical
/// fingerprints, so one finishing would suppress the other's ping — and a
/// suppressed ping never reaches `enqueueDevReady` to retire that session's
/// waiting peek, leaving live answer buttons on a question that is already
/// answered.
///
/// `.waiting` alerts are deliberately exempt entirely. Their fingerprint is
/// identical for *every* question a session asks — a second permission prompt 5s
/// after the first would be dropped and the agent would hang with nothing on
/// screen.
struct DevReadyDedup {
    var interval: TimeInterval = 12
    private var recent: [(String, Date)] = []

    /// How close together two peeks from the *same host app* must be to count as
    /// one turn. Short: this only has to span a hook and the process it wrapped,
    /// which is well under a second in practice.
    var hostWindow: TimeInterval = 5
    private var recentHosts: [((host: String, agent: String), Date)] = []

    mutating func shouldSuppress(_ alert: DevReadyAlert, now: Date = Date()) -> Bool {
        guard alert.kind == .finished else { return false }
        let fingerprint = "\(alert.title)|\(alert.subtitle ?? "")|\(alert.sessionId ?? "")"
        recent.removeAll { now.timeIntervalSince($0.1) > interval }
        if recent.contains(where: { $0.0 == fingerprint }) { return true }
        recent.append((fingerprint, now))

        // One turn in one app is one peek, even when two agents report it.
        //
        // Cursor can run Claude Code as its backend, reusing its own composer id
        // as the Claude session id. Both report honestly and neither is wrong:
        // Cursor's hook peeks as Cursor, and the `claude` process it spawned
        // fires its own Stop hook, which correctly names Cursor as the host app.
        // The result was two peeks a second apart for one turn, reading as a
        // Claude session the user never started. Their titles differ ("Question
        // for you" vs the project), so only the host app relates them.
        //
        // The first peek wins because it is the more specific one — the actual
        // question beats a generic "finished".
        //
        // Only a *different* agent collapses. Two Claude Code sessions in one
        // terminal finishing together are two real turns, and suppressing one
        // would undo the whole point of keying peeks on the session id.
        guard let host = alert.bundleId, !host.isEmpty else { return false }
        let agent = (alert.agent ?? alert.source ?? "").lowercased()
        recentHosts.removeAll { now.timeIntervalSince($0.1) > hostWindow }
        if recentHosts.contains(where: { $0.0.host == host && $0.0.agent != agent }) { return true }
        recentHosts.append(((host, agent), now))
        return false
    }
}
