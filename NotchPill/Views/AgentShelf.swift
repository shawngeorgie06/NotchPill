import Foundation

/// What the agents page says above its tiles, and where its one action goes.
///
/// The old card built the summary inline and hinted "tap to jump" at every
/// row. A shelf has one well, so choosing its target is a content decision
/// worth testing: the session blocked on you, else one that is working, else
/// the first — never nothing while there is a session to reach.
struct AgentShelf: Equatable {
    /// "1 needs you · 2 working". Nil when there is nothing to count, so an
    /// empty page does not grow an empty line.
    let caption: String?
    /// Where the jump well takes you.
    let jumpTarget: AgentSession?

    init(_ sessions: [AgentSession]) {
        let waiting = sessions.filter(\.isWaiting)
        let working = sessions.filter {
            if case .working = $0.state { return true }
            return false
        }
        let idle = sessions.filter {
            if case .idle = $0.state { return true }
            return false
        }
        let completed = sessions.filter(\.isCompleted)
        // Needs-you first because it is the one you act on; completed last
        // because it is history. A fixed order is what lets the eye skip the
        // line when nothing has changed.
        let parts = [
            waiting.isEmpty ? nil : "\(waiting.count) needs you",
            working.isEmpty ? nil : "\(working.count) working",
            idle.isEmpty ? nil : "\(idle.count) idle",
            completed.isEmpty ? nil : "\(completed.count) completed",
        ].compactMap { $0 }
        caption = parts.isEmpty ? nil : parts.joined(separator: " · ")
        jumpTarget = waiting.first ?? working.first ?? sessions.first
    }
}
