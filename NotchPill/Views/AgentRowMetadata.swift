import Foundation

/// The one tertiary line under an agent row, as a value.
///
/// The row used to draw runtime and context on one line and model, effort and
/// permission mode scattered across two others, each with its own indent and
/// its own trailing edge. That is what made the card look crowded: three text
/// rows, three left edges, three right edges, per session.
///
/// Deciding *what* goes on the line is a content question, so it lives here
/// where it can be tested, and the view is left with only the drawing.
struct AgentRowMetadata: Equatable {
    /// Runtime, context, model, effort — whichever the session has, joined.
    /// Nil when it has none, so a short-lived row does not grow an empty line.
    let text: String?

    /// A session near its window is about to compact and lose the thread, so
    /// at that point the figure stops being trivia and is drawn like it matters.
    let isContextTight: Bool

    /// The permission mode, when it is surprising. `default` is the mode
    /// everyone assumes, so it draws nothing.
    let badge: String?

    /// True when the mode means the agent acts without asking. `plan` is the
    /// cautious end of the scale and is drawn calmly.
    let badgeIsWarning: Bool

    init(_ session: AgentSession) {
        // Runtime first: it is the one fact true of every session. Effort last:
        // it modifies the model beside it. A fixed order is what lets the eye
        // skip this line on the rows it does not care about.
        let parts = [session.runtimeLabel,
                     session.contextLabel,
                     session.modelBaseLabel,
                     session.effortLabel].compactMap { $0 }
        text = parts.isEmpty ? nil : parts.joined(separator: " · ")
        isContextTight = session.isContextTight
        badge = session.permissionLabel
        badgeIsWarning = session.isUnsupervised
    }
}
