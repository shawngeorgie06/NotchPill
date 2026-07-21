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
    /// Delay before expanding so quick mouse moves (e.g. to browser tabs) don't trigger it.
    private let hoverExpandDelay: TimeInterval = 0.03

    private var cancellables = Set<AnyCancellable>()

    func start() {
        hotZoneKeys.onTogglePlayPause = { [weak self] in self?.nowPlaying.togglePlayPause() }
        hotZoneKeys.onNext = { [weak self] in self?.nowPlaying.next() }
        hotZoneKeys.onPrevious = { [weak self] in self?.nowPlaying.previous() }
        hotZoneKeys.onVolumeUp = { [weak self] in self?.volume.volumeUp() }
        hotZoneKeys.onVolumeDown = { [weak self] in self?.volume.volumeDown() }
        hotZoneKeys.pointerInHotZone = { [weak self] in
            self?.isPointerInShortcutZone() ?? false
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
        hoverMonitor.onTick = { [weak self] inside in
            self?.hotZoneKeys.updatePointerInHotZone(inside)
            self?.updateMousePassthrough(pointerInHotZone: inside)
        }
        hoverMonitor.hotZoneScreenRect = { [weak self] in self?.hotZoneScreenRect() ?? .zero }
        hoverMonitor.start()

        rebuildForCurrentDisplays()
        wireProviders()

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

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
            TimerStore.shared.objectWillChange.map { _ in () }.eraseToAnyPublisher()
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

    private func makeRootView() -> NotchRootView {
        let actions = NotchActions(
            togglePlayPause: { [weak self] in self?.nowPlaying.togglePlayPause() },
            next: { [weak self] in self?.nowPlaying.next() },
            previous: { [weak self] in self?.nowPlaying.previous() })
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
        systemStats.stop(); battery.stop()
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
            container.onSpacePressed = { [weak self] in self?.nowPlaying.togglePlayPause() }
            container.onDropFiles = { [weak self] urls in self?.shelf.add(urls: urls) }
            container.onDragTargetingChanged = { [weak self] targeting in
                guard let self else { return }
                self.shelf.isDropTargeted = targeting
                // Keep the pill open while a drag hovers; collapse (with grace)
                // when it leaves, mirroring hover behavior.
                targeting ? self.pointerEnteredHot() : self.pointerExitedHot()
            }

            let hosting = NSHostingView(rootView: root)
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
            if let hosting = container?.subviews.first as? NSHostingView<NotchRootView> {
                hosting.rootView = root
            }
        }

        applyWindowFrame(animated: false)
        window?.orderFrontRegardless()
        container?.refreshTracking()

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
        let activities = NotchContentSnapshot.expandedActivities(
            state: state, shelf: shelf, timer: TimerStore.shared, settings: AppSettings.shared
        )
        return NotchContentLayout.expandedSize(metrics: metrics, activities: activities)
    }

    private func applyWindowFrame(animated: Bool) {
        guard let geometry, let window else { return }
        let frame = geometry.windowFrame(
            expanded: state.isExpanded,
            collapsedContentSize: collapsedContentSize(),
            expandedContentSize: expandedContentSize()
        )
        updateHotZones(geometry: geometry, windowFrame: frame)
        if animated {
            window.animator().setFrame(frame, display: true)
        } else {
            window.setFrame(frame, display: true)
        }
        updateMousePassthrough(pointerInHotZone: hotZoneScreenRect().contains(NSEvent.mouseLocation))
    }

    // MARK: - Hover logic

    private static let logHover = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    private func pointerEnteredHot() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        expandWorkItem?.cancel()
        hotZoneKeys.updatePointerInHotZone(true)
        hotZoneKeys.ensureShortcutCaptureReady()
        if Self.logHover { print("HOVER enter -> expand in \(hoverExpandDelay)s") }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Only expand if the pointer is still over the interaction target.
            guard self.hotZoneScreenRect().insetBy(dx: -10, dy: -6).contains(NSEvent.mouseLocation) else {
                return
            }
            self.activateExpandedHotZone()
        }
        expandWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hoverExpandDelay, execute: item)
    }

    private func activateExpandedHotZone() {
        expandWorkItem = nil
        if Self.logHover { print("HOVER expand @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
        state.setExpanded(true)
        hotZoneKeys.updatePointerInHotZone(true)
        hotZoneKeys.ensureShortcutCaptureReady()
        applyWindowFrame(animated: true)
        window?.orderFrontRegardless()
    }

    private func pointerExitedHot() {
        // Ignore spurious exits while the pointer is still in the screen hot zone.
        if hotZoneScreenRect().insetBy(dx: -4, dy: -2).contains(NSEvent.mouseLocation) {
            return
        }

        expandWorkItem?.cancel()
        expandWorkItem = nil
        collapseWorkItem?.cancel()
        if Self.logHover { print("HOVER exit -> collapse in \(collapseGrace)s") }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.hotZoneScreenRect().insetBy(dx: -4, dy: -2).contains(NSEvent.mouseLocation) {
                return
            }
            if Self.logHover { print("HOVER collapse fired @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
            self.state.setExpanded(false)
            self.applyWindowFrame(animated: true)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseGrace, execute: item)
    }

    /// Hot zone in screen coordinates for the hover poller and shortcut arming.
    private func hotZoneScreenRect() -> CGRect {
        guard let geometry else { return .zero }

        let notch = geometry.notchRect
        let menuBarHeight = max(geometry.screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        // Band across the menu bar / physical notch — where the cursor sits before clicking.
        let notchBand = CGRect(
            x: notch.midX - max(notch.width + 96, 200) / 2,
            y: geometry.screen.frame.maxY - menuBarHeight - 20,
            width: max(notch.width + 96, 200),
            height: menuBarHeight + 36
        )

        let pill = collapsedInteractionRect().union(expandedInteractionRect())
        return notchBand.union(pill)
    }

    /// Live pointer test used by the global key monitor (no click required).
    private func isPointerInShortcutZone() -> Bool {
        let rect = hotZoneScreenRect()
        guard rect.width > 0, rect.height > 0 else { return false }
        return rect.insetBy(dx: -20, dy: -14).contains(NSEvent.mouseLocation)
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
    /// Expanded: capture clicks only over the pill for controls.
    private func updateMousePassthrough(pointerInHotZone: Bool) {
        let mouse = NSEvent.mouseLocation
        let overMenuBar = menuBarStrip.contains(mouse)
        if state.isExpanded {
            window?.ignoresMouseEvents = overMenuBar || !pointerInHotZone
        } else {
            window?.ignoresMouseEvents = true
        }
    }
}
