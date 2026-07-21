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

    // Hover.
    private var collapseWorkItem: DispatchWorkItem?
    private let collapseGrace: TimeInterval = 0.5
    private let hotZoneKeys = HotZoneKeyMonitor()
    private let hoverMonitor = HoverMonitor()
    var keyMonitor: HotZoneKeyMonitor { hotZoneKeys }

    /// Screen-space hover targets derived from NotchGeometry (not view layout).
    private var collapsedHotZone: CGRect = .zero
    private var expandedHotZone: CGRect = .zero

    /// Screen-space menu bar strip on the built-in display, if present.
    private var menuBarStrip: CGRect = .zero

    private var cancellables = Set<AnyCancellable>()

    func start() {
        hotZoneKeys.onTogglePlayPause = { [weak self] in self?.nowPlaying.togglePlayPause() }
        hotZoneKeys.onNext = { [weak self] in self?.nowPlaying.next() }
        hotZoneKeys.onPrevious = { [weak self] in self?.nowPlaying.previous() }
        hotZoneKeys.onVolumeUp = { [weak self] in self?.volume.volumeUp() }
        hotZoneKeys.onVolumeDown = { [weak self] in self?.volume.volumeDown() }
        hotZoneKeys.start()

        hoverMonitor.onEnter = { [weak self] in self?.pointerEnteredHot() }
        hoverMonitor.onExit = { [weak self] in self?.pointerExitedHot() }
        hoverMonitor.onTick = { [weak self] inside in
            self?.hotZoneKeys.updatePointerInHotZone(inside)
            self?.updateMousePassthrough(pointerInHotZone: inside)
        }
        hoverMonitor.hotZoneScreenRect = { [weak self] in self?.hotZoneScreenRect() ?? .zero }
        hoverMonitor.start()

        wireProviders()
        rebuildForCurrentDisplays()

        NotificationCenter.default.addObserver(
            self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // Rebuild hover tracking whenever expansion state flips.
        state.$isExpanded
            .removeDuplicates()
            .sink { [weak self] _ in self?.container?.refreshTracking() }
            .store(in: &cancellables)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        hoverMonitor.stop()
        hotZoneKeys.stop()
        nowPlaying.stop(); calendar.stop(); airDrop.stop(); appSwitch.stop()
        window?.orderOut(nil)
    }

    // MARK: - Providers

    private func wireProviders() {
        nowPlaying.onUpdate = { [weak self] np in self?.state.notifyMediaChanged(np) }
        calendar.onUpdate = { [weak self] event in self?.state.nextEvent = event }
        airDrop.onUpdate = { [weak self] status in self?.state.airDrop = status }
        appSwitch.onFrontmostApp = { [weak self] name, icon in self?.state.setFrontmostApp(name, icon: icon) }
        appSwitch.onSwitch = { [weak self] name, icon in self?.state.notifyAppSwitched(name, icon: icon) }

        nowPlaying.start(); calendar.start(); airDrop.start(); appSwitch.start()
        if let level = volume.currentVolume() { state.refreshSystemVolume(level) }
        volume.onVolumeChanged = { [weak self] level in self?.state.showVolume(level) }

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

        metrics = NotchMetrics(notchWidth: geometry.notchRect.width,
                               notchHeight: geometry.notchRect.height,
                               designExpandedWidth: NotchGeometry.expandedWidth,
                               designExpandedHeight: NotchGeometry.expandedHeight,
                               scale: NotchGeometry.expandedScale,
                               topGap: NotchGeometry.contentTopGap)

        let frame = geometry.windowFrame
        updateHotZones(geometry: geometry, windowFrame: frame)
        let actions = NotchActions(
            togglePlayPause: { [weak self] in self?.nowPlaying.togglePlayPause() },
            next: { [weak self] in self?.nowPlaying.next() },
            previous: { [weak self] in self?.nowPlaying.previous() })

        let root = NotchRootView(state: state, shelf: shelf, metrics: metrics, actions: actions)

        if window == nil {
            let win = NotchWindow(contentRect: frame)
            let container = NotchContainerView(metrics: metrics)
            container.isExpandedProvider = { [weak self] in self?.state.isExpanded ?? false }
            container.onHotEntered = { [weak self] in self?.pointerEnteredHot() }
            container.onHotExited = { [weak self] in self?.pointerExitedHot() }
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
            window?.setFrame(frame, display: true)
            container?.metrics = metrics
            if let hosting = container?.subviews.first as? NSHostingView<NotchRootView> {
                hosting.rootView = root
            }
        }

        window?.setFrame(frame, display: true)
        window?.orderFrontRegardless()
        window?.ignoresMouseEvents = true
        container?.refreshTracking()

        // Screenshot/inspection aid: start expanded so the pill is visible.
        if Diagnostics.forceExpand { state.setExpanded(true) }
        Diagnostics.seedShelfIfRequested(shelf)
    }

    // MARK: - Hover logic

    private static let logHover = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    private func pointerEnteredHot() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if Self.logHover { print("HOVER enter @\(String(format: "%.3f", Date().timeIntervalSince1970)) -> expand") }
        state.setExpanded(true)
        hotZoneKeys.setActive(true)
        hotZoneKeys.updatePointerInHotZone(true)
        // Become key on hover so Space reaches us without a click. Activating
        // briefly is required for the local key monitor when another app is front.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(container)
    }

    private func pointerExitedHot() {
        hotZoneKeys.setActive(false)
        hotZoneKeys.updatePointerInHotZone(false)
        window?.makeFirstResponder(nil)
        window?.resignKey()
        collapseWorkItem?.cancel()
        if Self.logHover { print("HOVER exit -> collapse in \(collapseGrace)s") }
        let item = DispatchWorkItem { [weak self] in
            if Self.logHover { print("HOVER collapse fired @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
            self?.state.setExpanded(false)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseGrace, execute: item)
    }

    /// Hot zone in screen coordinates for the hover poller.
    private func hotZoneScreenRect() -> CGRect {
        state.isExpanded ? expandedHotZone : collapsedHotZone
    }

    private func updateHotZones(geometry: NotchGeometry, windowFrame: CGRect) {
        menuBarStrip = NotchGeometry.menuBarStrip(for: geometry.screen)

        // Collapsed: center notch + chip row below — not the menu-bar flanks.
        let previewWidth = min(NotchGeometry.expandedWidth * NotchGeometry.expandedScale,
                               geometry.notchRect.width + 220)
        let chipRowHeight: CGFloat = 34
        let chipRow = CGRect(
            x: geometry.notchRect.midX - previewWidth / 2,
            y: geometry.notchRect.minY - chipRowHeight,
            width: previewWidth,
            height: chipRowHeight
        )
        collapsedHotZone = geometry.notchRect.union(chipRow).insetBy(dx: -8, dy: -4)

        // Expanded: pill body only — menu bar strip is excluded.
        let pillWidth = min(NotchGeometry.expandedWidth * NotchGeometry.expandedScale, windowFrame.width)
        expandedHotZone = CGRect(
            x: windowFrame.minX + (windowFrame.width - pillWidth) / 2,
            y: windowFrame.minY,
            width: pillWidth,
            height: max(0, windowFrame.height - geometry.notchRect.height)
        ).insetBy(dx: -8, dy: -4)

        if Self.logHover {
            print("HOTZONE collapsed=\(collapsedHotZone) expanded=\(expandedHotZone) menuBar=\(menuBarStrip)")
        }
        updateMousePassthrough(pointerInHotZone: hotZoneScreenRect().contains(NSEvent.mouseLocation))
    }

    /// Lets clicks reach menu-bar status items unless the pointer is in the pill hot zone.
    private func updateMousePassthrough(pointerInHotZone: Bool) {
        let mouse = NSEvent.mouseLocation
        let overMenuBar = menuBarStrip.contains(mouse)
        window?.ignoresMouseEvents = overMenuBar || !pointerInHotZone
    }
}
