import Foundation

/// Transport actions the UI invokes, wired to the now-playing provider.
struct NotchActions {
    var togglePlayPause: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var focusApp: (String) -> Void
    var dismissDevReady: (String) -> Void
    var beginReply: (DevReadyAlert) -> Void
    var sendReply: (DevReadyAlert, String) -> Void

    static let noop = NotchActions(
        togglePlayPause: {}, next: {}, previous: {},
        focusApp: { _ in }, dismissDevReady: { _ in },
        beginReply: { _ in }, sendReply: { _, _ in }
    )
}
