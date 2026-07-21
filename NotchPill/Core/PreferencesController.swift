import AppKit
import SwiftUI

/// Presents the settings window for the accessory (menu-bar-only) app.
@MainActor
final class PreferencesController {
    static let shared = PreferencesController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let content = PreferencesView()
            let hosting = NSHostingController(rootView: content)
            let win = NSWindow(contentViewController: hosting)
            win.title = "NotchPill Settings"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 420, height: 360))
            win.center()
            win.isReleasedWhenClosed = false
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
