import AppKit
import SwiftUI

/// Presents the settings window — the primary app surface when launched from the Dock.
@MainActor
final class PreferencesController {
    static let shared = PreferencesController()

    private var window: NSWindow?

    func show(bringToFront: Bool = true) {
        if window == nil {
            let content = PreferencesView()
            let hosting = NSHostingController(rootView: content)
            let win = NSWindow(contentViewController: hosting)
            win.title = "NotchPill"
            win.styleMask = [.titled, .closable, .miniaturizable]
            win.setContentSize(NSSize(width: 480, height: 580))
            win.center()
            win.isReleasedWhenClosed = false
            win.setFrameAutosaveName("NotchPillSettings")
            window = win
        }
        if bringToFront {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFront(nil)
        }
    }
}
