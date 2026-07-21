import AppKit
import ApplicationServices

/// A menu-bar status item giving the (otherwise chrome-less) accessory app a way
/// to quit, toggle tiles, and control launch-at-login.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let settings = AppSettings.shared
    var hotZoneKeys: HotZoneKeyMonitor?
    var onTestVolumeUp: (() -> Void)?
    var onTestDevReady: (() -> Void)?
    var onTestMultipleDevReady: (() -> Void)?

    func install() {
        if let button = statusItem.button {
            button.image = MenuBarIcon.templateImage()
            button.imagePosition = .imageOnly
            button.title = ""
            button.toolTip = "NotchPill — notch overlay & live status"
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
        header.attributedTitle = NSAttributedString(
            string: "NotchPill",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]
        )
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

        let about = NSMenuItem(title: "About NotchPill", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
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

        let testDev = NSMenuItem(title: "Test Dev Ready Ping", action: #selector(testDevReady), keyEquivalent: "")
        testDev.target = self
        menu.addItem(testDev)

        let testMulti = NSMenuItem(title: "Test Multiple Dev Ready Pings", action: #selector(testMultipleDevReady), keyEquivalent: "")
        testMulti.target = self
        menu.addItem(testMulti)

        let copyNotify = NSMenuItem(title: "Copy Notify Command", action: #selector(copyNotifyCommand), keyEquivalent: "")
        copyNotify.target = self
        menu.addItem(copyNotify)

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

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "NotchPill",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0",
            .credits: NSAttributedString(string: "Dynamic Island for your Mac notch.\n\nRuns in the background from the menu bar. Hover the notch to expand."),
        ])
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

    @objc private func testDevReady() {
        onTestDevReady?()
    }

    @objc private func testMultipleDevReady() {
        onTestMultipleDevReady?()
    }

    @objc private func copyNotifyCommand() {
        let script = "~/Projects/NotchPill/Scripts/notify-notchpill.sh \"Agent finished\" \"Review the changes\" Cursor com.todesktop.230313mzl4w4u92 Composer"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(script, forType: .string)
    }

    /// Boxes a closure so it can ride on `representedObject`.
    private final class Action: NSObject {
        let run: () -> Void
        init(run: @escaping () -> Void) { self.run = run }
    }
}
