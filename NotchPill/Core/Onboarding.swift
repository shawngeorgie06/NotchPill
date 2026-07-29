import Foundation

/// The first-run walkthrough.
///
/// Installing NotchPill and *finding* what it does were two different things:
/// a new install lands on an empty-looking pill, with the live-agent card, the
/// CI card and the agent hooks all reachable only by opening a menu nobody had
/// a reason to open. This walks through the two grants that gate real features
/// and then shows what can go in the row.
///
/// Steps are never skipped when they are already satisfied — a step that
/// reports "already done" still teaches that the feature exists, which is the
/// whole point of a guide. It just doesn't ask for anything.
enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome
    case accessibility
    case agentHooks
    case cards
    case finish

    var title: String {
        switch self {
        case .welcome: return "Welcome to NotchPill"
        case .accessibility: return "Keyboard shortcuts"
        case .agentHooks: return "Coding agents"
        case .cards: return "What goes in the notch"
        case .finish: return "You're set"
        }
    }

    var detail: String {
        switch self {
        case .welcome:
            return "Hover your notch to expand it. Everything below is optional — "
                + "you can change all of it later from the menu bar icon."
        case .accessibility:
            return "macOS asks for Accessibility before an app can watch for key "
                + "presses. NotchPill uses it only for its own shortcuts — "
                + "without it the pill still works, you just have to hover."
        case .agentHooks:
            return "Claude Code, Codex and Cursor can tell the notch when they're "
                + "waiting on you, so a question reaches you without watching a "
                + "terminal. This writes hooks into their config files, backing up "
                + "what's already there."
        case .cards:
            return "The expanded row is yours. Pick what belongs in it and how big "
                + "the pill should be — drag the widths later in Settings."
        case .finish:
            return "NotchPill lives in the menu bar. Open it any time to change "
                + "cards, widths, or run this guide again."
        }
    }
}

/// Pure walk over the steps, so the ordering and the terminal conditions can be
/// tested without a window.
struct OnboardingFlow: Equatable, Sendable {
    private(set) var index: Int = 0
    let steps: [OnboardingStep]

    init(steps: [OnboardingStep] = OnboardingStep.allCases) {
        self.steps = steps.isEmpty ? [.finish] : steps
    }

    var current: OnboardingStep { steps[index] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index == steps.count - 1 }
    /// 0…1, for a progress bar. The first step is not "0% done" to the reader,
    /// but it is the honest value and the bar has to start somewhere.
    var progress: Double { Double(index) / Double(max(1, steps.count - 1)) }

    mutating func next() {
        if !isLast { index += 1 }
    }

    mutating func back() {
        if !isFirst { index -= 1 }
    }
}

enum Onboarding {
    /// Keyed on version rather than a bare bool so a future release can show
    /// the guide again for a genuinely new feature without resetting anything
    /// else the user has configured.
    static let completedVersionKey = "onboardingCompletedVersion"
    static let currentVersion = 1

    nonisolated static func shouldShow(completedVersion: Int) -> Bool {
        completedVersion < currentVersion
    }

    static var shouldShow: Bool {
        // A pre-existing install that never saw a guide has already found its
        // way around; only genuinely fresh installs get interrupted.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: completedVersionKey) == nil,
           defaults.bool(forKey: "didCompleteFirstLaunch") {
            markComplete()
            return false
        }
        return shouldShow(completedVersion: defaults.integer(forKey: completedVersionKey))
    }

    static func markComplete() {
        UserDefaults.standard.set(currentVersion, forKey: completedVersionKey)
        UserDefaults.standard.set(true, forKey: "didCompleteFirstLaunch")
    }
}
