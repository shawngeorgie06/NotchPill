# NotchPill expanded panel: motion and layout

Date: 2026-09-06
Status: design, approved in chat, not yet planned

## The problem, stated precisely

The user's words were "boring and bland and kinda of crowded" and, earlier,
"static movements and animation and also it feels kinda cramped and improperly
laid out". Two distinct complaints, and neither is about colour or richness.
Colour is explicitly out of scope.

### Motion is static

`NotchRootView` has three animation tokens (lines 70-100):

```swift
private var expandAnimation: Animation      // .timingCurve(0.22, 0.8, 0.2, 1, duration: hoverAnimationDuration)
private var contentAnimation: Animation     // .easeOut(duration: 0.1)
private var contentFadeAnimation: Animation // .easeOut/.easeIn with a delay
```

`contentAnimation` — a flat 100ms ease-out — drives `state.activity`,
`volumeLevel`, `brightnessLevel` and `microphoneMuted`. Every state change in
the panel therefore reads as an instant cross-fade with no arrival. That is the
"static" feeling: things *replace* each other rather than *move*. Nothing in the
panel has weight.

### Layout is crowded

`Tiles.swift` (2,835 lines) has 157 `.opacity()` calls, 113 hardcoded `size:`
values, 9 distinct font sizes and 10 distinct spacing values (2,3,4,5,6,8,9,10,
14,18). But the count is a symptom, not the disease.

The disease is **columnar structure**. On the agents card — the densest thing in
the app and the card actually on screen most of the time — a single row draws
three text lines at three different left edges:

- the title line starts at the card's leading edge
- `agentActivityLine` indents its no-task branch by `s(12)` and its task branch
  by a `›` glyph plus `s(5)`
- `agentMetricsLine` indents by `s(12)`

and three different right edges: the status pill, `agentModelTag` (model +
effort, `fixedSize`), and `agentPermissionBadge` (capsule, `fixedSize`). None of
them share a width, so the right margin is ragged on every row and re-rags
whenever a session's model or permission mode differs.

Colour also does two jobs simultaneously. `color(for:)` returns green for
`working`, and that green appears at once as the header dot fill, the header dot
halo at `0.16`, the `›` glyph at `0.9`, and the effort tag at `0.85`. Orange
means both "waiting" and, via `agentPermissionBadge`, "unsupervised" — two
unrelated meanings on one row.

## Approach: one card end-to-end, then roll the vocabulary out

The user chose "C then A": build the reference implementation on a single card
first, prove the vocabulary against a real dense case, then use it as the
foundation everything else migrates to. Not a global refactor up front.

**The reference card is the agents card**, not the media card. It is what is on
screen, it is the densest layout in the app, and it is where the user's
attention actually goes.

## Design

### 1. Motion vocabulary

New tokens in `NotchPill/Views/NotchTheme.swift`, replacing raw durations:

```swift
enum NotchMotion {
    static let enter  = Animation.spring(response: 0.42, dampingFraction: 0.78)
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.85)
    static let exit   = Animation.easeIn(duration: 0.16)
}
```

- `enter` — the panel opening, a card appearing. Enough overshoot to read as
  arrival, not enough to wobble.
- `settle` — in-place value changes. This replaces `contentAnimation`'s
  `.easeOut(0.1)`, and is the single highest-leverage change in the document:
  it is what turns "replaced" into "moved".
- `exit` — anything leaving. Departure should be quicker than arrival and needs
  no spring; a spring on the way out reads as hesitation.

Under `reduceMotion` all three collapse to `.linear(duration: 0.01)`, exactly as
the existing tokens already do. This is testable and will be tested.

`expandAnimation` keeps its existing timing curve for now — the geometry of the
notch opening is tuned against `NotchState.hoverAnimationDuration` and changing
it is a separate risk. Only `contentAnimation` migrates in the first pass.

### 2. The signature move

The agent row's status badge **morphs** between `working` / `idle 18m` /
`needs you` via `matchedGeometryEffect`, instead of cross-fading. This is the
state the user actually watches change, so it is the one worth spending a
transition on.

**Known risk, to be re-checked during planning:** `matchedGeometryEffect` across
the collapse/expand boundary may glitch or silently no-op, because collapsed and
expanded content live in different branches of a `ZStack` driven by
`expansionProgress` rather than in one namespace. Within a single agent row —
where both badge states are siblings under one `ForEach` — it should hold. If it
does not, the fallback is animating the badge frame directly with `settle`, and
saying so in the plan rather than quietly dropping the effect.

### 3. Columnar layout for the agent row

Three rules, applied to `agentRow`, `agentActivityLine`, `agentMetricsLine`,
`agentModelTag` and `agentPermissionBadge`:

1. **One left edge per card.** The status dot moves into a fixed-width leading
   gutter (`NotchSpace.gutter`). Every text line in the row starts at the same
   x. The ad-hoc `.padding(.leading, s(12))` calls and the `›` glyph's implicit
   indent both go away; the gutter is the indent.
2. **One right-aligned metadata column** of consistent width. Status badge,
   model tag and permission badge all live in it, so the right margin stops
   re-ragging per session.
3. **Metadata demoted to one tertiary row.** Runtime, context, model, effort and
   permission collapse into a single line at tertiary opacity. The exceptions
   stay bright: `isContextTight` and `isUnsupervised` already earn a colour and
   keep it. Nothing else on that line does.

Vertical rhythm opens up relative to horizontal padding — the current card is
tighter top-to-bottom than side-to-side, which is what "cramped" describes.

### 4. Supporting token scales

Also in `NotchTheme.swift`. These support the structure; they are not the fix by
themselves.

- **Spacing**, 4pt-derived: `tight 2`, `snug 4`, `base 8`, `roomy 12`,
  `section 20`, plus `gutter`.
- **Type**, four roles: `title 13`, `body 11`, `caption 9`, `mono`.
- **Opacity**, four roles: `primary 1.0`, `secondary 0.60`, `tertiary 0.38`,
  `hairline 0.08`.

Every token flows through the existing `s()` and `textSize()` multipliers, so
pill size and readability settings keep working unchanged. Tokens are values fed
to `s()`, never replacements for it.

`NotchDesign.swift` stays as is. Its own comment says it is "shared tokens for
the settings window (notch overlay uses plain black)" — it is a different
surface with a different job, and merging the two is not part of this work.

Estimated new file: ~120 lines.

## Rollout

1. `NotchTheme.swift` lands with motion, spacing, type and opacity tokens.
2. `contentAnimation` becomes `NotchMotion.settle`.
3. The agents card is rebuilt against the tokens end-to-end — gutter, metadata
   column, demoted metrics row, morphing badge.
4. User looks at it. If the vocabulary is right, other cards migrate to it one
   at a time. If it is not, only one card was spent finding out.

No other card changes in this work.

## Testing

What can be asserted mechanically:

- Every `NotchMotion` token collapses to `.linear(duration: 0.01)` when
  `reduceMotion` is set.
- `s()` and `textSize()` remain pure functions of their input and the scale
  settings; token values pass through them unmodified.
- No unused tokens and no duplicate values within a scale.
- The agents card renders without layout assertions at the smallest and largest
  pill scale and readability settings.

What cannot: whether it looks better. That verdict is the user's, off a build,
and no test substitutes for it.

## Out of scope

- Colour, richness, new visual materials.
- `expandAnimation` and the notch-opening geometry.
- Migrating cards other than the agents card.
- Merging `NotchDesign` and `NotchTheme`.
