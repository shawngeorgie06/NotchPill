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
    /// Transient display-brightness HUD level (0–100), nil when hidden.
    @Published private(set) var brightnessLevel: Int? = nil
    /// Transient default-microphone mute HUD, nil when hidden.
    @Published private(set) var microphoneMuted: Bool? = nil
    /// Active dev-ready peeks (multiple agents can finish at once).
    @Published private(set) var devReadyAlerts: [DevReadyAlert] = []
    @Published private(set) var recentDevReadyAlerts: [DevReadyAlert] = []
    /// Agent conversations alive right now. Distinct from `devReadyAlerts`:
    /// those are events that fire once, this is a standing list.
    @Published var agentSessions: [AgentSession] = []
    /// Local OpenCode token/cost totals for today. This is not a quota value.
    @Published var openCodeUsage: OpenCodeUsage?
    /// Codex's own locally recorded current-window rate-limit signal.
    @Published var codexQuota: CodexQuota?
    /// Claude Code's latest response usage, never an account quota.
    @Published var claudeCodeUsage: ClaudeCodeUsage?
    /// GitHub Actions runs for the repos those sessions are in.
    @Published var ciRuns: [CIRun] = []
    /// Active reply composer, non-nil while the user is typing a reply to a
    /// finished agent. nil = not composing.
    @Published private(set) var replyCompose: ReplyComposeState?
    /// Live in-app update progress, rendered as a bar in the notch when set.
    @Published var updateProgress: UpdateProgress?
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
    private var brightnessHideItem: DispatchWorkItem?
    private var microphoneHideItem: DispatchWorkItem?

    // MARK: - Hover

    func setExpanded(_ expanded: Bool) {
        guard isExpanded != expanded else { return }
        isExpanded = expanded
    }

    func enqueueDevReady(_ alerts: [DevReadyAlert]) {
        guard !alerts.isEmpty else { return }
        for alert in alerts {
            if alert.kind == .finished {
                recentDevReadyAlerts.removeAll { $0.id == alert.id }
                recentDevReadyAlerts.insert(alert, at: 0)
                recentDevReadyAlerts = Array(recentDevReadyAlerts.prefix(3))
            }
            // A finished ping means that session is no longer blocked, so it
            // supersedes that session's waiting peek. Without this, waiting peeks
            // (which deliberately never auto-dismiss) would outlive the question:
            // the answer buttons would sit there offering to type `y` into a
            // terminal that has already moved on.
            if alert.kind == .finished {
                devReadyAlerts.removeAll { $0.kind == .waiting && $0.isSameSession(as: alert) }
            }
            if let index = devReadyAlerts.firstIndex(where: { $0.id == alert.id }) {
                devReadyAlerts[index] = alert
            } else {
                devReadyAlerts.append(alert)
            }
        }
    }

    func clearRecentDevReady() {
        recentDevReadyAlerts = []
    }

    /// Enqueues a "waiting" peek (an agent blocked on a permission/choice prompt).
    /// A re-notification for the same *session* replaces its prior waiting peek;
    /// other sessions coexist.
    ///
    /// The replace key is `DevReadyAlert.isSameSession`: the agent's own
    /// `sessionId` when the hook supplies one, else `bundleId` + project title.
    func enqueueWaiting(_ alert: DevReadyAlert) {
        devReadyAlerts.removeAll { $0.kind == .waiting && $0.isSameSession(as: alert) }
        devReadyAlerts.append(alert)
    }

    func removeDevReady(id: String) {
        devReadyAlerts.removeAll { $0.id == id }
    }

    /// Drops only `.finished` peeks, leaving `.waiting` peeks in place. The
    /// finished auto-dismiss timer uses this so a finished ping from terminal B
    /// can never erase terminal A's still-blocked question.
    func clearFinishedDevReady() {
        devReadyAlerts.removeAll { $0.kind == .finished }
    }

    /// Demotes on-screen `.waiting` peeks that have aged past the stale window to
    /// `.finished`, dropping their answer buttons. The ingest-time check can't
    /// cover this: a waiting peek never fades, so the one on screen is exactly the
    /// thing that can sit there for hours while the terminal moves on.
    /// Returns true if anything changed.
    @discardableResult
    func demoteStaleWaiting(now: Date = Date()) -> Bool {
        let updated = devReadyAlerts.map { DevReadyProvider.demotingStaleWaiting($0, now: now) }
        guard updated != devReadyAlerts else { return false }
        devReadyAlerts = updated
        return true
    }

    /// Drops every peek including `.waiting`. Only for *explicit* user dismissal
    /// (the ✕ button or Escape) — a `.waiting` peek doesn't time out, so this is
    /// the user's way to say "I dealt with it, go away."
    func clearAllDevReady() {
        devReadyAlerts = []
    }

    /// Shows the volume HUD briefly after a keyboard adjustment.
    func showVolume(_ level: Int) {
        systemVolume = level
        volumeLevel = level
        volumeHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.volumeLevel = nil }
        volumeHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.systemHUDDuration, execute: item)
    }

    /// Updates the stored volume without flashing the HUD.
    func refreshSystemVolume(_ level: Int) {
        systemVolume = level
    }

    /// Shows the built-in display's brightness briefly after macOS changes it.
    func showBrightness(_ level: Int) {
        brightnessLevel = level
        brightnessHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.brightnessLevel = nil }
        brightnessHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.systemHUDDuration, execute: item)
    }

    /// Shows whether the current default microphone was muted or unmuted.
    func showMicrophoneMuted(_ muted: Bool) {
        microphoneMuted = muted
        microphoneHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.microphoneMuted = nil }
        microphoneHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.shared.systemHUDDuration, execute: item)
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

    // MARK: - Reply compose

    func beginReply(to alert: DevReadyAlert) {
        replyCompose = ReplyComposeState(targetAlert: alert)
    }

    func beginPlanRevision(for alert: DevReadyAlert) {
        replyCompose = ReplyComposeState(targetAlert: alert, mode: .planRevision)
    }

    func updateReplyDraft(_ text: String) {
        guard replyCompose != nil else { return }
        replyCompose?.draft = text
        replyCompose?.errorText = nil
    }

    func setReplyError(_ message: String) {
        guard replyCompose != nil else { return }
        replyCompose?.errorText = message
    }

    func cancelReply() {
        replyCompose = nil
    }
}

/// The in-notch reply composer's state: which agent it targets and the draft.
struct ReplyComposeState: Equatable {
    enum Mode: Equatable { case reply, planRevision }

    var targetAlert: DevReadyAlert
    var mode: Mode = .reply
    var draft: String = ""
    var errorText: String? = nil

    var contextText: String? {
        mode == .planRevision ? "Tell Claude what to change before it starts." : targetAlert.questionText
    }
}
