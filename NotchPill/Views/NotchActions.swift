import Foundation

/// Transport actions the UI invokes, wired to the now-playing provider.
struct NotchActions {
    var togglePlayPause: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var focusApp: (String) -> Void
    /// Foreground an alert's actual host, with safe app-specific fallbacks for
    /// old hooks that did not carry a bundle identifier.
    var focusAlert: (DevReadyAlert) -> Void = { _ in }
    var dismissDevReady: (String) -> Void
    /// Explicit dismissal that also clears `.waiting` peeks, which never time out.
    var dismissPeek: (String) -> Void
    var beginReply: (DevReadyAlert) -> Void
    var sendReply: (DevReadyAlert, String) -> Void
    /// Open a feedback field that returns a plan for revision through the
    /// waiting PreToolUse hook, rather than typing into a terminal.
    var beginPlanRevision: (DevReadyAlert) -> Void
    var submitPlanRevision: (DevReadyAlert, String) -> Void
    var answer: (DevReadyAlert, AgentAnswer) -> Void
    var clearRecentActivity: () -> Void = {}
    /// Bring forward the app this agent session is running in.
    var focusAgentSession: (AgentSession) -> Void = { _ in }
    /// Open a URL (a CI run) in the default browser.
    var openURL: (String) -> Void = { _ in }

    static let noop = NotchActions(
        togglePlayPause: {}, next: {}, previous: {},
        focusApp: { _ in }, focusAlert: { _ in }, dismissDevReady: { _ in },
        dismissPeek: { _ in },
        beginReply: { _ in }, sendReply: { _, _ in },
        beginPlanRevision: { _ in }, submitPlanRevision: { _, _ in },
        answer: { _, _ in },
        clearRecentActivity: {},
        focusAgentSession: { _ in },
        openURL: { _ in }
    )
}
