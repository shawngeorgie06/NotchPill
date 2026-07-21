import AppKit
import Combine

/// The single source of truth for the overlay. Every content change — media
/// updates, frontmost-app switches, hover expand/collapse — is funnelled
/// through here. Rapid bursts of events are debounced and resolved by priority
/// so the UI renders exactly one crossfade per settled state, never a glitchy
/// double-render.
@MainActor
final class NotchState: ObservableObject {
    // Hover expansion.
    @Published private(set) var isExpanded = false

    // The resolved collapsed-notch activity (legacy primary chip for transitions).
    @Published private(set) var activity: NotchActivity = .idle

    /// Brief app-switch banner shown alongside other collapsed chips.
    @Published private(set) var appSwitchHint: String?

    /// The current frontmost app (persists after the switch banner clears).
    @Published private(set) var frontmostApp: String?
    @Published private(set) var frontmostAppIcon: NSImage?

    // Tile data.
    @Published var nowPlaying: NowPlaying?
    @Published var nextEvent: CalendarEvent?
    @Published private(set) var systemStats: SystemStats?
    @Published private(set) var battery: BatteryStatus?
    /// Last known system output volume (0–100).
    @Published private(set) var systemVolume: Int?
    /// Transient volume HUD level (0–100), nil when hidden.
    @Published private(set) var volumeLevel: Int? = nil
    /// Active dev-ready peeks (multiple agents can finish at once).
    @Published private(set) var devReadyAlerts: [DevReadyAlert] = []
    // AirDrop is intentionally always nil: no reliable public API exists to read
    // live transfer state, and the spec requires omitting it rather than faking.
    @Published var airDrop: String? = nil

    // Debounce/coalesce window for activity resolution. Two events arriving
    // inside this window resolve to a single published activity.
    private let debounceInterval: TimeInterval = 0.04
    private var resolveWorkItem: DispatchWorkItem?
    private var appSwitchRevertItem: DispatchWorkItem?

    // Pending inputs the resolver reads when it fires.
    private var volumeHideItem: DispatchWorkItem?

    // MARK: - Hover

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
    }

    func enqueueDevReady(_ alerts: [DevReadyAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            if let index = devReadyAlerts.firstIndex(where: { $0.id == alert.id }) {
                devReadyAlerts[index] = alert
            } else {
                devReadyAlerts.append(alert)
            }
        }
    }

    func removeDevReady(id: String) {
        devReadyAlerts.removeAll { $0.id == id }
    }

    func clearDevReady() {
        devReadyAlerts = []
    }

    /// Shows the volume HUD briefly after a keyboard adjustment.
    func showVolume(_ level: Int) {
        systemVolume = level
        volumeLevel = level
        volumeHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.volumeLevel = nil }
        volumeHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: item)
    }

    /// Updates the stored volume without flashing the HUD.
    func refreshSystemVolume(_ level: Int) {
        systemVolume = level
    }

    func updateSystemStats(_ stats: SystemStats?) {
        systemStats = stats
    }

    func updateBattery(_ status: BatteryStatus?) {
        battery = status
    }

    // MARK: - Event intake (debounced)

    /// A frontmost-application change. Shows a transient banner chip.
    func notifyAppSwitched(_ appName: String, icon: NSImage? = nil) {
        appSwitchHint = appName
        setFrontmostApp(appName, icon: icon)
        scheduleResolve()
        scheduleAppSwitchRevert()
    }

    func setFrontmostApp(_ appName: String, icon: NSImage? = nil) {
        frontmostApp = appName
        frontmostAppIcon = icon
    }

    /// Media metadata or playback state changed.
    func notifyMediaChanged(_ playing: NowPlaying?) {
        nowPlaying = playing
        scheduleResolve()
    }

    /// Coalesces bursts: the last event inside `debounceInterval` wins, and the
    /// resolver runs exactly once for the burst.
    private func scheduleResolve() {
        resolveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.resolve() }
        resolveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
    }

    /// Updates the primary collapsed activity used for crossfade transitions.
    private func resolve() {
        var resolved: NotchActivity = .idle
        if let np = nowPlaying, !np.isEmpty {
            resolved = .media(np)
        } else if let app = appSwitchHint {
            resolved = .appSwitch(app)
        }
        // Only crossfade when the activity *kind* changes — metadata updates use
        // `nowPlaying` directly and should not re-trigger the transition.
        if resolved.transitionKey != activity.transitionKey {
            activity = resolved
        }
    }

    /// Clears the transient app-switch banner and re-resolves activity.
    private func scheduleAppSwitchRevert() {
        appSwitchRevertItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.appSwitchHint = nil
            self.resolve()
        }
        appSwitchRevertItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }
}
