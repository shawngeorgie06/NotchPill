import SwiftUI
import ServiceManagement

/// Curated native alert voices. These are intentionally named by feel rather
/// than copied from another app's sound pack; users can preview each one in
/// Settings before it becomes their agent-completion cue.
enum DevReadySound: String, CaseIterable, Identifiable {
    case glass = "Glass"
    case ping = "Ping"
    case pop = "Pop"
    case basso = "Basso"
    case funk = "Funk"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .glass: return "Glass · clear"
        case .ping: return "Ping · light"
        case .pop: return "Pop · quick"
        case .basso: return "Basso · low"
        case .funk: return "Funk · playful"
        }
    }
}

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
    @Published var showCollapsedAgents: Bool {
        didSet { defaults.set(showCollapsedAgents, forKey: Keys.showCollapsedAgents) }
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
    /// Off by default: a clipboard holds passwords and tokens, so remembering
    /// them is something to opt into, never something that just starts.
    @Published var showClipboard: Bool {
        didSet { defaults.set(showClipboard, forKey: Keys.showClipboard) }
    }

    @Published var showExpandedShelf: Bool {
        didSet { defaults.set(showExpandedShelf, forKey: Keys.showExpandedShelf) }
    }
    @Published var showExpandedAgents: Bool {
        didSet { defaults.set(showExpandedAgents, forKey: Keys.showExpandedAgents) }
    }
    /// Claude usage card. **Off by default, deliberately.** Reading the token
    /// means reading the login Keychain, which raises a macOS consent prompt —
    /// an app that asks for that unbidden, for a card nobody requested, has
    /// earned the suspicion it gets. Turning this on is the consent.
    @Published var showClaudeUsage: Bool {
        didSet { defaults.set(showClaudeUsage, forKey: Keys.showClaudeUsage) }
    }

    /// Cursor's included-usage figure. Cheaper to justify than the Claude
    /// card — the token is in a file, so nothing prompts — but it is still a
    /// network call about your account, so it stays opt-in for symmetry.
    @Published var showCursorUsage: Bool {
        didSet { defaults.set(showCursorUsage, forKey: Keys.showCursorUsage) }
    }

    /// After a reply is delivered, hand focus back to whatever you were
    /// looking at. The agent's terminal has to come forward to receive the
    /// text either way — this decides whether you stay there afterwards.
    ///
    /// **On by default.** Replying from an overlay is something you do
    /// *without* leaving what you were in; being dropped into a terminal you
    /// did not ask to visit is the surprise, not the other way round. Tested
    /// by someone who asked for this within minutes of the first reply landing
    /// them somewhere they did not want to be.
    @Published var returnFocusAfterReply: Bool {
        didSet { defaults.set(returnFocusAfterReply, forKey: Keys.returnFocusAfterReply) }
    }

    @Published var showExpandedCI: Bool {
        didSet { defaults.set(showExpandedCI, forKey: Keys.showExpandedCI) }
    }
    @Published var showExpandedRecentActivity: Bool {
        didSet { defaults.set(showExpandedRecentActivity, forKey: Keys.showExpandedRecentActivity) }
    }
    /// A card kind that stays first in the expanded activity deck. Empty means
    /// the automatic, attention-based ordering.
    @Published var pinnedActivityKind: String {
        didSet { defaults.set(pinnedActivityKind, forKey: Keys.pinnedActivityKind) }
    }
    /// How much of the row each card gets, relative to the others. 1.0 is an
    /// equal share; a card at 2.0 takes twice the width of one at 1.0. Stored
    /// per card kind so it survives cards coming and going.
    @Published var cardWeights: [String: Double] {
        didSet { defaults.set(cardWeights, forKey: Keys.cardWeights) }
    }

    nonisolated static let cardWeightRange: ClosedRange<Double> = 0.4...3.0

    /// Not every card wants an equal share out of the box. CI is three short
    /// rows of "repo — passed"; at an equal split it took half the row to say
    /// very little, and the first thing anyone does is drag it back down. The
    /// agents card is the opposite — it holds a task line per session and is
    /// the one people lean on — so it starts wider.
    ///
    /// This is only the starting point: an explicit weight in `cardWeights`
    /// always wins, so changing a default never moves a row someone has
    /// already arranged.
    nonisolated static func defaultWeight(for kind: String) -> Double {
        switch kind {
        case "ci": return 0.7
        case "agents": return 1.6
        default: return 1.0
        }
    }

    func cardWeight(_ kind: String) -> Double {
        AppSettings.clampWeight(cardWeights[kind] ?? AppSettings.defaultWeight(for: kind))
    }

    func setCardWeight(_ kind: String, _ value: Double) {
        cardWeights[kind] = AppSettings.clampWeight(value)
    }

    /// A zero or negative weight would divide the row by nothing and collapse
    /// every card, so the range is enforced on the way in.
    nonisolated static func clampWeight(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, cardWeightRange.lowerBound), cardWeightRange.upperBound)
    }

    /// Shares of the row, normalised to sum to 1. Kept pure so the split can be
    /// tested without a layout pass.
    nonisolated static func shares(for kinds: [String],
                                   weights: [String: Double]) -> [String: Double] {
        guard !kinds.isEmpty else { return [:] }
        let resolved = kinds.map {
            (kind: $0, w: clampWeight(weights[$0] ?? defaultWeight(for: $0)))
        }
        let total = resolved.reduce(0) { $0 + $1.w }
        guard total > 0 else {
            let equal = 1.0 / Double(kinds.count)
            return Dictionary(uniqueKeysWithValues: kinds.map { ($0, equal) })
        }
        var out: [String: Double] = [:]
        for item in resolved { out[item.kind] = item.w / total }
        return out
    }
    /// User size for the expanded pill, as a multiplier on the design scale.
    /// Clamped on write so a hand-edited plist cannot produce a pill that is
    /// invisible or wider than the screen.
    /// Which display the pill lives on.
    ///
    /// Stored as the raw value of `NotchGeometry.DisplayMode`. Defaults to
    /// falling back to an external display, which changes nothing while the lid
    /// is open and gives a docked Mac a pill where it previously had none.
    /// Show tokens used on the Claude and Codex cards.
    @Published var showTokenUsage: Bool {
        didSet { defaults.set(showTokenUsage, forKey: Keys.showTokenUsage) }
    }

    /// How far back those figures reach. Raw value of `TokenUsagePeriod`.
    @Published var tokenUsagePeriod: String {
        didSet { defaults.set(tokenUsagePeriod, forKey: Keys.tokenUsagePeriod) }
    }

    var resolvedTokenPeriod: TokenUsagePeriod {
        TokenUsagePeriod(rawValue: tokenUsagePeriod) ?? .today
    }

    @Published var notchDisplayMode: String {
        didSet { defaults.set(notchDisplayMode, forKey: Keys.notchDisplayMode) }
    }

    var resolvedDisplayMode: NotchGeometry.DisplayMode {
        NotchGeometry.DisplayMode(rawValue: notchDisplayMode) ?? .builtInThenExternal
    }

    @Published var notchScale: Double {
        didSet {
            let clamped = AppSettings.clampNotchScale(notchScale)
            if clamped != notchScale { notchScale = clamped; return }
            defaults.set(notchScale, forKey: Keys.notchScale)
        }
    }

    /// Chosen by using it, not by picking a round number: 100% wasted space,
    /// and the type compensation plus the wider hover slack mean 75% is no
    /// harder to read or to hit.
    nonisolated static let defaultNotchScale: Double = 0.75
    /// A completed-agent ping should be glanceable, not a lingering banner.
    /// Waiting approval prompts deliberately use a separate, non-dismissing
    /// lifecycle so an agent cannot be stranded after this interval.
    nonisolated static let defaultDevReadyDuration: Double = 4.0
    nonisolated static let notchScaleRange: ClosedRange<Double> = 0.7...1.3

    /// How much room a dictated caption may take.
    ///
    /// Separate from `notchScale`, which sizes the whole pill including the
    /// hover cards. This scales only the ceiling a wrapping caption is allowed
    /// to grow into, because the right answer is personal: how much you want to
    /// read before pasting depends on how long you speak and how much screen
    /// you are willing to give a transient overlay.
    nonisolated static let captionScaleRange: ClosedRange<Double> = 0.6...2.0
    nonisolated static func clampCaptionScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, captionScaleRange.lowerBound), captionScaleRange.upperBound)
    }
    /// `nonisolated` so the clamp can be tested without hopping to the main actor.
    nonisolated static func clampNotchScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1.0 }
        return min(max(value, notchScaleRange.lowerBound), notchScaleRange.upperBound)
    }

    @Published var showDevReadyPings: Bool {
        didSet { defaults.set(showDevReadyPings, forKey: Keys.showDevReadyPings) }
    }
    /// Keeps a copy of the log on disk so a problem can be reported after the
    /// fact instead of reproduced on demand. Off by default: the in-memory log
    /// is a deliberate privacy choice, and this is the user's decision to
    /// reverse, not ours. Turning it off also deletes what was written.
    /// Multiplier on the caption peek's width and line ceilings (1.0 = default).
    @Published var captionScale: Double {
        didSet {
            let clamped = AppSettings.clampCaptionScale(captionScale)
            if clamped != captionScale { captionScale = clamped; return }
            defaults.set(captionScale, forKey: Keys.captionScale)
        }
    }

    @Published var persistLog: Bool {
        didSet {
            defaults.set(persistLog, forKey: Keys.persistLog)
            if !persistLog { LogFile.clear() }
        }
    }
    @Published var devReadyDuration: Double {
        didSet { defaults.set(devReadyDuration, forKey: Keys.devReadyDuration) }
    }
    @Published var devReadyPlaySound: Bool {
        didSet { defaults.set(devReadyPlaySound, forKey: Keys.devReadyPlaySound) }
    }
    @Published var devReadySound: String {
        didSet { defaults.set(devReadySound, forKey: Keys.devReadySound) }
    }
    /// Each system HUD is separately opt-in. The providers may continue to
    /// observe their public system state, but no visual interruption is shown
    /// unless the corresponding HUD is enabled.
    @Published var showVolumeHUD: Bool {
        didSet { defaults.set(showVolumeHUD, forKey: Keys.showVolumeHUD) }
    }
    @Published var showBrightnessHUD: Bool {
        didSet { defaults.set(showBrightnessHUD, forKey: Keys.showBrightnessHUD) }
    }
    @Published var showMicrophoneHUD: Bool {
        didSet { defaults.set(showMicrophoneHUD, forKey: Keys.showMicrophoneHUD) }
    }
    /// How long a system HUD remains visible after its state changes.
    @Published var systemHUDDuration: Double {
        didSet {
            let clamped = AppSettings.clampSystemHUDDuration(systemHUDDuration)
            if clamped != systemHUDDuration { systemHUDDuration = clamped; return }
            defaults.set(systemHUDDuration, forKey: Keys.systemHUDDuration)
        }
    }
    nonisolated static let systemHUDDurationRange: ClosedRange<Double> = 0.8...3.0
    nonisolated static func clampSystemHUDDuration(_ value: Double) -> Double {
        guard value.isFinite else { return 1.4 }
        return min(max(value, systemHUDDurationRange.lowerBound), systemHUDDurationRange.upperBound)
    }
    @Published var autoCheckUpdates: Bool {
        didSet { defaults.set(autoCheckUpdates, forKey: Keys.autoCheckUpdates) }
    }
    /// Watch Claude Code / Codex transcripts so finished peeks work with no
    /// hooks installed. On by default: NotchPill should do something useful the
    /// moment it is installed, not after a setup step.
    @Published var watchAgentTranscripts: Bool {
        didSet { defaults.set(watchAgentTranscripts, forKey: Keys.watchAgentTranscripts) }
    }

    @Published var agentReplyEnabled: Bool {
        didSet { defaults.set(agentReplyEnabled, forKey: Keys.agentReplyEnabled) }
    }

    /// Backed by `~/.notchpill/approvals-enabled` rather than UserDefaults —
    /// the shell hook that reads it cannot read defaults. See `ApprovalGate`.
    /// Hold peeks and sounds while the Mac is locked or another user is on
    /// the console. On by default: a peek nobody can see is spent for nothing.
    @Published var quietWhenLocked: Bool {
        didSet { defaults.set(quietWhenLocked, forKey: Keys.quietWhenLocked) }
    }

    /// One nudge about a request you never answered. Off by default: it is an
    /// extra interruption, and the peek already had its turn.
    @Published var followUpReminders: Bool {
        didSet { defaults.set(followUpReminders, forKey: Keys.followUpReminders) }
    }

    @Published var agentApprovalsEnabled: Bool {
        didSet {
            do {
                try ApprovalGate.setEnabled(agentApprovalsEnabled)
            } catch {
                LogStore.log("permission",
                             "could not turn approvals \(agentApprovalsEnabled ? "on" : "off"): \(error)",
                             level: .warn)
            }
        }
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
        static let showCollapsedAgents = "showCollapsedAgents"
        static let showExpandedMedia = "showExpandedMedia"
        static let showExpandedActiveApp = "showExpandedActiveApp"
        static let showExpandedVolume = "showExpandedVolume"
        static let showExpandedClock = "showExpandedClock"
        static let showExpandedCalendar = "showExpandedCalendar"
        static let showExpandedTimer = "showExpandedTimer"
        static let showExpandedSystemStats = "showExpandedSystemStats"
        static let showExpandedBattery = "showExpandedBattery"
        static let showExpandedShelf = "showExpandedShelf"
        static let showClipboard = "showClipboard"
        static let showExpandedAgents = "showExpandedAgents"
        static let showExpandedCI = "showExpandedCI"
        static let showClaudeUsage = "showClaudeUsage"
        static let showCursorUsage = "showCursorUsage"
        static let returnFocusAfterReply = "returnFocusAfterReply"
        static let showExpandedRecentActivity = "showExpandedRecentActivity"
        static let pinnedActivityKind = "pinnedActivityKind"
        static let cardWeights = "cardWeights"
        static let notchScale = "notchScale"
        static let notchDisplayMode = "notchDisplayMode"
        static let showTokenUsage = "showTokenUsage"
        static let tokenUsagePeriod = "tokenUsagePeriod"
        static let showDevReadyPings = "showDevReadyPings"
        static let persistLog = "persistLog"
        static let captionScale = "captionScale"
        static let devReadyDuration = "devReadyDuration"
        static let devReadyPlaySound = "devReadyPlaySound"
        static let devReadySound = "devReadySound"
        static let followUpReminders = "followUpReminders"
        static let quietWhenLocked = "quietWhenLocked"
        static let showVolumeHUD = "showVolumeHUD"
        static let showBrightnessHUD = "showBrightnessHUD"
        static let showMicrophoneHUD = "showMicrophoneHUD"
        static let systemHUDDuration = "systemHUDDuration"
        static let autoCheckUpdates = "autoCheckUpdates"
        static let agentReplyEnabled = "agentReplyEnabled"
        static let watchAgentTranscripts = "watchAgentTranscripts"
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
            Keys.showCollapsedAgents: true,
            Keys.showExpandedMedia: true,
            Keys.showExpandedActiveApp: true,
            Keys.showExpandedVolume: true,
            Keys.showExpandedClock: true,
            Keys.showExpandedCalendar: false,
            Keys.showExpandedTimer: true,
            Keys.showExpandedSystemStats: false,
            Keys.showExpandedBattery: false,
            Keys.showExpandedShelf: true,
            Keys.showClipboard: false,
            Keys.showExpandedAgents: true,
            Keys.showExpandedCI: true,
            Keys.showClaudeUsage: false,
            Keys.showCursorUsage: false,
            Keys.returnFocusAfterReply: true,
            Keys.showExpandedRecentActivity: false,
            Keys.pinnedActivityKind: "",
            Keys.notchScale: AppSettings.defaultNotchScale,
            Keys.notchDisplayMode: NotchGeometry.DisplayMode.builtInThenExternal.rawValue,
            Keys.showTokenUsage: false,
            Keys.tokenUsagePeriod: TokenUsagePeriod.today.rawValue,
            Keys.showDevReadyPings: true,
            Keys.persistLog: false,
            Keys.captionScale: 1.0,
            Keys.devReadyDuration: AppSettings.defaultDevReadyDuration,
            Keys.devReadyPlaySound: true,
            Keys.devReadySound: DevReadySound.glass.rawValue,
            Keys.showVolumeHUD: true,
            Keys.showBrightnessHUD: true,
            Keys.showMicrophoneHUD: true,
            Keys.systemHUDDuration: 1.4,
            Keys.autoCheckUpdates: true,
            Keys.agentReplyEnabled: true,
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
        showCollapsedAgents = defaults.object(forKey: Keys.showCollapsedAgents) as? Bool ?? true
        showExpandedMedia = defaults.bool(forKey: Keys.showExpandedMedia)
        showExpandedActiveApp = defaults.bool(forKey: Keys.showExpandedActiveApp)
        showExpandedVolume = defaults.bool(forKey: Keys.showExpandedVolume)
        showExpandedClock = defaults.bool(forKey: Keys.showExpandedClock)
        showExpandedCalendar = defaults.bool(forKey: Keys.showExpandedCalendar)
        showExpandedTimer = defaults.bool(forKey: Keys.showExpandedTimer)
        showExpandedSystemStats = defaults.bool(forKey: Keys.showExpandedSystemStats)
        showExpandedBattery = defaults.bool(forKey: Keys.showExpandedBattery)
        showExpandedShelf = defaults.bool(forKey: Keys.showExpandedShelf)
        showClipboard = defaults.bool(forKey: Keys.showClipboard)
        showExpandedAgents = defaults.bool(forKey: Keys.showExpandedAgents)
        showExpandedCI = defaults.bool(forKey: Keys.showExpandedCI)
        showClaudeUsage = defaults.bool(forKey: Keys.showClaudeUsage)
        showCursorUsage = defaults.bool(forKey: Keys.showCursorUsage)
        returnFocusAfterReply = defaults.bool(forKey: Keys.returnFocusAfterReply)
        showExpandedRecentActivity = defaults.bool(forKey: Keys.showExpandedRecentActivity)
        pinnedActivityKind = defaults.string(forKey: Keys.pinnedActivityKind) ?? ""
        cardWeights = (defaults.dictionary(forKey: Keys.cardWeights) as? [String: Double]) ?? [:]
        notchScale = AppSettings.clampNotchScale(defaults.double(forKey: Keys.notchScale))
        notchDisplayMode = defaults.string(forKey: Keys.notchDisplayMode)
            ?? NotchGeometry.DisplayMode.builtInThenExternal.rawValue
        showTokenUsage = defaults.bool(forKey: Keys.showTokenUsage)
        tokenUsagePeriod = defaults.string(forKey: Keys.tokenUsagePeriod)
            ?? TokenUsagePeriod.today.rawValue
        showDevReadyPings = defaults.object(forKey: Keys.showDevReadyPings) as? Bool ?? true
        persistLog = defaults.object(forKey: Keys.persistLog) as? Bool ?? false
        let storedCaptionScale = defaults.double(forKey: Keys.captionScale)
        captionScale = storedCaptionScale > 0
            ? AppSettings.clampCaptionScale(storedCaptionScale) : 1.0
        let storedDuration = defaults.double(forKey: Keys.devReadyDuration)
        devReadyDuration = storedDuration > 0 ? storedDuration : AppSettings.defaultDevReadyDuration
        devReadyPlaySound = defaults.object(forKey: Keys.devReadyPlaySound) as? Bool ?? true
        let storedSound = defaults.string(forKey: Keys.devReadySound) ?? DevReadySound.glass.rawValue
        devReadySound = DevReadySound(rawValue: storedSound)?.rawValue ?? DevReadySound.glass.rawValue
        showVolumeHUD = defaults.object(forKey: Keys.showVolumeHUD) as? Bool ?? true
        showBrightnessHUD = defaults.object(forKey: Keys.showBrightnessHUD) as? Bool ?? true
        showMicrophoneHUD = defaults.object(forKey: Keys.showMicrophoneHUD) as? Bool ?? true
        systemHUDDuration = AppSettings.clampSystemHUDDuration(defaults.object(forKey: Keys.systemHUDDuration) as? Double ?? 1.4)
        autoCheckUpdates = defaults.object(forKey: Keys.autoCheckUpdates) as? Bool ?? true
        agentReplyEnabled = defaults.object(forKey: Keys.agentReplyEnabled) as? Bool ?? true
        watchAgentTranscripts = defaults.object(forKey: Keys.watchAgentTranscripts) as? Bool ?? true
        followUpReminders = defaults.object(forKey: Keys.followUpReminders) as? Bool ?? false
        quietWhenLocked = defaults.object(forKey: Keys.quietWhenLocked) as? Bool ?? true
        agentApprovalsEnabled = ApprovalGate.isEnabled()
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
            Keys.showCollapsedAgents: true,
            Keys.showExpandedMedia: true,
            Keys.showExpandedActiveApp: true,
            Keys.showExpandedVolume: true,
            Keys.showExpandedClock: true,
            Keys.showExpandedCalendar: false,
            Keys.showExpandedTimer: true,
            Keys.showExpandedSystemStats: false,
            Keys.showExpandedBattery: false,
            Keys.showExpandedShelf: true,
            Keys.showClipboard: false,
            Keys.showExpandedAgents: true,
            Keys.showExpandedCI: true,
            Keys.showExpandedRecentActivity: false,
            Keys.pinnedActivityKind: "",
            Keys.notchScale: AppSettings.defaultNotchScale,
            Keys.notchDisplayMode: NotchGeometry.DisplayMode.builtInThenExternal.rawValue,
            Keys.showTokenUsage: false,
            Keys.tokenUsagePeriod: TokenUsagePeriod.today.rawValue,
            Keys.showDevReadyPings: true,
            Keys.persistLog: false,
            Keys.captionScale: 1.0,
            Keys.devReadyDuration: AppSettings.defaultDevReadyDuration,
            Keys.devReadyPlaySound: true,
            Keys.devReadySound: DevReadySound.glass.rawValue,
            Keys.showVolumeHUD: true,
            Keys.showBrightnessHUD: true,
            Keys.showMicrophoneHUD: true,
            Keys.systemHUDDuration: 1.4,
            Keys.autoCheckUpdates: true,
            Keys.agentReplyEnabled: true,
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
        showCollapsedAgents = true
        showExpandedMedia = true
        showExpandedActiveApp = true
        showExpandedVolume = true
        showExpandedClock = true
        showExpandedCalendar = false
        showExpandedTimer = true
        showExpandedSystemStats = false
        showExpandedBattery = false
        showExpandedShelf = true
        showExpandedAgents = true
        showExpandedCI = true
        showExpandedRecentActivity = false
        // Both off on reset. These are the only cards that read an account over
        // the network, so "back to defaults" has to mean they stop.
        showClaudeUsage = false
        showCursorUsage = false
        returnFocusAfterReply = true
        pinnedActivityKind = ""
        cardWeights = [:]
        notchScale = AppSettings.defaultNotchScale
        showDevReadyPings = true
        devReadyDuration = AppSettings.defaultDevReadyDuration
        devReadyPlaySound = true
        devReadySound = DevReadySound.glass.rawValue
        showVolumeHUD = true
        showBrightnessHUD = true
        showMicrophoneHUD = true
        systemHUDDuration = 1.4
        autoCheckUpdates = true
        agentReplyEnabled = true
        watchAgentTranscripts = true
        // Off is the shipped default, and unlike everything above this one
        // reaches the filesystem: it removes ~/.notchpill/approvals-enabled.
        followUpReminders = false
        quietWhenLocked = true
        agentApprovalsEnabled = false
    }
}
