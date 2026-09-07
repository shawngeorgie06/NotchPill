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

/// Spacing steps for the notch overlay, in unscaled points.
///
/// Always pass these through the view's `s()`, which applies the user's pill
/// size setting: `s(NotchSpace.base)`, never `NotchSpace.base` on its own.
///
/// `Tiles.swift` had ten distinct spacing values (2, 3, 4, 5, 6, 8, 9, 10, 14,
/// 18) chosen one call site at a time, which is what "cramped and improperly
/// laid out" describes — no two cards agreed on what a gap meant.
enum NotchSpace {
    static let tight: CGFloat = 2
    static let snug: CGFloat = 4
    static let base: CGFloat = 8
    static let roomy: CGFloat = 12
    static let section: CGFloat = 20

    /// The leading column a row's status dot sits in, so every text line below
    /// the title shares one left edge instead of each inventing its own indent.
    static let gutter: CGFloat = 11

    /// The square an icon sits in, and the diameter of a circular action. One
    /// size for both so a tile's vendor mark and the shelf's jump control read
    /// as the same kind of object.
    static let well: CGFloat = 22

    /// A session tile's width. A horizontal strip needs a fixed width; a
    /// flexible one has nothing to measure against inside a `ScrollView`.
    /// Room for a well, a short name, and `base` padding on each side.
    static let tile: CGFloat = 72

    /// Every step, for tests that assert the scale has no duplicates.
    static let all: [CGFloat] = [tight, snug, base, roomy, section, gutter, well, tile]
}

/// Corner radii for nested objects on the island, in unscaled points. Pass
/// through `s()` like a spacing step.
///
/// The island itself keeps its own 22pt silhouette in `NotchRootView`; these
/// are for the things sitting *on* it, which must be visibly rounder than a
/// text line and visibly less round than the surface that holds them.
enum NotchRadius {
    /// A `NotchSpace.well` square — a vendor mark's backing.
    static let well: CGFloat = 6
    /// A session tile. Continuous, so it reads as an object, not a box.
    static let tile: CGFloat = 14

    static let all: [CGFloat] = [well, tile]
}

/// Type roles, in unscaled points. Pass through `textSize()`, which applies the
/// user's readability setting.
enum NotchType {
    static let title: CGFloat = 13
    static let body: CGFloat = 11
    static let caption: CGFloat = 9
    /// Same size as `caption` by design — it is a different *face*, not a
    /// different size, and a monospaced digit at a different size next to a
    /// proportional one is what makes a metadata row look accidental.
    static let mono: CGFloat = 9

    /// The distinct sizes, for the duplicate assertion. `mono` is deliberately
    /// absent: it shares `caption`'s size and that is the point.
    static let all: [CGFloat] = [title, body, caption]
}

/// The four jobs opacity does on this surface. `Tiles.swift` had 157 opacity
/// call sites; almost all of them were one of these four intentions written out
/// as a fresh number.
enum NotchOpacity {
    /// The thing the row is about.
    static let primary: Double = 1.0
    /// Supporting text you read second.
    static let secondary: Double = 0.60
    /// Facts you consult rather than read — runtime, context, model.
    static let tertiary: Double = 0.38
    /// Separators and card strokes.
    static let hairline: Double = 0.08

    /// The fill of a well or tile: just enough lift off the black to read as
    /// a surface, and dimmer than a separator so a row of tiles is not a row
    /// of boxes.
    static let wellFill: Double = 0.06
    /// The sheen along the island's real top edge, where it has one.
    static let highlight: Double = 0.14
    /// The island's rim at its brightest — the bottom curve, where the light
    /// from above lands. Brighter than a separator, dimmer than any text.
    static let rim: Double = 0.18

    static let all: [Double] = [primary, secondary, tertiary, hairline,
                                wellFill, highlight, rim]
}
