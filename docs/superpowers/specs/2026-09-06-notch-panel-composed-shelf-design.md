# NotchPill expanded panel: composed shelf

Date: 2026-09-06
Status: design, approved in chat; planned in
`docs/superpowers/plans/2026-09-06-notch-panel-composed-shelf.md`

Amends `2026-09-06-notch-ui-motion-and-layout-design.md`. That spec treated
motion (static → settle springs) and columnar crowding on the agents list. Both
landed. The remaining complaint is that the panel still reads as **flat** next
to Droppy's Dynamic Island, which reads as **composed**.

The earlier spec put "colour, richness, new visual materials" out of scope.
That was the right call for the crowding problem. It is the wrong call for
this one. This document reopens richness in a narrow way: painted depth on the
island, and one nested object vocabulary on the agents page. Hue and live
glass stay out.

## The problem, stated precisely

Droppy's hanging island (the visual target: the media island and the file
shelf on getdroppy.app, not the marketing copy and not the bottom clipboard
drawer) is a **tray of objects**. Album art is a rounded-square tile. Files
are thumbnail tiles in a row. Actions live in circular wells on the trailing
edge. Content is inset from a large continuous silhouette that has a brighter
rim and a top-edge highlight, so the island reads as a surface, not a hole.

NotchPill's island is a **typeset sheet**. `PillSurface` fills `Color.black`
and strokes at `white.opacity(0.07)`. The agents page — still the card on
screen most of the time — is a tracked "AGENT SESSIONS" header over a
vertical list of three-line rows. The last pass correctly removed per-row
boxes (eleven competing rectangles in 210pt) and collapsed metadata onto one
tertiary line. That made the list *legible*. It also made the page more of a
sheet: glyphs on one plane, no nested objects to compose.

The 210pt width is a hard constraint. Droppy's file shelf is a wide
five-thumbnail strip and cannot be copied at that width. Compressed, the
same idea is two visible tiles, a horizontal scroll for the rest, and one
circular action well.

## Approach: paint the island, restyle only the agents page

The deck stays. Other cards keep their layouts. They inherit the painted
island and nothing else.

1. **Island chrome** — every expanded page. Opaque black with a painted
   inner highlight and a brighter hairline. More inset, so content sits in
   the tray.
2. **Agents page as a shelf** — session tiles in a horizontal strip, one
   trailing jump well, no in-card section header, no in-tile metadata.

Media, CI, clipboard, and the rest are not in this work. The morphing status
capsule on the agent row goes away on this page: status becomes a dot on the
tile. That is a replacement, not an accidental drop of `matchedGeometryEffect`.

## Design

### 1. Painted island chrome

`PillSurface` and `ExpandedPillSurface` in `NotchDesign.swift` keep a
`Color.black` fill. No `NSVisualEffectView`, no `ultraThinMaterial`, no
wallpaper showing through. The physical notch is already an opaque black
cutout; glass next to it would fight the hardware.

Depth is two overlays on that fill, clipped to the same shape:

- **Rim.** A 0.5pt stroke in a vertical gradient: `NotchOpacity.hairline`
  (0.08) at the top, `NotchOpacity.rim` (0.18) at the bottom curve. On
  notched hardware the pill's top edge is the seam with the cutout, and a
  uniformly brighter line there reads as a crack under the notch. The
  light still comes from above; it just does not land on the seam.
  `NotchDesign.pillStroke` (used by the HUDs) becomes `rim`.
- **Inner highlight.** A top-down `LinearGradient` from
  `Color.white.opacity(NotchOpacity.highlight)` (0.14) to clear over
  `NotchSpace.base`, masked to the pill shape — drawn **only where the pill
  has a real top edge**, i.e. the free-floating island on a display with
  no notch. This is the Droppy top-edge sheen.

`expandAnimation` in `NotchRootView` is untouched. `contentFadeAnimation`
is untouched.

`ExpandedView`'s padding (today raw 9 / 6 / 2) moves onto existing tokens:
`NotchSpace.roomy` (12) horizontally, `NotchSpace.base` (8) on top,
`NotchSpace.tight` (2) on the bottom. The deck height budget carries 10pt
of slack for top + bottom, so `roomy` on top would push the page dots off
the lower edge. No new 10 is added; it would sit between `base` and `roomy`
and rot the 4pt grid.

### 2. Agents page as a shelf

`agentsCard` in `Tiles.swift` is the only card that changes.

**Strip.** A horizontal `ScrollView` of session tiles. Two tiles fit in
210pt once `roomy` inset, tile gap, and the trailing well are reserved;
further sessions scroll. `.scrollBounceBehavior(.basedOnSize)` stays.
Vertical scrolling of three-line rows goes away.

**Tile.** Each session is one object:

- `NotchSpace.tile` (72) wide. Continuous rounded rect at
  `NotchRadius.tile`, fill `Color.white.opacity(NotchOpacity.wellFill)`
  (0.06), hairline stroke.
- Waiting keeps the existing tinted fill (state colour at 0.12) and stroke
  (state colour at 0.48). No other state gets a coloured box.
- Vendor symbol in a `NotchSpace.well` (22) rounded-square well at
  `NotchRadius.well`.
- Display name at `NotchType.body`, semibold, one line.
- Status as a `s(5)` coloured dot (today's gutter dot), not a text capsule.
- `statusLabel` ("idle 18m") as a tertiary `caption` line under the name.
  The dot carries the state; this carries the age the old capsule carried,
  the way Droppy's tile carries "4 weeks ago".
- The tile is the `focusAgentSession` tap target. `buttonStyle(.plain)`.

Runtime, context, model, effort, and permission leave the tile. They do not
fit a ~72pt object. `AgentRowMetadata` stays as a tested value type; the
view stops drawing it.

The layout budget (`NotchContentLayout`) sizes the page as one fixed
`agentsShelf` height (93) instead of N list rows: a strip scrolls sideways,
so a tenth session must not make the notch taller than a first. The number
is taken from the smallest pill size, where text compensation is 1.22× and
the tile is at its tallest. The 144pt
`expandedContentCeiling` used to be derived from two agent rows; it stays
at 144 as a literal because clipboard and terminal cards still cap there.

**Jump well.** One circular control, `NotchSpace.well` across, pinned to the
trailing edge of the strip, vertically centred on the tiles. It focuses the
first waiting session, else the first working one, else the first session.
It replaces the "tap to jump" caption. There is no second well: Droppy's
check/trash pair exists because files confirm or discard; agents have one
real action.

**Header.** The in-card "AGENT SESSIONS" tracked label, header status halo,
summary trailing, and "tap to jump" all go. The deck chrome already names
the page. A single tertiary caption above the strip may keep the counts
("2 working · 1 needs you") using the same summary string `agentsCard`
already builds. If there are no sessions to count, omit the caption.

### 3. Tokens

All new values are unique against today's scales (spacing 2/4/8/12/20/11,
type 13/11/9, opacity 1.0/0.60/0.38/0.08) and land on each enum's `all`.

```swift
enum NotchSpace {
    // existing: tight 2, snug 4, base 8, roomy 12, section 20, gutter 11
    static let well: CGFloat = 22   // icon well and jump control diameter
    static let tile: CGFloat = 72   // session tile width
}

enum NotchRadius {
    static let well: CGFloat = 6
    static let tile: CGFloat = 14
    static let all: [CGFloat] = [well, tile]
}

enum NotchOpacity {
    // existing: primary 1.0, secondary 0.60, tertiary 0.38, hairline 0.08
    static let wellFill: Double = 0.06
    static let highlight: Double = 0.14
    static let rim: Double = 0.18
}
```

Island inset uses existing steps, not a new 10 that would sit between
`base` and `roomy` and rot the 4pt grid. `well` (22) and `tile` (72) are
sizes, listed on `all` but not on the spacing-ascend check, same as
`gutter`. The jump control is a `Circle` of diameter `s(NotchSpace.well)`
and does not need its own radius token.

Every dimension still goes through `s(_:)`. Every font size still goes
through `textSize(_:)` or `font(size:)`. Tokens are values fed to those
helpers, never replacements for them. No `s(NotchSpace.snug + 2)`-style
expressions.

`NotchDesign.pillStroke` becomes `Color.white.opacity(NotchOpacity.rim)` so
the hairline has one source. Settings-window tokens in `NotchDesign` stay
as they are.

## Rollout

1. Tokens land in `NotchTheme.swift` (and `NotchRadius`). Tests assert
   uniqueness. `well` is listed on `NotchSpace.all` but not on the
   spacing-ascend check — it is a size, same as `gutter`.
2. Island chrome on `PillSurface` / `ExpandedPillSurface`. `ExpandedView`
   inset uses `NotchSpace.roomy`.
3. `agentsCard` rebuilt as the strip + jump well. User looks at a signed
   build. Other cards do not move.

## Testing

What can be asserted mechanically:

- New opacity, space, and radius values are unique within their `all` arrays.
  `NotchTokenScaleTests` grows a `NotchRadius.all` uniqueness check.
- `s()` and `textSize()` remain pure; token values pass through unmodified.
- The agents card lays out at the smallest and largest pill scale and
  readability settings without overflowing 210pt: two tiles plus the jump
  well remain visible, tiles do not crush to zero width.
- Jump well targets waiting before working before "first session".

What cannot: whether it looks composed. That verdict is the user's, off:

```
NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh
```

Ad-hoc signing without that identity rotates the code identity and macOS
silently revokes Accessibility.

## Out of scope

- Hue rewrite. `color(for:)` on agent state stays.
- Live materials (`NSVisualEffectView`, `ultraThinMaterial`, Liquid Glass).
- Per-row list boxes coming back. Waiting's tile well is the one box.
- Media, CI, clipboard, shelf, and every other card's layout.
- Replacing the one-card deck with a multi-widget shelf.
- Widening the panel past ~210pt.
- `expandAnimation` and the notch-opening geometry.
- Drawing `AgentRowMetadata` on the tile.
- A second circular well without a second real action.
