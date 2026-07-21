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
    private let calendar = CalendarProvider()
    private let airDrop = AirDropProvider()
    private let appSwitch = AppSwitchProvider()
    private let systemStats = SystemStatsProvider()
    private let battery = BatteryProvider()
    private let devReady = DevReadyProvider()

    // Hover.
    private var collapseWorkItem: DispatchWorkItem?
    private let collapseGrace: TimeInterval = 0.16
    private let hotZoneKeys = HotZoneKeyMonitor()
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
    private var recentDevReadyFingerprints: [(String, Date)] = []
    private let devReadyDedupInterval: TimeInterval = 12

    private var cancellables = Set<AnyCancellable>()

    func start() {
        hotZoneKeys.onTogglePlayPause = { [weak self] in self?.nowPlaying.togglePlayPause() }
        hotZoneKeys.onNext = { [weak self] in self?.nowPlaying.next() }
        hotZoneKeys.onPrevious = { [weak self] in self?.nowPlaying.previous() }
        hotZoneKeys.onVolumeUp = { [weak self] in self?.volume.volumeUp() }
        hotZoneKeys.onVolumeDown = { [weak self] in self?.volume.volumeDown() }
        hotZoneKeys.pointerInHotZone = { [weak self] in
            self?.shouldArmShortcuts() ?? false
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
            state.$devReadyAlerts.map { _ in () }.eraseToAnyPublisher()
        )
        .receive(on: RunLoop.main)
        .sink { [weak self] in
            // Defer so @Published settings and state are committed before relayout.
            DispatchQueue.main.async {
                self?.refreshOverlayContent(animated: true)
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
            dismissDevReady: { [weak self] id in self?.dismissDevReady(id: id) }
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
        systemStats.stop(); battery.stop(); devReady.stop()
        window?.orderOut(nil)
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
        devReady.onDevReady = { [weak self] alert in self?.presentDevReady(alert) }
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
            window?.orderOut(nil)
            return
        }

        self.geometry = geometry

        metrics = NotchMetrics(notchWidth: geometry.notchRect.width,
                               notchHeight: geometry.notchRect.height,
                               designExpandedWidth: NotchGeometry.expandedWidth,
                               designExpandedHeight: NotchGeometry.expandedHeight,
                               scale: NotchGeometry.expandedScale,
                               topGap: NotchGeometry.contentTopGap)

        let root = makeRootView()

        if window == nil {
            let initialFrame = geometry.windowFrame(
                expanded: state.isExpanded,
                collapsedContentSize: collapsedContentSize(),
                expandedContentSize: expandedContentSize()
            )
            let win = NotchWindow(contentRect: initialFrame)
            let container = NotchContainerView(metrics: metrics)
            container.isExpandedProvider = { [weak self] in self?.state.isExpanded ?? false }
            container.collapsedContentSizeProvider = { [weak self] in self?.collapsedContentSize() ?? .zero }
            container.expandedContentSizeProvider = { [weak self] in self?.expandedContentSize() ?? .zero }
            container.browserFlankContains = { [weak self] point in
                guard let screen = self?.geometry?.screen else { return false }
                return NotchGeometry.pointIsInBrowserFlank(point, on: screen)
            }
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
            container?.browserFlankContains = { [weak self] point in
                guard let screen = self?.geometry?.screen else { return false }
                return NotchGeometry.pointIsInBrowserFlank(point, on: screen)
            }
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
        return NotchContentLayout.devReadyLayout(metrics: metrics, alerts: state.devReadyAlerts).size
    }

    private func applyWindowFrame(animated: Bool) {
        guard let geometry, let window else { return }
        let expanded = state.isExpanded || !state.devReadyAlerts.isEmpty
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
            hotZoneKeys.updatePointerInHotZone(false)
            updateMousePassthrough(pointerInHotZone: false)
            return
        }

        let armShortcuts = shouldArmShortcuts(at: mouse)
        hotZoneKeys.updatePointerInHotZone(armShortcuts)
        updateMousePassthrough(pointerInHotZone: armShortcuts)
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

    private func isPointerOverPill(_ point: NSPoint) -> Bool {
        if container?.isPointOnInteractivePill(point) == true { return true }
        guard let geometry else { return false }
        let pad: CGFloat = state.isExpanded ? 16 : 10
        let rect = state.isExpanded ? expandedInteractionRect() : collapsedInteractionRect()
        return rect.insetBy(dx: -pad, dy: -pad).contains(point)
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
        if expandHoverScreenRect().insetBy(dx: -8, dy: -6).contains(mouse) {
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
        if Self.logHover { print("HOVER exit -> collapse in \(collapseGrace)s") }
        let grace = state.isExpanded ? 0.35 : collapseGrace
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
    private func expandHoverScreenRect() -> CGRect {
        guard let geometry else { return .zero }

        if state.isExpanded || pillEngaged {
            return expandedInteractionRect().insetBy(dx: -14, dy: -10)
        }

        let notch = geometry.notchRect.insetBy(dx: -10, dy: -6)
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
        if NotchGeometry.pointIsInBrowserFlank(mouse, on: geometry.screen),
           container.isPointOnInteractivePill(mouse) == false {
            window.ignoresMouseEvents = true
            return
        }

        // Menu bar strip always passes through (clock, Wi‑Fi, NotchPill icon, etc.).
        if menuBarStrip.contains(mouse), !isPointerOverPill(mouse) {
            window.ignoresMouseEvents = true
            return
        }

        if !state.isExpanded {
            let overPill = isPointerOverPill(mouse)
            window.ignoresMouseEvents = !overPill
            return
        }

        let overPill = container.isPointOnInteractivePill(mouse)
        window.ignoresMouseEvents = !overPill
    }

    // MARK: - Dev ready pings

    private func presentDevReady(_ alert: DevReadyAlert) {
        guard AppSettings.shared.showDevReadyPings else { return }
        let fingerprint = "\(alert.title)|\(alert.subtitle ?? "")"
        let now = Date()
        recentDevReadyFingerprints.removeAll { now.timeIntervalSince($0.1) > devReadyDedupInterval }
        if recentDevReadyFingerprints.contains(where: { $0.0 == fingerprint }) { return }
        recentDevReadyFingerprints.append((fingerprint, now))

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
        scheduleDevReadyDismiss()
    }

    private func scheduleDevReadyDismiss() {
        devReadyDismissItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismissDevReady() }
        devReadyDismissItem = item
        let delay = AppSettings.shared.devReadyDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func dismissDevReady(id: String? = nil) {
        if let id {
            state.removeDevReady(id: id)
            if !state.devReadyAlerts.isEmpty {
                scheduleDevReadyDismiss()
                applyWindowFrame(animated: true)
                return
            }
        }

        guard !state.devReadyAlerts.isEmpty else { return }
        devReadyDismissItem?.cancel()
        devReadyDismissItem = nil
        state.clearDevReady()

        let mouse = NSEvent.mouseLocation
        if isPointerOverPill(mouse) || expandHoverScreenRect().insetBy(dx: -8, dy: -6).contains(mouse) {
            applyWindowFrame(animated: true)
            return
        }

        pillEngaged = false
        state.setExpanded(false)
        applyWindowFrame(animated: true)
    }

    private func focusSourceApp(bundleId: String) {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first?
            .activate(options: [.activateIgnoringOtherApps, .activateAllWindows])
    }
}
