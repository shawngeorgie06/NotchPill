import AppKit

/// The shelf's "file this somewhere" menu, as a real `NSMenu`.
///
/// This started life as a SwiftUI `.popover` and did not survive contact with
/// the notch. The pill is a nonactivating panel that collapses the moment the
/// pointer leaves it, so a popover hanging below the notch was dismissed as the
/// user reached for it; and `.onDrag` on the same chip competes with
/// `.onTapGesture`, so the click that opened it often never arrived.
///
/// `NSMenu.popUp` sidesteps both. It runs its own event loop, needs no key
/// window, and is positioned in screen coordinates, so it is unaffected by what
/// the pill does underneath it.
@MainActor
final class ShelfDestinationMenu: NSObject {
    static let shared = ShelfDestinationMenu()

    private var onPick: ((URL) -> Void)?

    /// - Parameter onPick: called with the chosen folder. Not called if the
    ///   menu is dismissed without a choice.
    func present(destinations: [FileDestination], onPick: @escaping (URL) -> Void) {
        self.onPick = onPick

        let menu = NSMenu()
        menu.autoenablesItems = false

        let pinned = destinations.filter { $0.source == .pinned }
        let recent = destinations.filter { $0.source == .recent }

        if !pinned.isEmpty {
            menu.addItem(header("PINNED"))
            pinned.forEach { menu.addItem(destinationItem($0)) }
        }
        if !recent.isEmpty {
            if !pinned.isEmpty { menu.addItem(.separator()) }
            menu.addItem(header("RECENT (FINDER)"))
            recent.forEach { menu.addItem(destinationItem($0)) }
        }
        if !pinned.isEmpty || !recent.isEmpty { menu.addItem(.separator()) }

        let other = NSMenuItem(title: "Other Folder…",
                               action: #selector(chooseOtherFolder(_:)),
                               keyEquivalent: "")
        other.target = self
        other.isEnabled = true
        other.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil)
        menu.addItem(other)

        // Two things this needs that are easy to miss.
        //
        // `popUp` runs a modal event loop, and starting one from inside a
        // SwiftUI button action — i.e. during a view update — is unreliable;
        // AppKit can simply decline. Hopping to the next turn of the run loop
        // gets it out of the update.
        //
        // And NotchPill is a menu-bar accessory whose panel never activates, so
        // the menu belongs to an inactive app and may not take events. It has
        // to be frontmost for the duration.
        let location = NSEvent.mouseLocation
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let started = Date()
            // `in: nil` makes the location screen-relative, which is what
            // `NSEvent.mouseLocation` already is.
            let shown = menu.popUp(positioning: nil, at: location, in: nil)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            LogStore.shelf("menu popUp returned \(shown) after \(ms)ms at "
                + "\(Int(location.x)),\(Int(location.y))")
        }
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private func destinationItem(_ destination: FileDestination) -> NSMenuItem {
        let item = NSMenuItem(title: destination.name,
                              action: #selector(pick(_:)),
                              keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        item.representedObject = destination.url
        item.toolTip = destination.url.path
        let icon = NSWorkspace.shared.icon(forFile: destination.url.path)
        icon.size = NSSize(width: 14, height: 14)
        item.image = icon
        return item
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        onPick?(url)
        onPick = nil
    }

    @objc private func chooseOtherFolder(_ sender: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        // Nonactivating panel: without this the picker opens behind whatever is
        // frontmost and accepts no keyboard input.
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            onPick?(url)
        }
        onPick = nil
    }
}
