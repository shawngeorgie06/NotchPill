import AppKit
import SwiftUI

/// Presents the log window.
@MainActor
final class LogViewerController {
    static let shared = LogViewerController()

    private var window: NSWindow?

    func show() {
        if window == nil {
            let win = NSWindow(contentViewController: NSHostingController(rootView: LogView()))
            win.title = "NotchPill Log"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.setContentSize(NSSize(width: 700, height: 460))
            win.center()
            win.isReleasedWhenClosed = false
            win.setFrameAutosaveName("NotchPillLog")
            // Debugging usually means watching the notch do something while the
            // log is open, and the notch reacts to the *frontmost* app — so this
            // follows you rather than pinning you to one space.
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = win
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
