import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var menuBar: MenuBarController?
    private var appMenu: AppMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if Diagnostics.isEnabled {
            Diagnostics.run()
            return
        }

        NSApp.setActivationPolicy(.regular)
        let appMenu = AppMenuController()
        appMenu.install()
        self.appMenu = appMenu

        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar
        controller = NotchController()
        menuBar.hotZoneKeys = controller?.keyMonitor
        menuBar.onTestVolumeUp = { [weak controller] in controller?.testSystemVolumeUp() }
        menuBar.onTestDevReady = { [weak controller] in controller?.testDevReadyPing() }
        menuBar.onTestMultipleDevReady = { [weak controller] in controller?.testMultipleDevReadyPings() }
        controller?.start()

        // Load the notch first; open settings without stealing focus from the front app.
        DispatchQueue.main.async {
            PreferencesController.shared.show(bringToFront: false)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesController.shared.show() }
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
