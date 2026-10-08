import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Captures keyboard shortcuts while the pointer is over the notch.
///
/// The event tap has an explicit lifecycle because installation happens on a
/// separate thread. The tap is the only active capture path when it is ready;
/// NSEvent monitors are installed only as a fallback.
final class HotZoneKeyMonitor {
    var onTogglePlayPause: () -> Void = {}
    var onNext: () -> Void = {}
    var onPrevious: () -> Void = {}
    var onVolumeUp: () -> Void = {}
    var onVolumeDown: () -> Void = {}
    var pointerInHotZone: () -> Bool = { false }

    private enum TapLifecycle: Equatable { case stopped, starting, running, stopping }

    private let lock = NSRecursiveLock()
    private var lifecycle = TapLifecycle.stopped
    private var generation: UInt64 = 0
    private var wantsEventTap = false
    private var cachedInHotZone = false
    private var suspendedState = false
    private var textInputFocused = false
    private var lastDispatch: (keyCode: UInt16, time: CFAbsoluteTime)?
    private var typing = TypingGuard()

    // Written by the tap thread and read by the main thread while holding lock.
    private var eventTap: CFMachPort?
    private var tapRunLoop: CFRunLoop?
    private var tapRunLoopSource: CFRunLoopSource?
    private var tapThread: Thread?

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var pendingAccessibilityAlert: DispatchWorkItem?
    private var observersInstalled = false

    private static let logKeys = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_HOVER"] == "1"

    /// Set from the main thread when a text field starts or stops editing.
    var suspended: Bool {
        get { lock.withLock { suspendedState } }
        set { lock.withLock { suspendedState = newValue } }
    }

    private func noteKeyAndCheckTyping(keyCode: UInt16) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            typing.observe(isShortcut: isShortcut(keyCode), now: now)
            return typing.isTyping(now: now)
        }
    }

    func start() {
        installMonitors()
        installFallbackMonitors()
        if !AccessibilityAuthorization.isGranted, !hasWorkingMonitor {
            if AccessibilityAuthorization.shouldOfferSystemPrompt {
                AccessibilityAuthorization.requestSystemPrompt()
            } else if AccessibilityAuthorization.shouldOfferAlert {
                showAccessibilityAlertIfNeeded()
            }
        }
        guard !observersInstalled else { return }
        observersInstalled = true
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
        observersInstalled = false
        pendingAccessibilityAlert?.cancel()
        pendingAccessibilityAlert = nil
        updatePointerInHotZone(false)
        stopEventTap()
        removeGlobalMonitor()
        removeLocalMonitor()
    }

    func setActive(_ active: Bool) {
        if Self.logKeys { print("KEYS setActive(\(active)) ignored") }
    }

    func updatePointerInHotZone(_ inside: Bool) {
        let responder = NSApp.keyWindow?.firstResponder
        let editingText = responder is NSTextView || responder is NSTextField || responder is NSSearchField
        lock.withLock {
            let wasInside = cachedInHotZone
            cachedInHotZone = inside
            textInputFocused = editingText
            if inside, !wasInside { typing.reset() }
        }
        if inside { ensureShortcutCaptureReady() }
    }

    func ensureShortcutCaptureReady() {
        guard AccessibilityAuthorization.isGranted else { return }
        startEventTapIfNeeded()
    }

    @objc private func appDidBecomeActive() {
        pendingAccessibilityAlert?.cancel()
        pendingAccessibilityAlert = nil
        installMonitors()
        installFallbackMonitors()
    }

    @objc private func accessibilityChanged() {
        installMonitors()
        installFallbackMonitors()
    }

    private func showAccessibilityAlertIfNeeded() {
        guard AccessibilityAuthorization.shouldOfferAlert, !hasWorkingMonitor else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  AccessibilityAuthorization.shouldOfferAlert,
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

    private func installMonitors() {
        guard AccessibilityAuthorization.isGranted else {
            stopEventTap()
            return
        }
        startEventTapIfNeeded()
    }

    /// Starts at most one tap thread, including while the previous request is
    /// still creating its mach port. Callers only transition stopped → starting.
    private func startEventTapIfNeeded() {
        guard AccessibilityAuthorization.isGranted else { return }
        let threadToStart: Thread? = lock.withLock {
            wantsEventTap = true
            guard case .stopped = lifecycle else { return nil }
            lifecycle = .starting
            generation &+= 1
            let launchGeneration = generation
            let thread = Thread { [weak self] in
                self?.runEventTapThread(generation: launchGeneration)
            }
            thread.name = "NotchPill.HotZoneKeyTap"
            tapThread = thread
            return thread
        }
        threadToStart?.start()
    }

    private func runEventTapThread(generation launchGeneration: UInt64) {
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
            lock.withLock {
                if generation == launchGeneration {
                    lifecycle = .stopped
                    tapThread = nil
                }
            }
            if Self.logKeys { print("KEYS event tap unavailable; using NSEvent fallback") }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.generation == launchGeneration && self.lifecycle == .stopped }) else { return }
                self.installFallbackMonitors()
            }
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        let shouldRun = lock.withLock { () -> Bool in
            guard generation == launchGeneration, lifecycle == .starting else { return false }
            eventTap = tap
            tapRunLoop = runLoop
            tapRunLoopSource = source
            lifecycle = .running
            return true
        }
        guard shouldRun else {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
            CFMachPortInvalidate(tap)
            eventTapThreadFinished(generation: launchGeneration)
            return
        }

        // Keep only one capture path. A CG tap sees the app's own key events as
        // well, so local/global NSEvent monitors are removed once it is live.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.lock.withLock({ self.generation == launchGeneration && self.lifecycle == .running }) else { return }
            self.removeGlobalMonitor()
            self.removeLocalMonitor()
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        if Self.logKeys { print("KEYS event tap running on background thread") }
        CFRunLoopRun()

        CFRunLoopRemoveSource(runLoop, source, .commonModes)
        CFMachPortInvalidate(tap)
        eventTapThreadFinished(generation: launchGeneration)
    }

    private func eventTapThreadFinished(generation launchGeneration: UInt64) {
        let restart = lock.withLock { () -> Bool in
            guard generation == launchGeneration else { return false }
            eventTap = nil
            tapRunLoop = nil
            tapRunLoopSource = nil
            tapThread = nil
            lifecycle = .stopped
            return wantsEventTap
        }
        if restart {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.lock.withLock({ self.wantsEventTap }) else { return }
                self.startEventTapIfNeeded()
            }
        }
    }

    private func stopEventTap() {
        let stopState = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            wantsEventTap = false
            guard lifecycle == .running || lifecycle == .starting else { return (nil, nil) }
            lifecycle = .stopping
            return (eventTap, tapRunLoop)
        }
        if let tap = stopState.0 { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop = stopState.1 {
            // Queue the stop on the tap run loop itself. This also covers a
            // stop request immediately before CFRunLoopRun() begins.
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes!.rawValue) {
                CFRunLoopStop(runLoop)
            }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func installFallbackMonitors() {
        guard lock.withLock({ lifecycle != .running && lifecycle != .stopping }) else { return }
        installLocalMonitor()
        installGlobalMonitor()
    }

    private func installGlobalMonitor() {
        guard globalMonitor == nil else { return }
        guard let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            self?.handleObservedKeyDown(event)
        }) else { return }
        globalMonitor = monitor
        if Self.logKeys { print("KEYS global fallback monitor installed") }
    }

    private func handleObservedKeyDown(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard !IsSecureEventInputEnabled(), !hasShortcutModifiers(event.modifierFlags), !isTextInputFocused else { return }
        guard !noteKeyAndCheckTyping(keyCode: event.keyCode) else { return }
        _ = dispatchIfNeeded(keyCode: event.keyCode, fromTap: false)
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotZoneKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
        return monitor.handleEvent(type: type, event: event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout {
            if let eventTap = lock.withLock({ lifecycle == .running ? eventTap : nil }) {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard !IsSecureEventInputEnabled(), !hasShortcutModifiers(event.flags), !isTextInputFocused else {
            return Unmanaged.passUnretained(event)
        }
        let wasTyping = noteKeyAndCheckTyping(keyCode: keyCode)
        let shouldCapture = lock.withLock { cachedInHotZone }
        guard isShortcut(keyCode), !wasTyping, shouldCapture else {
            return Unmanaged.passUnretained(event)
        }
        guard dispatchIfNeeded(keyCode: keyCode, fromTap: true) else {
            return Unmanaged.passUnretained(event)
        }
        return nil
    }

    @discardableResult
    private func dispatchIfNeeded(keyCode: UInt16, fromTap: Bool) -> Bool {
        guard isShortcut(keyCode) else { return false }
        let now = CFAbsoluteTimeGetCurrent()
        let decision = lock.withLock { () -> (capture: Bool, dispatch: Bool) in
            guard !suspendedState, !textInputFocused, cachedInHotZone else { return (false, false) }
            if let last = lastDispatch, last.keyCode == keyCode, now - last.time < 0.05 {
                return (true, false)
            }
            lastDispatch = (keyCode, now)
            return (true, true)
        }
        guard decision.capture else { return false }
        guard decision.dispatch else { return true }

        // Event taps must never wait on main. Their callback uses a cached hover
        // bit and schedules the action, keeping input latency independent of UI.
        if fromTap {
            DispatchQueue.main.async { [weak self] in self?.dispatchIfStillActive(keyCode: keyCode) }
        } else if Thread.isMainThread {
            _ = dispatch(keyCode: keyCode)
        } else {
            DispatchQueue.main.async { [weak self] in self?.dispatchIfStillActive(keyCode: keyCode) }
        }
        return true
    }

    private func dispatchIfStillActive(keyCode: UInt16) {
        guard lock.withLock({ !suspendedState && !textInputFocused && cachedInHotZone }),
              pointerInHotZone() else { return }
        _ = dispatch(keyCode: keyCode)
    }

    @discardableResult
    private func dispatch(keyCode: UInt16) -> Bool {
        switch keyCode {
        case 49: onTogglePlayPause()
        case 124: onNext()
        case 123: onPrevious()
        case 126: onVolumeUp()
        case 125: onVolumeDown()
        default: return false
        }
        if Self.logKeys { print("KEYS shortcut \(keyCode) dispatched") }
        return true
    }

    private func isShortcut(_ keyCode: UInt16) -> Bool {
        switch keyCode { case 49, 124, 123, 126, 125: return true; default: return false }
    }

    private func hasShortcutModifiers(_ flags: NSEvent.ModifierFlags) -> Bool {
        !flags.intersection([.command, .option, .control, .shift, .function]).isEmpty
    }

    private func hasShortcutModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskAlternate, .maskControl,
                             .maskShift, .maskSecondaryFn]).isEmpty
    }

    private func installLocalMonitor() {
        guard localMonitor == nil else { return }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !event.isARepeat else { return event }
            guard !IsSecureEventInputEnabled(), !self.hasShortcutModifiers(event.modifierFlags),
                  !self.isTextInputFocused else { return event }
            guard !self.noteKeyAndCheckTyping(keyCode: event.keyCode) else { return event }
            if self.dispatchIfNeeded(keyCode: event.keyCode, fromTap: false) { return nil }
            return event
        }
    }

    private func removeLocalMonitor() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
    }

    private func removeGlobalMonitor() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
    }

    var hasWorkingMonitor: Bool {
        lock.withLock { lifecycle == .running } || globalMonitor != nil || localMonitor != nil
    }

    private var isTextInputFocused: Bool {
        lock.withLock { textInputFocused }
    }

    var isAccessibilityGranted: Bool { AccessibilityAuthorization.isGranted }

    func openAccessibilitySetup() {
        if AccessibilityAuthorization.isGranted {
            installMonitors()
            installFallbackMonitors()
            return
        }
        AccessibilityAuthorization.requestSystemPrompt()
        Self.openAccessibilitySettings()
    }
}
