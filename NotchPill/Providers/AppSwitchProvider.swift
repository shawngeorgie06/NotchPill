import AppKit

/// Watches the frontmost application and reports each switch. Feeds the state
/// manager so a switch briefly crossfades into an app chip on the notch.
final class AppSwitchProvider {
    var onFrontmostApp: ((String, NSImage?) -> Void)?
    var onSwitch: ((String, NSImage?) -> Void)?

    private var observation: NSObjectProtocol?

    func start() {
        reportCurrent()
        observation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.report(app, isSwitch: true)
        }
    }

    func stop() {
        if let observation {
            NSWorkspace.shared.notificationCenter.removeObserver(observation)
        }
        observation = nil
    }

    private func reportCurrent() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        report(app, isSwitch: false)
    }

    private func report(_ app: NSRunningApplication, isSwitch: Bool) {
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
        let name = app.localizedName ?? "App"
        if isSwitch {
            onSwitch?(name, app.icon)
        } else {
            onFrontmostApp?(name, app.icon)
        }
    }
}
