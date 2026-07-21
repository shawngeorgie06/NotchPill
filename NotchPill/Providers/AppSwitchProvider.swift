import AppKit

/// Watches the frontmost application and reports each switch. Feeds the state
/// manager so a switch briefly crossfades into an app chip on the notch.
final class AppSwitchProvider {
    var onSwitch: ((String) -> Void)?

    private var observation: NSObjectProtocol?

    func start() {
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Ignore our own accessory app.
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            let name = app.localizedName ?? "App"
            self?.onSwitch?(name)
        }
    }

    func stop() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observation = nil
    }
}
