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

    // The resolved collapsed-notch activity (crossfaded between).
    @Published private(set) var activity: NotchActivity = .idle

    // Tile data.
    @Published var nowPlaying: NowPlaying?
    @Published var nextEvent: CalendarEvent?
    /// Transient volume HUD level (0–100), nil when hidden.
    @Published private(set) var volumeLevel: Int? = nil
    // AirDrop is intentionally always nil: no reliable public API exists to read
    // live transfer state, and the spec requires omitting it rather than faking.
    @Published var airDrop: String? = nil

    // Debounce/coalesce window for activity resolution. Two events arriving
    // inside this window resolve to a single published activity.
    private let debounceInterval: TimeInterval = 0.18
    private var resolveWorkItem: DispatchWorkItem?
    private var appSwitchRevertItem: DispatchWorkItem?

    // Pending inputs the resolver reads when it fires.
    private var pendingAppSwitch: String?
    private var volumeHideItem: DispatchWorkItem?

    // MARK: - Hover

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
    }

    /// Shows the volume HUD briefly after a keyboard adjustment.
    func showVolume(_ level: Int) {
        volumeLevel = level
        volumeHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.volumeLevel = nil }
        volumeHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: item)
    }

    // MARK: - Event intake (debounced)

    /// A frontmost-application change. Shows a transient app-switch chip.
    func notifyAppSwitched(_ appName: String) {
        pendingAppSwitch = appName
        scheduleResolve()
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

    /// Picks the highest-priority activity from current inputs and publishes it
    /// once. SwiftUI animates the difference as a crossfade.
    private func resolve() {
        var candidates: [NotchActivity] = [.idle]

        if let np = nowPlaying, np.isPlaying, !np.isEmpty {
            candidates.append(.media(np))
        }
        if let app = pendingAppSwitch {
            candidates.append(.appSwitch(app))
            scheduleAppSwitchRevert()
            pendingAppSwitch = nil
        }

        let resolved = candidates.max { $0.priority < $1.priority } ?? .idle
        if resolved != activity {
            activity = resolved
        }
    }

    /// An app-switch chip is transient; after a short display it yields back to
    /// media/idle by re-resolving.
    private func scheduleAppSwitchRevert() {
        appSwitchRevertItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.resolve()
        }
        appSwitchRevertItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: item)
    }
}
