import SwiftUI
import ServiceManagement

/// User-facing preferences, persisted in UserDefaults and observable by the UI.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @AppStorage("showBattery") var showBattery = true
    @AppStorage("showCalendar") var showCalendar = true
    @AppStorage("showFileShelf") var showFileShelf = true

    /// Launch-at-login is backed by SMAppService, not UserDefaults; this mirror
    /// keeps the menu checkmark in sync.
    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            NSLog("NotchPill: launch-at-login toggle failed: \(error.localizedDescription)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
