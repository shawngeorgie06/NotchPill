import AppKit
import SwiftUI
import Combine

/// Owns the overlay window, its placement over the physical notch, hover-driven
/// expand/collapse with a grace delay, multi-display handling, and the wiring
/// of every data provider into the single `NotchState`.
@MainActor
final class NotchController {
    private let state = NotchState()
    private var window: NotchWindow?
    private var container: NotchContainerView?
    private var metrics = NotchMetrics(notchWidth: 200, notchHeight: 32,
                                       expandedWidth: NotchGeometry.expandedWidth,
                                       expandedHeight: NotchGeometry.expandedHeight)

    // Providers.
    private let nowPlaying = NowPlayingProvider()
    private let battery = BatteryProvider()
    private let calendar = CalendarProvider()
    private let airDrop = AirDropProvider()
    private let appSwitch = AppSwitchProvider()

    // Hover.
    private var collapseWorkItem: DispatchWorkItem?
    private let collapseGrace: TimeInterval = 0.5

    private var cancellables = Set<AnyCancellable>()

    func start() {
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
        nowPlaying.stop(); battery.stop(); calendar.stop(); airDrop.stop(); appSwitch.stop()
        window?.orderOut(nil)
    }

    // MARK: - Providers

    private func wireProviders() {
        nowPlaying.onUpdate = { [weak self] np in self?.state.notifyMediaChanged(np) }
        battery.onUpdate = { [weak self] info in self?.state.battery = info }
        calendar.onUpdate = { [weak self] event in self?.state.nextEvent = event }
        airDrop.onUpdate = { [weak self] status in self?.state.airDrop = status }
        appSwitch.onSwitch = { [weak self] name in self?.state.notifyAppSwitched(name) }

        nowPlaying.start(); battery.start(); calendar.start(); airDrop.start(); appSwitch.start()
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
                               expandedWidth: NotchGeometry.expandedWidth,
                               expandedHeight: NotchGeometry.expandedHeight)

        let frame = geometry.windowFrame
        let actions = NotchActions(
            togglePlayPause: { [weak self] in self?.nowPlaying.togglePlayPause() },
            next: { [weak self] in self?.nowPlaying.next() },
            previous: { [weak self] in self?.nowPlaying.previous() })

        let root = NotchRootView(state: state, metrics: metrics, actions: actions)

        if window == nil {
            let win = NotchWindow(contentRect: frame)
            let container = NotchContainerView(metrics: metrics)
            container.isExpandedProvider = { [weak self] in self?.state.isExpanded ?? false }
            container.onHotEntered = { [weak self] in self?.pointerEnteredHot() }
            container.onHotExited = { [weak self] in self?.pointerExitedHot() }

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
        container?.refreshTracking()

        // Screenshot/inspection aid: start expanded so the pill is visible.
        if Diagnostics.forceExpand { state.setExpanded(true) }
    }

    // MARK: - Hover logic

    private static let logHover = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    private func pointerEnteredHot() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if Self.logHover { print("HOVER enter @\(String(format: "%.3f", Date().timeIntervalSince1970)) -> expand") }
        state.setExpanded(true)
    }

    private func pointerExitedHot() {
        collapseWorkItem?.cancel()
        if Self.logHover { print("HOVER exit -> collapse in \(collapseGrace)s") }
        let item = DispatchWorkItem { [weak self] in
            if Self.logHover { print("HOVER collapse fired @\(String(format: "%.3f", Date().timeIntervalSince1970))") }
            self?.state.setExpanded(false)
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseGrace, execute: item)
    }
}
