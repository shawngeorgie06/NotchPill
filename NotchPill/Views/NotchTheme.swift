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

    /// Swiping from one deck page to the next. Longer and more damped than
    /// `settle`: a page is a whole surface, and the short ease-out that used
    /// to drive it read as a cut rather than a slide.
    static func page(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .spring(response: 0.40, dampingFraction: 0.90)
    }

    /// A painted surface or meter filling in. Softer than `enter` so the wash
    /// lands as colour arriving, not as an object bouncing into place.
    static func paint(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .spring(response: 0.52, dampingFraction: 0.92)
    }

    /// Anything leaving. Quicker than arrival and deliberately not a spring —
    /// overshoot on the way out reads as hesitation.
    static func exit(reduceMotion: Bool) -> Animation {
        reduceMotion ? floor : .easeIn(duration: 0.16)
    }

    /// The gap between one object arriving and the next on the same card.
    /// Long enough that three tiles read as three arrivals; short enough that
    /// the last is settled before you have finished reading the first.
    static let stagger: TimeInterval = 0.045

    /// How far an arriving object rises into place, in unscaled points.
    static let rise: CGFloat = 4

    /// How much a tile swells when its state changes. Enough to catch the eye
    /// in the periphery; not enough to move its neighbours.
    static let bump: CGFloat = 1.04

    /// How much an object compresses under the pointer while pressed. The
    /// mirror of `bump`: the same distance, the other way.
    static let press: CGFloat = 0.96

    /// How long a transient label stays after the thing it names changes —
    /// the page's name after a swipe. Long enough to read once.
    static let linger: TimeInterval = 1.4

    /// How far a page sits under its neighbours while sliding in, so the
    /// swap reads as depth rather than a hard cut.
    static let pageScale: CGFloat = 0.985

    /// How far a painted tile grows from while its wash lands.
    static let paintScale: CGFloat = 0.97

    /// The exact value the rest of the overlay already uses for Reduce Motion.
    /// Not zero: a true zero-duration animation still lets SwiftUI batch the
    /// change, and matching the existing constant keeps every surface in step.
    private static let floor = Animation.linear(duration: 0.01)
}

/// An object arriving on a card: it fades in and rises `NotchMotion.rise`
/// points, `index` staggers behind its siblings. Reduce Motion keeps the fade
/// and drops the rise.
///
/// Applied to the objects — tiles, meters, rows, chips — and not to the
/// header, which is where the eye lands first and should already be there.
/// Set inside a `notchReveal` subtree so decorations know their arrival is
/// already being animated for them. One arriving object gets one arrival:
/// a painted fill that fades itself in *while* the reveal fades its parent
/// in composites two ramps, and the tile reads as a half-black rectangle
/// that then fills with colour.
private struct NotchArrivalOwnedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var notchArrivalOwned: Bool {
        get { self[NotchArrivalOwnedKey.self] }
        set { self[NotchArrivalOwnedKey.self] = newValue }
    }
}

struct NotchReveal: ViewModifier {
    let index: Int
    let scale: CGFloat
    let reduceMotion: Bool
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : NotchMotion.rise * scale)
            .onAppear {
                withAnimation(NotchMotion.enter(reduceMotion: reduceMotion)
                    .delay(reduceMotion ? 0 : NotchMotion.stagger * Double(index))) {
                    shown = true
                }
            }
            // Applied outward, so it reaches `.background` content too —
            // which is exactly where the painted fills live.
            .environment(\.notchArrivalOwned, true)
    }
}

/// A tile whose state just changed swells by `NotchMotion.bump` and settles,
/// so a session going from working to waiting is seen without being read.
/// Nothing under Reduce Motion: the band colour still changes.
struct NotchBump<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                SpringKeyframe(NotchMotion.bump, duration: 0.14, spring: .snappy)
                SpringKeyframe(1, duration: 0.30, spring: .smooth)
            }
        }
    }
}

/// How every object on the island answers the pointer: it lifts under hover
/// (a wash of white over its own surface, its rim brightening) and compresses
/// under press. One style for tiles, rows and chips, so they all feel like the
/// same material; before this only the shelf chips reacted to hover and only
/// the transport buttons to press.
///
/// The wash is drawn over the label, not as its background, so it works on
/// any surface the object already has — a tinted band, a well fill, nothing.
struct NotchObjectButtonStyle: ButtonStyle {
    let cornerRadius: CGFloat
    let reduceMotion: Bool
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        configuration.label
            .overlay(shape.fill(.white.opacity(hovered ? NotchOpacity.wellFill : 0)))
            .overlay(shape.stroke(.white.opacity(hovered ? NotchOpacity.rim : 0), lineWidth: 0.5))
            .scaleEffect(configuration.isPressed && !reduceMotion ? NotchMotion.press : 1)
            .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: configuration.isPressed)
            .animation(NotchMotion.exit(reduceMotion: reduceMotion), value: hovered)
            .onHover { hovered = $0 }
    }
}

extension View {
    func notchReveal(_ index: Int, scale: CGFloat, reduceMotion: Bool) -> some View {
        modifier(NotchReveal(index: index, scale: scale, reduceMotion: reduceMotion))
    }

    func notchBump<T: Equatable>(on trigger: T, reduceMotion: Bool) -> some View {
        modifier(NotchBump(trigger: trigger, reduceMotion: reduceMotion))
    }
}

/// Depth for an object sitting on the island: a vertical wash of the tint,
/// a sheen along the top edge, and a rim that is brighter where the light
/// lands. A flat fill at `NotchOpacity.band` is a sticker; this is a tile.
///
/// The wash lands rather than pops: on appear it fills from a slightly
/// smaller, transparent state, and lit/idle changes interpolate instead of
/// swapping. Reduce Motion keeps the final paint with no travel.
struct NotchPaintedFill: View {
    let tint: Color
    var lit: Bool = true
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// True when an enclosing `notchReveal` is already animating this tile in.
    @Environment(\.notchArrivalOwned) private var arrivalOwned
    @State private var painted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let ready = painted || reduceMotion || arrivalOwned
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: lit
                        ? [tint, tint.opacity(0.72)]
                        : [Color.white.opacity(0.20), Color.white.opacity(0.08)],
                    startPoint: .top, endPoint: .bottom
                )
            )
            shape.fill(
                LinearGradient(
                    colors: [.white.opacity(lit ? NotchOpacity.rim : NotchOpacity.highlight), .clear],
                    startPoint: .top, endPoint: .center
                )
            )
        }
        .overlay(
            shape.stroke(
                LinearGradient(
                    colors: [.white.opacity(lit ? NotchOpacity.secondary : NotchOpacity.highlight),
                             .white.opacity(NotchOpacity.hairline)],
                    startPoint: .top, endPoint: .bottom
                ),
                lineWidth: 0.5
            )
        )
        .opacity(ready ? 1 : 0)
        .scaleEffect(ready ? 1 : NotchMotion.paintScale)
        .onAppear {
            // Only paint ourselves in when nobody else is doing it for us.
            guard !arrivalOwned else { return }
            withAnimation(NotchMotion.paint(reduceMotion: reduceMotion)) {
                painted = true
            }
        }
        .animation(NotchMotion.paint(reduceMotion: reduceMotion), value: lit)
    }
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

    /// A session object's minimum width. The strip sizes each tile to half
    /// the island, so this is a floor, not the drawn size: two names have to
    /// fit, which 88pt never did.
    static let tile: CGFloat = 168

    /// Album art, a CI status block, the app icon: the large object a page
    /// is about. Bigger than a well (a tap target) and smaller than a tile
    /// (a session).
    static let hero: CGFloat = 72

    /// A card header's glyph well: the small tinted square every card opens
    /// with, sized to sit on one 13pt title line. Smaller than `well`, which
    /// is a tap target; this is a mark.
    static let mark: CGFloat = 16

    /// A meter bar's thickness. 4pt read as a hairline once the bars sat on a
    /// tile rather than the bare island.
    static let bar: CGFloat = 6

    /// Every step, for tests that assert the scale has no duplicates.
    static let all: [CGFloat] = [tight, snug, base, roomy, section, gutter, well, tile, mark, bar, hero]
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
    /// 14pt on a 108pt-tall tile still looked rectangular; 18 is the step
    /// that makes the silhouette a squircle without becoming a pill.
    static let tile: CGFloat = 18
    /// A card-sized object shorter than a tile — a meter, a shelf chip, a
    /// list row's surface. `tile`'s 14 on a 40pt object reads as a pill.
    static let card: CGFloat = 10

    static let all: [CGFloat] = [well, card, tile]
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
    /// The one number a metric card is about — a percentage, a level. Larger
    /// than a title because it is read from across the desk, not up close.
    static let display: CGFloat = 15
    /// The number the island is *for* on a quota or timer page. Display is a
    /// figure on a card; this is the card.
    static let hero: CGFloat = 28

    /// The distinct sizes, for the duplicate assertion. `mono` is deliberately
    /// absent: it shares `caption`'s size and that is the point.
    static let all: [CGFloat] = [hero, display, title, body, caption]
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
    /// 0.18 was invisible against a mid-tone wallpaper.
    static let rim: Double = 0.28
    /// A tile's coloured header band. Nearly opaque: this is where the state
    /// colour does its work now, instead of as a 5pt dot, and a washed-out
    /// band is worse than none.
    static let band: Double = 0.85
    /// The model badge on a band: black at this opacity over the state colour,
    /// so it reads as a darker patch of the same hue rather than a new one.
    static let badge: Double = 0.30
    /// Album artwork glowing behind the media card. Strong enough that the
    /// card takes the cover's colour, weak enough that white text on it is
    /// still white text on black.
    static let glow: Double = 0.55

    static let all: [Double] = [primary, secondary, tertiary, hairline,
                                wellFill, highlight, rim, band, badge, glow]
}
