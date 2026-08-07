import Foundation

/// Decides whether a peek's fade timer is allowed to run.
///
/// A finished peek fades on a fixed timer, which is right for a glanceable
/// "agent done" ping and wrong for anything you have to *read*. Dictation
/// captions made that obvious: a long one arrives, you start reading, and the
/// text disappears mid-sentence with no way to get it back.
///
/// Two reasons to hold it open, deliberately kept separate:
///
/// - **Hover** is implicit and reversible. Your pointer is over the peek, so
///   you are presumably looking at it; move away and the normal timer resumes.
///   It costs nothing and needs no decision from you.
/// - **Pin** is explicit and sticky. It survives the pointer leaving, and only
///   an unpin or a dismissal clears it — for when you want to read something
///   while your hands are back on the keyboard.
///
/// Pure and value-typed so the interesting part (when the timer restarts) is
/// testable without a window, a pointer, or a run loop.
struct PeekHold: Equatable {
    private(set) var isHovered = false
    /// Pinning is per-alert: pinning a caption should not also freeze an
    /// unrelated agent ping that happens to be stacked with it.
    private(set) var pinnedIDs: Set<String> = []

    /// True while the fade timer must not run.
    var holdsPeek: Bool { isHovered || !pinnedIDs.isEmpty }

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    /// Returns true only when this changed whether the peek is held, so the
    /// caller can cancel or restart the timer exactly once per transition
    /// rather than on every tick of a polling hover loop.
    mutating func setHovered(_ hovered: Bool) -> Bool {
        guard hovered != isHovered else { return false }
        let before = holdsPeek
        isHovered = hovered
        return holdsPeek != before
    }

    /// Returns true when the hold changed. Toggling a pin while the pointer is
    /// still over the peek changes nothing yet — hover is already holding it —
    /// but it decides what happens the moment the pointer leaves.
    mutating func togglePin(_ id: String) -> Bool {
        let before = holdsPeek
        if pinnedIDs.contains(id) {
            pinnedIDs.remove(id)
        } else {
            pinnedIDs.insert(id)
        }
        return holdsPeek != before
    }

    /// Drop one alert's pin — it was dismissed, answered, or superseded. A pin
    /// that outlived its row would hold the peek open forever with nothing to
    /// unpin, which is the one way this feature could strand the UI.
    mutating func forget(_ id: String) -> Bool {
        guard pinnedIDs.contains(id) else { return false }
        let before = holdsPeek
        pinnedIDs.remove(id)
        return holdsPeek != before
    }

    /// Keep only pins whose rows still exist.
    mutating func retain(ids: Set<String>) -> Bool {
        let survivors = pinnedIDs.intersection(ids)
        guard survivors != pinnedIDs else { return false }
        let before = holdsPeek
        pinnedIDs = survivors
        return holdsPeek != before
    }

    /// The peek is gone. Hover is cleared too: the pointer may well still be
    /// sitting where the peek used to be, and a stale `isHovered` would hold
    /// the *next* peek open without the user hovering anything.
    mutating func reset() {
        isHovered = false
        pinnedIDs.removeAll()
    }
}
