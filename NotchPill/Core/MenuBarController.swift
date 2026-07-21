import AppKit
import ApplicationServices

/// A menu-bar status item giving the (otherwise chrome-less) accessory app a way
/// to quit, toggle tiles, and control launch-at-login.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = AppSettings.shared
    var hotZoneKeys: HotZoneKeyMonitor?
    var onTestVolumeUp: (() -> Void)?

    func install() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "capsule.fill",
                                   accessibilityDescription: "NotchPill")
            button.image?.isTemplate = true
            button.title = " NotchPill"
            button.imagePosition = .imageLeading
            button.action = #selector(showMenu(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func showMenu(_ sender: NSStatusBarButton) {
        statusItem.menu?.popUp(positioning: nil,
                               at: NSPoint(x: 0, y: sender.bounds.height + 4),
                               in: sender)
    }

    // Rebuild the menu each time it opens so checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "NotchPill", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addToggle(to: menu, title: "Next Event", isOn: settings.showCalendar) { [weak self] in
            self?.settings.showCalendar.toggle()
        }
        addToggle(to: menu, title: "File Shelf", isOn: settings.showFileShelf) { [weak self] in
            self?.settings.showFileShelf.toggle()
        }
        addToggle(to: menu, title: "Collapsed Preview", isOn: settings.showCollapsedActivity) { [weak self] in
            self?.settings.showCollapsedActivity.toggle()
        }
        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        addToggle(to: menu, title: "Launch at Login", isOn: settings.launchAtLogin) { [weak self] in
            guard let self else { return }
            self.settings.setLaunchAtLogin(!self.settings.launchAtLogin)
        }
        menu.addItem(.separator())

        if hotZoneKeys?.isAccessibilityGranted != true {
            let access = NSMenuItem(
                title: "Enable Keyboard Shortcuts…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: "")
            access.target = self
            menu.addItem(access)
        } else {
            let status = NSMenuItem(title: "Shortcuts: enabled", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        let testVol = NSMenuItem(title: "Test System Volume Up", action: #selector(testVolumeUp), keyEquivalent: "")
        testVol.target = self
        menu.addItem(testVol)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchPill", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func addToggle(to menu: NSMenu, title: String, isOn: Bool, action: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(handleToggle(_:)), keyEquivalent: "")
        item.target = self
        item.state = isOn ? .on : .off
        item.representedObject = Action(run: action)
        menu.addItem(item)
    }

    @objc private func handleToggle(_ sender: NSMenuItem) {
        (sender.representedObject as? Action)?.run()
    }

    @objc private func openSettings() {
        PreferencesController.shared.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        hotZoneKeys?.openAccessibilitySetup()
    }

    @objc private func testVolumeUp() {
        onTestVolumeUp?()
    }

    /// Boxes a closure so it can ride on `representedObject`.
    private final class Action: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }
}
