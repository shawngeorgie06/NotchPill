import AppKit
import Combine
import SwiftUI

/// The single source of truth for the overlay. Every content change — media
/// updates, frontmost-app switches, hover expand/collapse — is funnelled
/// through here. Rapid bursts of events are debounced and resolved by priority
/// so the UI renders exactly one crossfade per settled state, never a glitchy
/// double-render.
@MainActor
final class NotchState: ObservableObject {
    static let hoverAnimationDuration: TimeInterval = 0.28
    /// Notifications carry text and actions, so their entrance needs a touch
    /// more time than a hover surface to read as a deliberate motion.
    static let devReadyAnimationDuration: TimeInterval = 0.36
    /// Finished notifications are useful after their five-second peek fades,
    /// but a local history must not retain a raw permission payload or answer
    /// specification. The persisted form is intentionally presentation-only.
    static let notificationHistoryLimit = 12
    private static let notificationHistoryKey = "recentDevReadyNotificationHistory"
    // Hover expansion.
    @Published private(set) var isExpanded = false
    /// Keeps the larger SwiftUI tree alive for the last fraction of a second
    /// while it visibly shrinks. Unlike `isExpanded`, this must never keep the
    /// large hit target alive: a vanished island should not hold hover open.
    @Published private(set) var isCollapsing = false
    /// 0 is the physical notch; 1 is the fully expanded hover surface. Keeping
    /// this separate from `isExpanded` gives the renderer a real in-between
    /// state instead of swapping directly between two finished layouts.
    @Published private(set) var expansionProgress: CGFloat = 0
    /// The selected deck card is stored by kind rather than by position. Live
    /// data can insert a CI or media card ahead of it without taking someone
    /// who was reading Codex usage to an unrelated page.
    @Published private(set) var expandedDeckPage = 0
    @Published private(set) var expandedDeckKind: String?
    @Published private(set) var expandedDeckDirection = 1

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
    /// A short-lived copy used only while a notification contracts back into
    /// the notch. Removing the alert before rendering its exit previously made
    /// SwiftUI replace it with the dashboard for one frame.
    @Published private(set) var departingDevReadyAlerts: [DevReadyAlert] = []
    @Published private(set) var isDismissingDevReady = false
    @Published private(set) var devReadyPresentation: CGFloat = 0
    @Published private(set) var recentDevReadyAlerts: [DevReadyAlert] = []
    /// Agent conversations alive right now. Distinct from `devReadyAlerts`:
    /// those are events that fire once, this is a standing list.
    @Published var agentSessions: [AgentSession] = []
    /// Local OpenCode token/cost totals for today. This is not a quota value.
    @Published var openCodeUsage: OpenCodeUsage?
    /// Codex's own locally recorded current-window rate-limit signal.
    @Published var codexQuota: CodexQuota?
    @Published var claudeQuota: ClaudeQuota?
    @Published var cursorQuota: CursorQuota?
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
    private var collapseWorkItem: DispatchWorkItem?
    private var devReadyExitWorkItem: DispatchWorkItem?

    // Pending inputs the resolver reads when it fires.
    private var volumeHideItem: DispatchWorkItem?
    private var brightnessHideItem: DispatchWorkItem?
    private var microphoneHideItem: DispatchWorkItem?

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.notificationHistoryKey),
              let stored = try? JSONDecoder().decode([DevReadyAlert].self, from: data)
        else { return }
        recentDevReadyAlerts = Array(stored.filter { $0.kind == .finished }
            .sorted { ($0.createdAt ?? 0) > ($1.createdAt ?? 0) }
            .prefix(Self.notificationHistoryLimit))
    }

    // MARK: - Hover

    func setExpanded(_ expanded: Bool) {
        if expanded {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            isCollapsing = false
            // Re-entering during the closing animation reverses it from its
            // current visual state instead of snapping back open.
            if isExpanded {
                expansionProgress = 1
                return
            }
            // Publish the narrow notch first. The next main-loop turn lets the
            // renderer install the compact geometry before it grows outward.
            expansionProgress = 0
            isExpanded = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isExpanded else { return }
                self.expansionProgress = 1
            }
            return
        }
        guard isExpanded, collapseWorkItem == nil else { return }
        // Leave the expanded tree alive while its surface shrinks back into
        // the notch. Removing it immediately was the source of the abrupt
        // collapse users could see on hover exit.
        //
        // Crucially, `isExpanded` becomes false now. Hit testing keys off that
        // flag, so the invisible large card cannot keep itself open while this
        // short visual tail completes.
        isExpanded = false
        isCollapsing = true
        expansionProgress = 0
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.expansionProgress < 0.001 else { return }
            self.collapseWorkItem = nil
            self.isCollapsing = false
        }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverAnimationDuration, execute: item)
    }

    func resolvedExpandedDeckPage(for kinds: [String]) -> Int {
        guard !kinds.isEmpty else { return 0 }
        if let expandedDeckKind, let index = kinds.firstIndex(of: expandedDeckKind) {
            return index
        }
        return min(max(0, expandedDeckPage), kinds.count - 1)
    }

    func selectExpandedDeckPage(_ index: Int, kinds: [String]) {
        guard !kinds.isEmpty else {
            expandedDeckPage = 0
            expandedDeckKind = nil
            return
        }
        let current = resolvedExpandedDeckPage(for: kinds)
        let target = min(max(0, index), kinds.count - 1)
        expandedDeckDirection = target == current ? expandedDeckDirection : (target > current ? 1 : -1)
        expandedDeckPage = target
        expandedDeckKind = kinds[target]
    }

    func moveExpandedDeckPage(by offset: Int, kinds: [String]) {
        guard !kinds.isEmpty else {
            expandedDeckPage = 0
            expandedDeckKind = nil
            return
        }
        let current = resolvedExpandedDeckPage(for: kinds)
        let target = (current + offset % kinds.count + kinds.count) % kinds.count
        expandedDeckDirection = offset >= 0 ? 1 : -1
        expandedDeckPage = target
        expandedDeckKind = kinds[target]
    }

    func reconcileExpandedDeck(kinds: [String]) {
        guard !kinds.isEmpty else {
            expandedDeckPage = 0
            expandedDeckKind = nil
            return
        }
        let page = resolvedExpandedDeckPage(for: kinds)
        expandedDeckPage = page
        expandedDeckKind = kinds[page]
    }

    func enqueueDevReady(_ alerts: [DevReadyAlert]) {
        guard !alerts.isEmpty else { return }
        let wasEmpty = devReadyAlerts.isEmpty
        devReadyExitWorkItem?.cancel()
        departingDevReadyAlerts = []
        isDismissingDevReady = false
        for alert in alerts {
            if alert.kind == .finished {
                recentDevReadyAlerts.removeAll { $0.id == alert.id }
                recentDevReadyAlerts.insert(Self.historyEntry(for: alert), at: 0)
                recentDevReadyAlerts = Array(recentDevReadyAlerts.prefix(Self.notificationHistoryLimit))
                persistNotificationHistory()
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
        if wasEmpty, !devReadyAlerts.isEmpty { animateDevReadyIn() }
    }

    func clearRecentDevReady() {
        recentDevReadyAlerts = []
        UserDefaults.standard.removeObject(forKey: Self.notificationHistoryKey)
    }

    /// Removes fields that could invoke or describe a past agent prompt before
    /// saving it. A history entry can only reopen its source app.
    nonisolated static func historyEntry(for alert: DevReadyAlert) -> DevReadyAlert {
        DevReadyAlert(
            id: alert.id,
            title: alert.displayTitle,
            subtitle: alert.displaySubtitle,
            source: alert.source,
            agent: alert.agent,
            bundleId: alert.bundleId,
            kind: .finished,
            createdAt: alert.createdAt
        )
    }

    private func persistNotificationHistory() {
        guard let data = try? JSONEncoder().encode(recentDevReadyAlerts) else { return }
        UserDefaults.standard.set(data, forKey: Self.notificationHistoryKey)
    }

    /// Enqueues a "waiting" peek (an agent blocked on a permission/choice prompt).
    /// A re-notification for the same *session* replaces its prior waiting peek;
    /// other sessions coexist.
    ///
    /// The replace key is `DevReadyAlert.isSameSession`: the agent's own
    /// `sessionId` when the hook supplies one, else `bundleId` + project title.
    func enqueueWaiting(_ alert: DevReadyAlert) {
        let wasEmpty = devReadyAlerts.isEmpty
        devReadyExitWorkItem?.cancel()
        departingDevReadyAlerts = []
        isDismissingDevReady = false
        devReadyAlerts.removeAll { $0.kind == .waiting && $0.isSameSession(as: alert) }
        devReadyAlerts.append(alert)
        if wasEmpty { animateDevReadyIn() }
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

    /// The alerts that the overlay should draw. During an exit this is the
    /// departing snapshot rather than the now-empty live collection.
    var renderedDevReadyAlerts: [DevReadyAlert] {
        devReadyAlerts.isEmpty ? departingDevReadyAlerts : devReadyAlerts
    }

    func beginDevReadyDismissal() {
        guard !devReadyAlerts.isEmpty else { return }
        devReadyExitWorkItem?.cancel()
        departingDevReadyAlerts = devReadyAlerts
        isDismissingDevReady = true
        withAnimation(.timingCurve(0.22, 0.8, 0.2, 1,
                                   duration: Self.devReadyAnimationDuration)) {
            devReadyPresentation = 0
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.isDismissingDevReady else { return }
            self.departingDevReadyAlerts = []
            self.isDismissingDevReady = false
        }
        devReadyExitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.devReadyAnimationDuration, execute: item)
    }

    private func animateDevReadyIn() {
        devReadyPresentation = 0
        // One display turn first: the attached notch geometry has to be in the
        // hierarchy before changing progress, or SwiftUI coalesces both states
        // into a single full-sized notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self, !self.devReadyAlerts.isEmpty else { return }
            withAnimation(.timingCurve(0.22, 0.8, 0.2, 1,
                                       duration: Self.devReadyAnimationDuration)) {
                self.devReadyPresentation = 1
            }
        }
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
        mode == .planRevision
            ? "Tell Claude what to change before it starts."
            : targetAlert.replyContextText
    }
}
