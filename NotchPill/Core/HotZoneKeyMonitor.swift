import AppKit
import ApplicationServices

/// Intercepts keyboard shortcuts while the pointer is over the notch hot zone,
/// without requiring a click or key-window focus.
final class HotZoneKeyMonitor {
    var onTogglePlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onVolumeUp: () -> Void = {}
    var onVolumeDown: () -> Void = {}

    /// Dispatches a hot-zone shortcut. Returns true when the key was handled.
    @discardableResult
    private func dispatch(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49: // space
            if Self.logKeys { print("KEYS space -> toggle") }
            onTogglePlayPause()
        case 124: // right arrow
            if Self.logKeys { print("KEYS right -> next") }
            onNext()
        case 123: // left arrow
            if Self.logKeys { print("KEYS left -> previous") }
            onPrevious()
        case 126: // up arrow
            if Self.logKeys { print("KEYS up -> volume up") }
            onVolumeUp()
        case 125: // down arrow
            if Self.logKeys { print("KEYS down -> volume down") }
            onVolumeDown()
        default:
            return false
        }
        return true
    }

    /// Screen-coordinate hot-zone check, updated on the main thread each hover tick.
    var isPointerInHotZone: () -> Bool = { false }

    private let lock = NSLock()
    private var active = false
    private var cachedInHotZone = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    private static let logKeys = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    func start() {
        promptForAccessibilityIfNeeded()
        installEventTap()
        showAccessibilityAlertIfNeeded()

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        setActive(false)
        removeEventTap()
        removeGlobalMonitor()
        removeLocalMonitor()
    }

    func setActive(_ active: Bool) {
        lock.withLock {
            self.active = active
            self.cachedInHotZone = active
        }
        if active {
            installLocalMonitor()
            if !hasWorkingMonitor { installEventTap() }
        } else {
            removeLocalMonitor()
        }
        if Self.logKeys {
            print("KEYS active=\(active) local=\(localMonitor != nil) tap=\(eventTap != nil) global=\(globalMonitor != nil)")
        }
    }

    /// Called from the main thread on each hover poll so the tap thread can read
    /// a fresh flag without touching AppKit.
    func updatePointerInHotZone(_ inside: Bool) {
        lock.withLock { cachedInHotZone = inside }
    }

    @objc private func appDidBecomeActive() {
        if !hasWorkingMonitor, AXIsProcessTrusted() {
            installEventTap()
        }
    }

    // MARK: - Accessibility

    private func promptForAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private func showAccessibilityAlertIfNeeded() {
        guard !AXIsProcessTrusted(), !hasWorkingMonitor else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard !AXIsProcessTrusted() else { return }
            let alert = NSAlert()
            alert.messageText = "Enable Keyboard Shortcuts"
            alert.informativeText = """
            NotchPill needs Accessibility access so Space can pause music while \
            your cursor is over the notch.

            Open System Settings → Privacy & Security → Accessibility, turn on \
            NotchPill, then relaunch the app.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                Self.openAccessibilitySettings()
            }
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Event tap

    private func installEventTap() {
        removeGlobalMonitor()
        guard eventTap == nil else { return }

        let mask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.tapDisabledByTimeout.rawValue)

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventTapCallback,
            userInfo: refcon
        ) ?? CGEvent.tapCreate(
            tap: .cgAnnotatedSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: Self.eventTapCallback,
            userInfo: refcon
        )

        guard let tap else {
            if Self.logKeys { print("KEYS event tap unavailable — trying global monitor") }
            installGlobalMonitorFallback()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if Self.logKeys { print("KEYS event tap installed, AX=\(AXIsProcessTrusted())") }
    }

    private func removeEventTap() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
        guard let refcon else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<HotZoneKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handleEvent(proxy: proxy, type: type, event: event)
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType,
                             event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown, shouldHandleShortcut else {
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        switch keyCode {
        case 49, 124, 123, 126, 125:
            DispatchQueue.main.async { [weak self] in self?.dispatch(keyCode: keyCode) }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private var shouldHandleShortcut: Bool {
        lock.withLock { active || cachedInHotZone }
    }

    // MARK: - Local monitor (works once the app is key — no Accessibility needed)

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shouldHandleShortcut, !event.isARepeat else { return event }
            if self.dispatch(keyCode: event.keyCode) { return nil }
            return event
        }
        if Self.logKeys { print("KEYS local monitor installed") }
    }

    private func removeLocalMonitor() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    // MARK: - Global fallback (needs Accessibility when another app is focused)

    private func installGlobalMonitorFallback() {
        guard globalMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.shouldHandleShortcut, !event.isARepeat else { return }
            DispatchQueue.main.async {
                _ = self.dispatch(keyCode: event.keyCode)
            }
        }) else {
            if Self.logKeys { print("KEYS global monitor unavailable — grant Accessibility to NotchPill") }
            return
        }
        globalMonitor = monitor
        if Self.logKeys { print("KEYS global monitor installed, AX=\(AXIsProcessTrusted())") }
    }

    var hasWorkingMonitor: Bool {
        eventTap != nil || globalMonitor != nil || localMonitor != nil
    }

    var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }
}
