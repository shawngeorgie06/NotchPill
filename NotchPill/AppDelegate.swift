import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if Diagnostics.isEnabled {
            Diagnostics.run()
            return
        }

        NSApp.setActivationPolicy(.accessory)

        // First line in the log, so an exported report always says which build
        // and which permissions produced everything below it.
        LogStore.log("app", "launched "
            + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "?")
            + " · accessibility "
            + (AccessibilityAuthorization.isGranted ? "granted" : "NOT granted"))

        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar
        controller = NotchController()
        menuBar.hotZoneKeys = controller?.keyMonitor
        menuBar.onTestVolumeUp = { [weak controller] in controller?.testSystemVolumeUp() }
        menuBar.onTestDevReady = { [weak controller] in controller?.testDevReadyPing() }
        menuBar.onTestMultipleDevReady = { [weak controller] in controller?.testMultipleDevReadyPings() }
        controller?.start()

        // Check GitHub for a newer release so the menu bar can offer an in-app update.
        UpdateChecker.shared.onUpdateFound = { [weak self] _ in
            // Rebuilding isn't needed — the menu reads live state when opened —
            // but nudge the icon so a fresh update is noticeable.
            self?.menuBar?.flagUpdateAvailable()
        }
        UpdateChecker.shared.start()

        // First launch only. Settings used to open here, which showed every
        // control at once and explained none of them; the guide walks the two
        // grants that gate real features and then shows what the row can hold.
        if Onboarding.shouldShow {
            DispatchQueue.main.async {
                OnboardingController.shared.show(takeFocus: false)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PreferencesController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep the notch overlay running when Settings is closed.
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
