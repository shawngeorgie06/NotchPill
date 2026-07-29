import AppKit
import SwiftUI

/// Presents the first-run guide in its own window.
///
/// Deliberately not a sheet on Settings: the guide is what a new install should
/// see *instead* of Settings, and putting it on top of the thing it exists to
/// explain would show every control at once.
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()

    private var window: NSWindow?

    /// - Parameter takeFocus: true when the user asked for the guide from the
    ///   menu. On first launch it is false: the app starts at login, behind
    ///   whatever the person is actually doing, and yanking keyboard focus out
    ///   of their editor to show a welcome screen is rude — and worse, it lands
    ///   their next keystroke on a button in here. The window still comes to
    ///   the front, it just doesn't become key until it's clicked.
    func show(takeFocus: Bool = true) {
        if window == nil {
            let hosting = NSHostingController(rootView: OnboardingView(onFinish: { [weak self] in
                self?.close()
            }))
            let win = NSWindow(contentViewController: hosting)
            win.title = "Getting Started"
            win.styleMask = [.titled, .closable]
            win.setContentSize(NSSize(width: 520, height: 480))
            win.center()
            win.isReleasedWhenClosed = false
            // An accessory app's window opens on whatever space it was created
            // on. First launch often happens while something else is
            // full-screen, and a guide the user never sees is worse than no
            // guide — so it follows them instead.
            win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            window = win
        }
        if takeFocus {
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKeyAndOrderFront(nil)
        } else {
            window?.orderFrontRegardless()
        }
    }

    /// Closing by any route counts as done — someone who hits the red button
    /// has made their decision, and re-interrupting them on next launch would
    /// be the app arguing with them.
    func close() {
        Onboarding.markComplete()
        window?.close()
    }
}
