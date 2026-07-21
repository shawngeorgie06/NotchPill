import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: NotchController?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosted by the unit-test bundle, don't spin up the overlay.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        if Diagnostics.isEnabled {
            Diagnostics.run()
            return
        }
        let menuBar = MenuBarController()
        menuBar.install()
        self.menuBar = menuBar
        controller = NotchController()
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}
