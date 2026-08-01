import Foundation

/// One nudge about something you did not deal with.
///
/// A peek is on screen for a few seconds and then it is gone. That is the right
/// default — the notch is not a queue and a banner that will not leave is worse
/// than one that goes — but it means a request can pass while you are reading
/// something else and never come back. This has actually happened here: an
/// agent sat blocked on an approval while its peek came and went unanswered.
///
/// So: exactly one reminder, later, for things that timed out without you
/// touching them. Deliberately not a repeating alert. Something that pings
/// until you deal with it is a nag, and a nag gets ignored wholesale — which
/// would cost the peeks that *are* worth reading.
struct FollowUpReminder: Equatable {
    /// How long after a peek goes unattended the reminder is due.
    static let defaultDelay: TimeInterval = 300

    struct Pending: Equatable {
        var id: String
        var kind: AlertKind
        /// When the peek left the screen unattended.
        var since: Date
    }

    private(set) var pending: [Pending] = []
    /// Ids already reminded about, so a second nudge can never happen. Cleared
    /// only when the alert is attended to, which also removes it from pending.
    private(set) var reminded: Set<String> = []

    /// A peek left the screen without the user doing anything about it.
    ///
    /// Called only for timeouts. A peek you dismissed is one you *did* attend
    /// to — you looked at it and decided it was not for you — and reminding
    /// about it would be arguing with the user.
    mutating func recordUnattended(id: String, kind: AlertKind, at: Date) {
        guard !reminded.contains(id) else { return }
        guard !pending.contains(where: { $0.id == id }) else { return }
        pending.append(Pending(id: id, kind: kind, since: at))
    }

    /// The user answered, dismissed, or opened it. Nothing more is owed, and
    /// the id is forgotten entirely so a later peek reusing it starts clean.
    mutating func attended(id: String) {
        pending.removeAll { $0.id == id }
        reminded.remove(id)
    }

    /// Ids whose reminder is now due, marked as reminded on the way out.
    ///
    /// Marking here rather than at the call site means a caller that drops the
    /// result still cannot produce a second nudge. Losing one reminder is a
    /// smaller failure than repeating it forever.
    mutating func due(now: Date, delay: TimeInterval = defaultDelay) -> [Pending] {
        let ready = pending.filter { now.timeIntervalSince($0.since) >= delay }
        guard !ready.isEmpty else { return [] }
        pending.removeAll { item in ready.contains { $0.id == item.id } }
        reminded.formUnion(ready.map(\.id))
        return ready
    }

    /// Drops anything too old to be worth raising.
    ///
    /// A prompt from three hours ago has almost certainly been answered in the
    /// terminal, and the agent has moved on. Reminding you about it would be
    /// stating something false, which is worse than staying quiet.
    mutating func expire(now: Date, olderThan: TimeInterval = AgentSession.liveWindow) {
        pending.removeAll { now.timeIntervalSince($0.since) > olderThan }
    }

    /// How the reminder reads. It has to say it is a reminder — an identical
    /// second copy of a peek looks like the agent asked twice.
    static func title(for kind: AlertKind) -> String {
        kind == .waiting ? "Still waiting on you" : "You have not looked at this"
    }
}
