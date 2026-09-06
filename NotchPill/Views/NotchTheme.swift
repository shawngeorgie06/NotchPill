import SwiftUI

/// Motion vocabulary for the notch overlay.
///
/// Before this existed the panel animated every in-place value change with a
/// flat `.easeOut(duration: 0.1)`, which is why it read as static: at that
/// length with no spring, a value does not move, it is replaced. Three named
/// curves instead, so a reader can tell what kind of change they are looking
/// at from the call site.
///
/// `reduceMotion` is a parameter rather than an environment read so the
/// accessibility floor can be asserted in a unit test instead of only in a
/// rendered view.
enum NotchMotion {
    /// The panel opening, or a card appearing. Enough overshoot to read as an
    /// arrival, not enough to wobble on a surface this small.
    static func enter(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .spring(response: 0.42, dampingFraction: 0.78)
    }

    /// A value changing in place. This is the token that does the work: it is
    /// what turns "replaced" into "moved".
    static func settle(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .spring(response: 0.30, dampingFraction: 0.85)
    }

    /// Anything leaving. Quicker than arrival and deliberately not a spring —
    /// overshoot on the way out reads as hesitation.
    static func exit(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .easeIn(duration: 0.16)
    }

    /// The exact value the rest of the overlay already uses for Reduce Motion.
    /// Not zero: a true zero-duration animation still lets SwiftUI batch the
    /// change, and matching the existing constant keeps every surface in step.
    private static let floor = Animation.linear(duration: 0.01)
}
