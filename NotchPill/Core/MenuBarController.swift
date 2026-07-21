import AppKit

/// A menu-bar status item giving the (otherwise chrome-less) accessory app a way
/// to quit, toggle tiles, and control launch-at-login.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings = AppSettings.shared

    func install() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled",
                                   accessibilityDescription: "NotchPill")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // Rebuild the menu each time it opens so checkmarks reflect current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let header = NSMenuItem(title: "NotchPill", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addToggle(to: menu, title: "Battery", isOn: settings.showBattery) { [weak self] in
            self?.settings.showBattery.toggle()
        }
        addToggle(to: menu, title: "Next Event", isOn: settings.showCalendar) { [weak self] in
            self?.settings.showCalendar.toggle()
        }
        addToggle(to: menu, title: "File Shelf", isOn: settings.showFileShelf) { [weak self] in
            self?.settings.showFileShelf.toggle()
        }
        addToggle(to: menu, title: "Live Music Preview", isOn: settings.showCollapsedActivity) { [weak self] in
            self?.settings.showCollapsedActivity.toggle()
        }
        menu.addItem(.separator())
        addToggle(to: menu, title: "Launch at Login", isOn: settings.launchAtLogin) { [weak self] in
            guard let self else { return }
            self.settings.setLaunchAtLogin(!self.settings.launchAtLogin)
        }
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

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    /// Boxes a closure so it can ride on `representedObject`.
    private final class Action: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }
}
