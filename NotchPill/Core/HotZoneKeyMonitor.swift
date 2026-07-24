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
    /// When true, hot-zone key shortcuts (space/arrows) are suspended and pass
    /// through untouched — e.g. while a text field in the notch (the reply
    /// composer) is capturing keystrokes. Written on the main thread; read from
    /// the event-tap thread (a benign race on an aligned Bool).
    var suspended = false

    /// Live screen-space hot-zone check (must be safe to call on the main thread).
    var pointerInHotZone: () -> Bool = { false }

    private let lock = NSLock()
    private var cachedInHotZone = false
    private var lastDispatch: (keyCode: UInt16, time: CFAbsoluteTime)?

    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var tapThread: Thread?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingAccessibilityAlert: DispatchWorkItem?

    private static let logKeys = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    func start() {
        installMonitors()
        installLocalMonitor()

        if !AccessibilityAuthorization.isGranted, !hasWorkingMonitor {
            if AccessibilityAuthorization.shouldOfferSystemPrompt {
                AccessibilityAuthorization.requestSystemPrompt()
            } else if AccessibilityAuthorization.shouldOfferAlert {
                showAccessibilityAlertIfNeeded()
            }
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        DistributedNotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityChanged),
            name: NSNotification.Name("com.apple.accessibility.api"), object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        DistributedNotificationCenter.default.removeObserver(self)
        pendingAccessibilityAlert?.cancel()
        pendingAccessibilityAlert = nil
        updatePointerInHotZone(false)
        removeEventTap()
        removeGlobalMonitor()
        removeLocalMonitor()
    }

    func setActive(_ active: Bool) {
        if Self.logKeys { print("KEYS setActive(\(active)) ignored") }
    }

    func updatePointerInHotZone(_ inside: Bool) {
        lock.withLock { cachedInHotZone = inside }
        if inside {
            ensureShortcutCaptureReady()
        }
    }

    func ensureShortcutCaptureReady() {
        guard AccessibilityAuthorization.isGranted else { return }
        installEventTap()
        installGlobalMonitor()
    }

    @objc private func appDidBecomeActive() {
        pendingAccessibilityAlert?.cancel()
        pendingAccessibilityAlert = nil
        installMonitors()
    }

    @objc private func accessibilityChanged() {
        installMonitors()
    }

    // MARK: - Accessibility alert

    private func showAccessibilityAlertIfNeeded() {
        guard AccessibilityAuthorization.shouldOfferAlert, !hasWorkingMonitor else { return }

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard AccessibilityAuthorization.shouldOfferAlert,
                  !AccessibilityAuthorization.isGranted,
                  !self.hasWorkingMonitor else { return }

            AccessibilityAuthorization.markSystemPromptOffered()

            let alert = NSAlert()
            alert.messageText = "Enable Keyboard Shortcuts"
            alert.informativeText = """
            NotchPill needs Accessibility access so Space / arrow keys work while \
            your cursor is over the notch (even when Brave or another app is focused).

            In System Settings → Privacy & Security → Accessibility, turn on \
            NotchPill for this copy of the app, then relaunch.
            """
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            if alert.runModal() == .alertFirstButtonReturn {
                Self.openAccessibilitySettings()
            } else {
                AccessibilityAuthorization.markAlertDeclined()
            }
        }
        pendingAccessibilityAlert = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: item)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Monitors

    private func installMonitors() {
        if AccessibilityAuthorization.isGranted {
            installEventTap()
            installGlobalMonitor()
        } else {
            installGlobalMonitorFallback()
        }
    }

    private func installEventTap() {
        guard AccessibilityAuthorization.isGranted else { return }
        guard eventTap == nil else { return }

        tapThread = Thread { [weak self] in
            self?.runEventTapThread()
        }
        tapThread?.name = "NotchPill.HotZoneKeyTap"
        tapThread?.start()
    }

    private func runEventTapThread() {
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
            if Self.logKeys { print("KEYS event tap unavailable") }
            return
        }

        eventTap = tap
        tapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, tapRunLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        if Self.logKeys { print("KEYS event tap running on background thread") }
        CFRunLoopRun()
    }

    private func removeEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let source = tapRunLoopSource {
            CFRunLoopSourceInvalidate(source)
            tapRunLoopSource = nil
        }
        tapThread?.cancel()
        tapThread = nil
    }

    private func installGlobalMonitor() {
        guard AccessibilityAuthorization.isGranted else { return }
        guard globalMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleObservedKeyDown(event)
        }) else { return }
        globalMonitor = monitor
        if Self.logKeys { print("KEYS global monitor installed") }
    }

    private func installGlobalMonitorFallback() {
        guard globalMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleObservedKeyDown(event)
        }) else { return }
        globalMonitor = monitor
    }

    private func handleObservedKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        _ = dispatchIfNeeded(keyCode: event.keyCode)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotZoneKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard isShortcut(keyCode), isPointerInHotZoneLive() else {
            return Unmanaged.passUnretained(event)
        }

        if dispatchIfNeeded(keyCode: keyCode) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    @discardableResult
    private func dispatchIfNeeded(keyCode: UInt16) -> Bool {
        guard !suspended else { return false }
        guard isShortcut(keyCode) else { return false }

        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastDispatch, last.keyCode == keyCode, now - last.time < 0.05 {
            return true
        }

        final class Box { var value = false }
        let box = Box()
        let checkAndDispatch = { [weak self] in
            guard let self else { return }
            guard self.isPointerInHotZoneLive() else { return }
            self.lastDispatch = (keyCode, now)
            _ = self.dispatch(keyCode: keyCode)
            box.value = true
        }

        if Thread.isMainThread {
            checkAndDispatch()
        } else {
            DispatchQueue.main.sync(execute: checkAndDispatch)
        }
        return box.value
    }

    @discardableResult
    private func dispatch(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49:
            if Self.logKeys { print("KEYS space -> toggle") }
            onTogglePlayPause()
        case 124:
            if Self.logKeys { print("KEYS right -> next") }
            onNext()
        case 123:
            if Self.logKeys { print("KEYS left -> previous") }
            onPrevious()
        case 126:
            if Self.logKeys { print("KEYS up -> volume up") }
            onVolumeUp()
        case 125:
            if Self.logKeys { print("KEYS down -> volume down") }
            onVolumeDown()
        default:
            return false
        }
        return true
    }

    private func isShortcut(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49, 124, 123, 126, 125: return true
        default: return false
        }
    }

    private var shouldHandleShortcut: Bool {
        isPointerInHotZoneLive()
    }

    /// Reads the live cursor position on the main thread (authoritative for hover shortcuts).
    private func isPointerInHotZoneLive() -> Bool {
        if Thread.isMainThread {
            return pointerInHotZone()
        }
        var inside = false
        DispatchQueue.main.sync {
            inside = pointerInHotZone()
        }
        return inside
    }

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.isARepeat else { return event }
            if self.dispatchIfNeeded(keyCode: event.keyCode) { return nil }
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

    private func removeGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
    }

    var hasWorkingMonitor: Bool {
        eventTap != nil || globalMonitor != nil || localMonitor != nil
    }

    var isAccessibilityGranted: Bool {
        AccessibilityAuthorization.isGranted
    }

    func openAccessibilitySetup() {
        if AccessibilityAuthorization.isGranted {
            installMonitors()
            return
        }
        AccessibilityAuthorization.requestSystemPrompt()
        Self.openAccessibilitySettings()
    }
}
