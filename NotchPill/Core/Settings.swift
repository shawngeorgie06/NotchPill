import SwiftUI
import ServiceManagement

/// User-facing preferences, persisted in UserDefaults and observable by the UI.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    // MARK: - Collapsed preview chips

    @Published var showCollapsedActivity: Bool {
        didSet { defaults.set(showCollapsedActivity, forKey: Keys.showCollapsedActivity) }
    }
    @Published var showCollapsedMedia: Bool {
        didSet { defaults.set(showCollapsedMedia, forKey: Keys.showCollapsedMedia) }
    }
    @Published var showCollapsedAppSwitch: Bool {
        didSet { defaults.set(showCollapsedAppSwitch, forKey: Keys.showCollapsedAppSwitch) }
    }
    @Published var showCalendar: Bool {
        didSet { defaults.set(showCalendar, forKey: Keys.showCalendar) }
    }
    @Published var showFileShelf: Bool {
        didSet { defaults.set(showFileShelf, forKey: Keys.showFileShelf) }
    }
    @Published var showCollapsedTimer: Bool {
        didSet { defaults.set(showCollapsedTimer, forKey: Keys.showCollapsedTimer) }
    }
    @Published var showCollapsedSystemStats: Bool {
        didSet { defaults.set(showCollapsedSystemStats, forKey: Keys.showCollapsedSystemStats) }
    }
    @Published var showCollapsedBattery: Bool {
        didSet { defaults.set(showCollapsedBattery, forKey: Keys.showCollapsedBattery) }
    }
    @Published var showCollapsedClock: Bool {
        didSet { defaults.set(showCollapsedClock, forKey: Keys.showCollapsedClock) }
    }

    // MARK: - Expanded status cards

    @Published var showExpandedMedia: Bool {
        didSet { defaults.set(showExpandedMedia, forKey: Keys.showExpandedMedia) }
    }
    @Published var showExpandedActiveApp: Bool {
        didSet { defaults.set(showExpandedActiveApp, forKey: Keys.showExpandedActiveApp) }
    }
    @Published var showExpandedVolume: Bool {
        didSet { defaults.set(showExpandedVolume, forKey: Keys.showExpandedVolume) }
    }
    @Published var showExpandedClock: Bool {
        didSet { defaults.set(showExpandedClock, forKey: Keys.showExpandedClock) }
    }
    @Published var showExpandedCalendar: Bool {
        didSet { defaults.set(showExpandedCalendar, forKey: Keys.showExpandedCalendar) }
    }
    @Published var showExpandedTimer: Bool {
        didSet { defaults.set(showExpandedTimer, forKey: Keys.showExpandedTimer) }
    }
    @Published var showExpandedSystemStats: Bool {
        didSet { defaults.set(showExpandedSystemStats, forKey: Keys.showExpandedSystemStats) }
    }
    @Published var showExpandedBattery: Bool {
        didSet { defaults.set(showExpandedBattery, forKey: Keys.showExpandedBattery) }
    }
    @Published var showExpandedShelf: Bool {
        didSet { defaults.set(showExpandedShelf, forKey: Keys.showExpandedShelf) }
    }

    @Published var showDevReadyPings: Bool {
        didSet { defaults.set(showDevReadyPings, forKey: Keys.showDevReadyPings) }
    }
    @Published var devReadyDuration: Double {
        didSet { defaults.set(devReadyDuration, forKey: Keys.devReadyDuration) }
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }

    @Published var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)

    private enum Keys {
        static let showCollapsedActivity = "showCollapsedActivity"
        static let showCollapsedMedia = "showCollapsedMedia"
        static let showCollapsedAppSwitch = "showCollapsedAppSwitch"
        static let showCalendar = "showCalendar"
        static let showFileShelf = "showFileShelf"
        static let showCollapsedTimer = "showCollapsedTimer"
        static let showCollapsedSystemStats = "showCollapsedSystemStats"
        static let showCollapsedBattery = "showCollapsedBattery"
        static let showCollapsedClock = "showCollapsedClock"
        static let showExpandedMedia = "showExpandedMedia"
        static let showExpandedActiveApp = "showExpandedActiveApp"
        static let showExpandedVolume = "showExpandedVolume"
        static let showExpandedClock = "showExpandedClock"
        static let showExpandedCalendar = "showExpandedCalendar"
        static let showExpandedTimer = "showExpandedTimer"
        static let showExpandedSystemStats = "showExpandedSystemStats"
        static let showExpandedBattery = "showExpandedBattery"
        static let showExpandedShelf = "showExpandedShelf"
        static let showDevReadyPings = "showDevReadyPings"
        static let devReadyDuration = "devReadyDuration"
        static let autoCheckUpdates = "autoCheckUpdates"
    }

    private init() {
        defaults.register(defaults: [
            // Hover-only by default: the collapsed preview strip stays hidden
            // until you hover the notch. Users can turn it on in Settings.
            Keys.showCollapsedActivity: false,
            Keys.showCollapsedMedia: true,
            Keys.showCollapsedAppSwitch: true,
            Keys.showCalendar: true,
            Keys.showFileShelf: true,
            Keys.showCollapsedTimer: true,
            Keys.showCollapsedSystemStats: false,
            Keys.showCollapsedBattery: false,
            Keys.showCollapsedClock: true,
            Keys.showExpandedMedia: true,
            Keys.showExpandedActiveApp: true,
            Keys.showExpandedVolume: true,
            Keys.showExpandedClock: true,
            Keys.showExpandedCalendar: false,
            Keys.showExpandedTimer: true,
            Keys.showExpandedSystemStats: false,
            Keys.showExpandedBattery: false,
            Keys.showExpandedShelf: false,
            Keys.showDevReadyPings: true,
            Keys.devReadyDuration: 8.0,
            Keys.autoCheckUpdates: true,
        ])

        showCollapsedActivity = defaults.bool(forKey: Keys.showCollapsedActivity)
        showCollapsedMedia = defaults.bool(forKey: Keys.showCollapsedMedia)
        showCollapsedAppSwitch = defaults.bool(forKey: Keys.showCollapsedAppSwitch)
        showCalendar = defaults.bool(forKey: Keys.showCalendar)
        showFileShelf = defaults.bool(forKey: Keys.showFileShelf)
        showCollapsedTimer = defaults.bool(forKey: Keys.showCollapsedTimer)
        showCollapsedSystemStats = defaults.bool(forKey: Keys.showCollapsedSystemStats)
        showCollapsedBattery = defaults.bool(forKey: Keys.showCollapsedBattery)
        showCollapsedClock = defaults.bool(forKey: Keys.showCollapsedClock)
        showExpandedMedia = defaults.bool(forKey: Keys.showExpandedMedia)
        showExpandedActiveApp = defaults.bool(forKey: Keys.showExpandedActiveApp)
        showExpandedVolume = defaults.bool(forKey: Keys.showExpandedVolume)
        showExpandedClock = defaults.bool(forKey: Keys.showExpandedClock)
        showExpandedCalendar = defaults.bool(forKey: Keys.showExpandedCalendar)
        showExpandedTimer = defaults.bool(forKey: Keys.showExpandedTimer)
        showExpandedSystemStats = defaults.bool(forKey: Keys.showExpandedSystemStats)
        showExpandedBattery = defaults.bool(forKey: Keys.showExpandedBattery)
        showExpandedShelf = defaults.bool(forKey: Keys.showExpandedShelf)
        showDevReadyPings = defaults.object(forKey: Keys.showDevReadyPings) as? Bool ?? true
        let storedDuration = defaults.double(forKey: Keys.devReadyDuration)
        devReadyDuration = storedDuration > 0 ? storedDuration : 8.0
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
    }

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

    func resetToDefaults() {
        let defaultValues: [String: Any] = [
            Keys.showCollapsedActivity: false,
            Keys.showCollapsedMedia: true,
            Keys.showCollapsedAppSwitch: true,
            Keys.showCalendar: true,
            Keys.showFileShelf: true,
            Keys.showCollapsedTimer: true,
            Keys.showCollapsedSystemStats: false,
            Keys.showCollapsedBattery: false,
            Keys.showCollapsedClock: true,
            Keys.showExpandedMedia: true,
            Keys.showExpandedActiveApp: true,
            Keys.showExpandedVolume: true,
            Keys.showExpandedClock: true,
            Keys.showExpandedCalendar: false,
            Keys.showExpandedTimer: true,
            Keys.showExpandedSystemStats: false,
            Keys.showExpandedBattery: false,
            Keys.showExpandedShelf: false,
            Keys.showDevReadyPings: true,
            Keys.devReadyDuration: 8.0,
            Keys.autoCheckUpdates: true,
        ]
        defaultValues.forEach { defaults.set($0.value, forKey: $0.key) }
        showCollapsedActivity = false
        showCollapsedMedia = true
        showCollapsedAppSwitch = true
        showCalendar = true
        showFileShelf = true
        showCollapsedTimer = true
        showCollapsedSystemStats = false
        showCollapsedBattery = false
        showCollapsedClock = true
        showExpandedMedia = true
        showExpandedActiveApp = true
        showExpandedVolume = true
        showExpandedClock = true
        showExpandedCalendar = false
        showExpandedTimer = true
        showExpandedSystemStats = false
        showExpandedBattery = false
        showExpandedShelf = false
        showDevReadyPings = true
        devReadyDuration = 8.0
        autoCheckUpdates = true
    }
}
