import AppKit
import CoreAudio

/// The volume card's "send sound to…" menu.
///
/// A real `NSMenu` for the same reasons `ShelfDestinationMenu` is one: it runs
/// its own event loop, needs no key window, and is placed in screen
/// coordinates, so the pill collapsing underneath it cannot take it away.
@MainActor
final class AudioOutputMenu: NSObject {
    static let shared = AudioOutputMenu()

    private var onPick: ((AudioOutputDevice) -> Void)?

    func present(devices: [AudioOutputDevice],
                 current: AudioDeviceID?,
                 onPick: @escaping (AudioOutputDevice) -> Void) {
        guard !devices.isEmpty else { return }
        self.onPick = onPick

        let menu = NSMenu()
        menu.autoenablesItems = false
        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(pick(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.isEnabled = true
            item.representedObject = device.id
            item.state = device.id == current ? .on : .off
            item.image = NSImage(systemSymbolName: device.symbolName,
                                 accessibilityDescription: nil)
            menu.addItem(item)
        }

        // Hopping off this turn of the run loop, and activating first, for the
        // reasons written out at length in ShelfDestinationMenu: a modal event
        // loop started during a SwiftUI update is unreliable, and an inactive
        // app's menu may take no events at all.
        let location = NSEvent.mouseLocation
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            menu.popUp(positioning: nil, at: location, in: nil)
        }
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? AudioDeviceID,
              let device = AudioOutputStore.shared.devices.first(where: { $0.id == id })
        else { return }
        onPick?(device)
        onPick = nil
    }
}
