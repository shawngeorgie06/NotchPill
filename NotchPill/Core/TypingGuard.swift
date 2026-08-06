import Foundation

/// Keeps the notch's Space/arrow shortcuts away from someone who is typing.
///
/// The hot-zone shortcuts are captured with a `CGEvent` tap, which means that
/// when they fire the key is *swallowed* — it never reaches the focused app.
/// That is correct for a deliberate hover, and disastrous for the same keys
/// pressed mid-sentence: the space bar stops working in the terminal and the
/// only cure is waiting for the peek to fade.
///
/// `ShortcutArming` already tried to prevent this by treating pointer movement
/// as consent, and it is not enough. It arms on *any* movement inside the zone
/// and stays armed until the pointer leaves — and on a laptop, palms brushing
/// the trackpad produce that movement continuously while you type. A peek that
/// grows under a parked pointer re-arms within a keystroke or two and then
/// eats every space until it fades. That is the reported bug.
///
/// So this adds the signal that was missing, and it is the least ambiguous one
/// available: what the user just typed. Nobody presses `k`, `e`, `y` and then
/// means "play/pause" by the following space — the space belongs to the
/// sentence. Any non-shortcut key marks the user as typing, and Space and the
/// arrows pass straight through for a short grace period afterwards.
///
/// Deliberately one-directional: it only ever *releases* keys back to the
/// focused app. The worst it can do is make someone press Space twice on the
/// notch; the bug it replaces made a keyboard stop working.
struct TypingGuard: Equatable {
    /// Long enough to bridge the gap between words at any human typing speed,
    /// short enough that pausing to reach for the notch clears it. Typing rate
    /// is what matters here, not reaction time: a touch typist leaves well
    /// under a second between keys, and someone who has stopped to hover the
    /// notch has spent longer than this moving the pointer there.
    static let grace: TimeInterval = 2

    private var lastTypedAt: TimeInterval?

    /// Feed every key the monitors see, shortcut or not.
    mutating func observe(isShortcut: Bool, now: TimeInterval) {
        guard !isShortcut else { return }
        lastTypedAt = now
    }

    /// Whether the user was typing recently enough that Space and the arrows
    /// belong to them rather than to the notch.
    func isTyping(now: TimeInterval) -> Bool {
        guard let lastTypedAt else { return false }
        // A clock that jumps backwards should not arm the guard forever.
        let elapsed = now - lastTypedAt
        return elapsed >= 0 && elapsed < Self.grace
    }

    /// Hovering the notch on purpose is a fresh start — otherwise a sentence
    /// typed just before reaching for the pill would mute the first press.
    mutating func reset() {
        lastTypedAt = nil
    }
}
