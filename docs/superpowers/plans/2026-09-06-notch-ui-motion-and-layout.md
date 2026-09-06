# Notch UI Motion and Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the NotchPill expanded panel stop reading as static and crowded, by introducing a shared motion/spacing/type/opacity vocabulary and rebuilding the agents card against it as the reference implementation.

**Architecture:** A new `NotchPill/Views/NotchTheme.swift` holds four token groups — `NotchMotion` (three springs, all collapsing to a 10ms linear under Reduce Motion), `NotchSpace`, `NotchType`, `NotchOpacity`. The agents card in `Tiles.swift` is then rebuilt against them: one leading gutter so every text line in a row shares a left edge, one right-aligned metadata column so the right margin stops re-ragging, and the runtime/context/model/effort/permission facts collapsed into a single tertiary line driven by a new pure `AgentRowMetadata` value type. The status badge morphs between states via `matchedGeometryEffect` instead of cross-fading. No other card changes.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`import Testing`, `@Suite`/`@Test`/`#expect`), Xcode project with `PBXFileSystemSynchronizedRootGroup` groups.

**Spec:** `docs/superpowers/specs/2026-09-06-notch-ui-motion-and-layout-design.md`

## Global Constraints

- **New Swift files need no `project.pbxproj` edit.** Both targets use `PBXFileSystemSynchronizedRootGroup` (see `NotchPill.xcodeproj/project.pbxproj:9-20`), so a file dropped in `NotchPill/Views/` is compiled automatically.
- **Test command:** `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'`. Scope a run with `-only-testing:NotchPillTests/<SuiteName>`.
- **All tests live in one file:** `NotchPillTests/NotchPillTests.swift` (~9,285 lines). Append new suites at the end. Fixture helpers are `private func` members of the suite that uses them — do not add global fixtures.
- **Never replace `s()` or `textSize()`.** Every token is a raw value *fed into* `s(...)` or `textSize(...)`, e.g. `s(NotchSpace.base)`. `s()` applies the user's pill-size setting and `textSize()` the readability setting; bypassing them breaks both settings. `s()` and `textSize()` are `private` members of the view structs in `Tiles.swift` (lines 1000-1001, 2575-2576, 2743-2744).
- **Colour is out of scope.** Do not change any hue, add materials, or alter `color(for:)` in `Tiles.swift:1926-1932`. Opacity tokens replace *existing* opacity numbers only.
- **`expandAnimation` is out of scope.** Only `contentAnimation` migrates. `NotchRootView.swift:70-100` holds all three animation properties; leave `expandAnimation` and `contentFadeAnimation` alone.
- **Reduce Motion floor is exactly `.linear(duration: 0.01)`** — the value already used throughout `NotchRootView.swift` and `Tiles.swift:562`.
- **Commit after every task.** Message style in this repo is a `type: subject` line plus a body explaining *why*, in prose.

---

### Task 1: Motion tokens

**Files:**
- Create: `NotchPill/Views/NotchTheme.swift`
- Test: `NotchPillTests/NotchPillTests.swift` (append suite)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum NotchMotion` with three static funcs, each `(reduceMotion: Bool) -> Animation`:
    - `NotchMotion.enter(reduceMotion:)`
    - `NotchMotion.settle(reduceMotion:)`
    - `NotchMotion.exit(reduceMotion:)`

Taking `reduceMotion` as a parameter rather than reading the environment is what makes the accessibility floor testable at all — a computed property that reads `@Environment` can only be checked by rendering a view.

- [ ] **Step 1: Write the failing test**

Append to the end of `NotchPillTests/NotchPillTests.swift`:

```swift
// MARK: - Notch theme

@Suite("NotchMotion")
struct NotchMotionTests {
    @Test("every token collapses to the reduce-motion floor")
    func reduceMotionFloor() {
        // The floor is not "something short" — it is the exact value the rest
        // of the overlay already uses, so a card animating at 10ms next to one
        // animating at 12ms cannot happen.
        let floor = Animation.linear(duration: 0.01)
        #expect(NotchMotion.enter(reduceMotion: true) == floor)
        #expect(NotchMotion.settle(reduceMotion: true) == floor)
        #expect(NotchMotion.exit(reduceMotion: true) == floor)
    }

    @Test("tokens are distinct from the floor when motion is allowed")
    func motionAllowed() {
        let floor = Animation.linear(duration: 0.01)
        #expect(NotchMotion.enter(reduceMotion: false) != floor)
        #expect(NotchMotion.settle(reduceMotion: false) != floor)
        #expect(NotchMotion.exit(reduceMotion: false) != floor)
    }

    @Test("the three tokens are distinct from each other")
    func tokensDiffer() {
        // Three names for one curve would be a lie in the source: a reader
        // would think `exit` had been tuned when it had not.
        #expect(NotchMotion.enter(reduceMotion: false) != NotchMotion.settle(reduceMotion: false))
        #expect(NotchMotion.enter(reduceMotion: false) != NotchMotion.exit(reduceMotion: false))
        #expect(NotchMotion.settle(reduceMotion: false) != NotchMotion.exit(reduceMotion: false))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/NotchMotionTests`

Expected: BUILD FAILURE — `cannot find 'NotchMotion' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `NotchPill/Views/NotchTheme.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/NotchMotionTests`

Expected: PASS, 3 tests.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Views/NotchTheme.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: name the notch overlay's three motion curves

Every in-place change in the panel ran through one flat 100ms ease-out,
which is why it read as static — at that length with no spring a value
is replaced rather than moved. enter/settle/exit say which kind of
change a call site is animating, and take reduceMotion as an argument
so the accessibility floor is assertable without rendering a view."
```

---

### Task 2: Spacing, type and opacity scales

**Files:**
- Modify: `NotchPill/Views/NotchTheme.swift`
- Test: `NotchPillTests/NotchPillTests.swift` (append suite)

**Interfaces:**
- Consumes: `NotchTheme.swift` from Task 1.
- Produces:
  - `enum NotchSpace` — `tight: CGFloat = 2`, `snug = 4`, `base = 8`, `roomy = 12`, `section = 20`, `gutter = 11`, plus `static let all: [CGFloat]`
  - `enum NotchType` — `title: CGFloat = 13`, `body = 11`, `caption = 9`, `mono = 9`, plus `static let all: [CGFloat]`
  - `enum NotchOpacity` — `primary: Double = 1.0`, `secondary = 0.60`, `tertiary = 0.38`, `hairline = 0.08`, plus `static let all: [Double]`

`all` exists so the scales can be asserted for duplicates. It is test-facing, and the doc comment says so.

`gutter = 11` is the leading column Task 5 puts the status dot in: the dot is 5pt wide and the old ad-hoc indent was `s(12)`, so 11 keeps the row visually where it already sits while making the number mean something.

- [ ] **Step 1: Write the failing test**

Append to `NotchPillTests/NotchPillTests.swift`:

```swift
@Suite("Notch token scales")
struct NotchTokenScaleTests {
    @Test("no scale contains a duplicate value")
    func noDuplicates() {
        // Two names for one number is how a scale rots: the next person picks
        // whichever reads better and the two drift apart at the first edit.
        #expect(Set(NotchSpace.all).count == NotchSpace.all.count)
        #expect(Set(NotchType.all).count == NotchType.all.count)
        #expect(Set(NotchOpacity.all).count == NotchOpacity.all.count)
    }

    @Test("spacing steps ascend")
    func spacingAscends() {
        let steps: [CGFloat] = [NotchSpace.tight, NotchSpace.snug,
                                NotchSpace.base, NotchSpace.roomy, NotchSpace.section]
        #expect(steps == steps.sorted())
    }

    @Test("type roles descend from title to caption")
    func typeDescends() {
        #expect(NotchType.title > NotchType.body)
        #expect(NotchType.body > NotchType.caption)
    }

    @Test("opacity roles descend from primary to hairline")
    func opacityDescends() {
        #expect(NotchOpacity.primary > NotchOpacity.secondary)
        #expect(NotchOpacity.secondary > NotchOpacity.tertiary)
        #expect(NotchOpacity.tertiary > NotchOpacity.hairline)
    }

    @Test("the gutter clears the status dot")
    func gutterClearsDot() {
        // The dot is 5pt. A gutter narrower than the thing it holds would put
        // the text lines' shared left edge inside the dot.
        #expect(NotchSpace.gutter > 5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/NotchTokenScaleTests`

Expected: BUILD FAILURE — `cannot find 'NotchSpace' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `NotchPill/Views/NotchTheme.swift`:

```swift
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

    /// Every step, for tests that assert the scale has no duplicates.
    static let all: [CGFloat] = [tight, snug, base, roomy, section, gutter]
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

    static let all: [Double] = [primary, secondary, tertiary, hairline]
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/NotchTokenScaleTests`

Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Views/NotchTheme.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: add spacing, type and opacity scales for the notch overlay

Tiles.swift carried ten spacing values, nine font sizes and 157 opacity
call sites, each chosen locally, so no two cards agreed on what a gap or
a dim meant. Naming the four jobs each scale actually does is what lets
the agents card be rebuilt against something rather than retuned by eye."
```

---

### Task 3: Route in-place changes through `settle`

**Files:**
- Modify: `NotchPill/Views/NotchRootView.swift:70-100`

**Interfaces:**
- Consumes: `NotchMotion.settle(reduceMotion:)` from Task 1.
- Produces: no new symbols. `contentAnimation` keeps its name and its type.

This is the single highest-leverage change in the plan and it is one line, so it gets its own task and its own gate: it changes how every value change in the panel feels, and a reviewer should be able to accept or reject exactly that.

- [ ] **Step 1: Read the current definitions**

Run: `sed -n '70,100p' NotchPill/Views/NotchRootView.swift`

Confirm `contentAnimation` currently reads:

```swift
private var contentAnimation: Animation {
    reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.1)
}
```

If it does not, stop and report — the file has moved since this plan was written.

- [ ] **Step 2: Replace the body**

Edit `NotchPill/Views/NotchRootView.swift`, replacing the whole `contentAnimation` property with:

```swift
/// In-place value changes: activity, volume, brightness, mic mute.
///
/// This was a flat `.easeOut(duration: 0.1)`. At that length with no spring
/// a value does not appear to move, it appears to be swapped, and every
/// state change in the panel read the same dead way. `settle` gives the
/// change somewhere to arrive.
private var contentAnimation: Animation {
    NotchMotion.settle(reduceMotion: reduceMotion)
}
```

Leave `expandAnimation` and `contentFadeAnimation` exactly as they are.

- [ ] **Step 3: Build and run the whole suite**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'`

Expected: PASS. No test asserts on `contentAnimation` directly; this run is checking that nothing else regressed.

- [ ] **Step 4: Look at it**

Run: `NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh`, launch `NotchPill Dev.app`, and change the system volume with the panel open.

Expected: the volume bar now arrives with a slight settle rather than snapping. If it visibly wobbles, raise `dampingFraction` in `NotchMotion.settle` and say so in the commit body — do not silently retune and claim the spec's numbers.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Views/NotchRootView.swift
git commit -m "feat: settle in-place panel changes instead of swapping them

contentAnimation drove activity, volume, brightness and mic mute through
a flat 100ms ease-out. At that length with no spring the eye reads a
swap, not a movement, which is most of why the panel felt static."
```

---

### Task 4: `AgentRowMetadata` — the demoted metadata line as a value

**Files:**
- Create: `NotchPill/Views/AgentRowMetadata.swift`
- Test: `NotchPillTests/NotchPillTests.swift` (append suite)

**Interfaces:**
- Consumes: `AgentSession` (`NotchPill/Core/AgentSession.swift`) — specifically `runtimeLabel: String?`, `contextLabel: String?`, `modelBaseLabel: String?`, `effortLabel: String?`, `permissionLabel: String?`, `isContextTight: Bool`, `isUnsupervised: Bool`.
- Produces:
  ```swift
  struct AgentRowMetadata: Equatable {
      let text: String?          // the single tertiary line, nil when there is nothing to say
      let isContextTight: Bool   // draw the line in warning colour
      let badge: String?         // permission label, drawn as a capsule; nil for `default`
      let badgeIsWarning: Bool   // capsule warm rather than cool
      init(_ session: AgentSession)
  }
  ```

The spec's third layout rule — "metadata demoted to one tertiary row" — is a *content* decision before it is a layout one: which facts join the line and in what order. Pulling that into a value type makes it the one part of the row that can be tested without rendering.

Order is runtime, context, model, effort, joined with ` · `. Runtime first because it is the fact that is true of every session; effort last because it sits next to the model it modifies.

- [ ] **Step 1: Write the failing test**

Append to `NotchPillTests/NotchPillTests.swift`:

```swift
@Suite("AgentRowMetadata")
struct AgentRowMetadataTests {
    private func session(startedAt: Date? = nil,
                         contextTokens: Int? = nil,
                         model: String? = nil,
                         effort: String? = nil,
                         permissionMode: String? = nil) -> AgentSession {
        var s = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                             state: .working, lastActivity: Date())
        s.startedAt = startedAt
        s.contextTokens = contextTokens
        s.model = model
        s.effort = effort
        s.permissionMode = permissionMode
        return s
    }

    @Test("a bare session has no metadata line")
    func empty() {
        let meta = AgentRowMetadata(session())
        #expect(meta.text == nil)
        #expect(meta.badge == nil)
        #expect(meta.isContextTight == false)
    }

    @Test("facts join in a fixed order")
    func ordering() {
        // Runtime first because it is true of every session; effort last
        // because it modifies the model beside it. A stable order is what lets
        // the eye skip the line entirely on rows it does not care about.
        let meta = AgentRowMetadata(session(startedAt: Date().addingTimeInterval(-3600),
                                            contextTokens: 20_000,
                                            model: "claude-opus-5",
                                            effort: "low"))
        let text = try! #require(meta.text)
        let runtimeIndex = try! #require(text.range(of: "running"))
        let contextIndex = try! #require(text.range(of: "ctx"))
        let modelIndex = try! #require(text.range(of: "Opus"))
        let effortIndex = try! #require(text.range(of: "low"))
        #expect(runtimeIndex.lowerBound < contextIndex.lowerBound)
        #expect(contextIndex.lowerBound < modelIndex.lowerBound)
        #expect(modelIndex.lowerBound < effortIndex.lowerBound)
    }

    @Test("a tight context is flagged")
    func tightContext() {
        // 180k of a 200k window is 90%.
        let meta = AgentRowMetadata(session(contextTokens: 180_000, model: "claude-opus-5"))
        #expect(meta.isContextTight == true)
    }

    @Test("a roomy context is not flagged")
    func roomyContext() {
        let meta = AgentRowMetadata(session(contextTokens: 20_000, model: "claude-opus-5"))
        #expect(meta.isContextTight == false)
    }

    @Test("default permission mode draws no badge")
    func defaultPermission() {
        // Everyone already assumes the agent asks. A badge on every row would
        // teach the eye to skip the badge.
        #expect(AgentRowMetadata(session(permissionMode: "default")).badge == nil)
        #expect(AgentRowMetadata(session(permissionMode: nil)).badge == nil)
    }

    @Test("unsupervised modes badge as warnings, plan does not")
    func permissionWarning() {
        let bypass = AgentRowMetadata(session(permissionMode: "bypassPermissions"))
        #expect(bypass.badge == "bypass")
        #expect(bypass.badgeIsWarning == true)

        let plan = AgentRowMetadata(session(permissionMode: "plan"))
        #expect(plan.badge == "plan")
        #expect(plan.badgeIsWarning == false)
    }
}
```

Note: if `AgentSession`'s stored properties `startedAt`, `contextTokens`, `model`, `effort` or `permissionMode` are `let` rather than `var`, pass them through the memberwise initializer instead of assigning after construction. Check with `grep -n "startedAt\|contextTokens\|permissionMode" NotchPill/Core/AgentSession.swift` before writing the fixture.

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/AgentRowMetadataTests`

Expected: BUILD FAILURE — `cannot find 'AgentRowMetadata' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `NotchPill/Views/AgentRowMetadata.swift`:

```swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/AgentRowMetadataTests`

Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Views/AgentRowMetadata.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: model the agent row's metadata line as a testable value

Runtime, context, model, effort and permission mode were drawn across
three lines with three different indents, which is most of why the card
reads as crowded. Which facts share the line, and in what order, is a
content decision — it belongs somewhere a test can reach it, leaving the
view with only the drawing."
```

---

### Task 5: Columnar agent row

**Files:**
- Modify: `NotchPill/Views/Tiles.swift` — `agentRow` (1743-1794), `agentActivityLine` (1841-1866), `agentMetricsLine` (1874-1893), `agentModelTag` (1807-1828), `agentPermissionBadge` (1905-1922)
- Test: manual visual check plus the existing suite as a regression net

**Interfaces:**
- Consumes: `NotchSpace`, `NotchType`, `NotchOpacity` (Task 2), `AgentRowMetadata` (Task 4).
- Produces: no new public symbols. `agentModelTag` and `agentMetricsLine` are **deleted** — their content is now inside the single metadata line. `agentPermissionBadge` survives, taking `(label: String, isWarning: Bool)` instead of an `AgentSession`.

This is a view-layout task, so there is no unit test that can prove it right. The gate is the user looking at it. What the test run buys here is proof that deleting two functions broke nothing else.

- [ ] **Step 1: Rewrite `agentActivityLine` to use the gutter**

Replace the whole function with:

```swift
/// The row says what the session is *for*, never what it is typing.
///
/// This line used to render the live tool call — "$ Bash xcodebuild test".
/// Two problems. It is the most volatile thing on the card, so the row
/// rewrote itself several times a second and the eye could not rest on it;
/// and a command line is not ours to publish. Whatever a user types after
/// `Bash` lands in the notch verbatim, in front of whoever is looking at
/// the screen — an API key passed inline, a token in a curl, a private
/// path. The task line answers the question the card is actually for
/// ("what is this session doing?") and stays still while it does.
///
/// The leading gutter is the indent. It used to be a `›` glyph on one branch
/// and a `.padding(.leading, s(12))` on the other, so the two states of the
/// same row started at two different x positions.
@ViewBuilder
private func agentActivityLine(_ session: AgentSession) -> some View {
    HStack(spacing: 0) {
        Color.clear.frame(width: s(NotchSpace.gutter))
        if let task = session.task {
            Text("\(session.taskLeadIn) · \(task)")
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                .lineLimit(1)
        } else {
            Text(session.isWaiting ? "Needs your attention" : "Monitoring this session")
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                .lineLimit(1)
        }
        Spacer(minLength: s(NotchSpace.snug))
    }
}
```

- [ ] **Step 2: Replace `agentMetricsLine` with the demoted single line**

Replace the whole `agentMetricsLine` function with:

```swift
/// Everything you consult rather than read: runtime, context, model, effort,
/// and the permission mode when it is surprising.
///
/// One line at tertiary weight, starting at the same left edge as every other
/// line in the row. This was three lines at two indents with three different
/// trailing edges, and the ragged right margin re-ragged per session because
/// the model tag and the permission capsule were both `fixedSize`.
@ViewBuilder
private func agentMetricsLine(_ session: AgentSession) -> some View {
    let meta = AgentRowMetadata(session)
    if meta.text != nil || meta.badge != nil {
        HStack(spacing: 0) {
            Color.clear.frame(width: s(NotchSpace.gutter))
            if let text = meta.text {
                Text(text)
                    .font(.system(size: textSize(NotchType.mono), weight: .medium,
                                  design: .monospaced))
                    .foregroundStyle(meta.isContextTight
                        ? Color.orange.opacity(0.9)
                        : .white.opacity(NotchOpacity.tertiary))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: s(NotchSpace.snug))
            if let badge = meta.badge {
                agentPermissionBadge(label: badge, isWarning: meta.badgeIsWarning)
            }
        }
    }
}
```

- [ ] **Step 3: Delete `agentModelTag` and reshape `agentPermissionBadge`**

Delete the entire `agentModelTag(_:)` function and its doc comment — the model and effort now live in the metadata line.

Replace `agentPermissionBadge(_:)` with:

```swift
/// Whether the agent will stop and ask — the one thing on the row that
/// says if it is safe to walk away from.
///
/// Only drawn when the answer is surprising. `default` is the mode where
/// the agent asks, which is what everyone already assumes, so a badge there
/// would be noise on every row and teach the eye to skip the badge
/// entirely. `bypass` and `auto-edit` are warned about; `plan` is the
/// cautious end of the scale and is drawn calmly.
private func agentPermissionBadge(label: String, isWarning: Bool) -> some View {
    let tint = isWarning ? Color.orange : Color.cyan
    return Text(label)
        .font(.system(size: textSize(8), weight: .semibold))
        .foregroundStyle(tint.opacity(0.95))
        .padding(.horizontal, s(NotchSpace.snug))
        .padding(.vertical, 1)
        .background(tint.opacity(0.16), in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(isWarning
            ? "Runs without asking: \(label)"
            : "Permission mode \(label)")
}
```

- [ ] **Step 4: Put the status dot in the gutter and open the vertical rhythm**

In `agentRow`, replace the title `HStack`'s leading `Circle()` and the `VStack` spacing so the dot occupies the gutter and the rows breathe:

```swift
private func agentRow(_ session: AgentSession) -> some View {
    Button {
        actions.focusAgentSession(session)
    } label: {
        VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            HStack(spacing: 0) {
                // The dot lives in the gutter every line below shares, so the
                // row has one left edge instead of three.
                Circle()
                    .fill(color(for: session.state))
                    .frame(width: s(5), height: s(5))
                    .frame(width: s(NotchSpace.gutter), alignment: .leading)
                if let symbol = session.vendorSymbol {
                    Image(systemName: symbol)
                        .font(font(size: NotchType.caption, weight: .semibold))
                        // Dimmer than the name: it answers "which tool",
                        // which you only ask once per row, and it must not
                        // compete with the task line for attention.
                        .foregroundStyle(.white.opacity(NotchOpacity.secondary))
                        .frame(width: s(9))
                        .accessibilityLabel(session.agentName)
                        .padding(.trailing, s(NotchSpace.snug))
                }
                Text(session.displayName)
                    .font(font(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize(horizontal: true, vertical: false)
                if let context = session.displayContext, !context.isEmpty {
                    Text(context)
                        .font(.system(size: textSize(NotchType.caption), weight: .medium,
                                      design: .monospaced))
                        .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                        .lineLimit(1)
                        .padding(.leading, s(NotchSpace.snug))
                }
                Spacer(minLength: s(NotchSpace.snug))
                agentStatusBadge(session)
            }
            agentActivityLine(session)
            agentMetricsLine(session)
        }
        .padding(.horizontal, s(NotchSpace.base))
        .padding(.vertical, s(NotchSpace.snug + 2))
        .background(color(for: session.state).opacity(session.isWaiting ? 0.12 : 0.06),
                    in: RoundedRectangle(cornerRadius: s(7), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: s(7), style: .continuous)
                .stroke(color(for: session.state).opacity(session.isWaiting ? 0.48 : 0.16),
                        lineWidth: 0.75)
        }
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

Extract the status pill that was inline into its own function, unchanged for now — Task 6 is the one that makes it morph:

```swift
/// The status pill at the row's trailing edge.
private func agentStatusBadge(_ session: AgentSession) -> some View {
    Text(session.statusLabel)
        .font(font(size: 8, weight: .bold))
        .foregroundStyle(color(for: session.state).opacity(0.95))
        .padding(.horizontal, s(5))
        .padding(.vertical, s(NotchSpace.tight))
        .background(color(for: session.state).opacity(0.14), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
}
```

- [ ] **Step 5: Run the whole suite**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'`

Expected: PASS. If anything referenced `agentModelTag`, this is where it surfaces — fix the call site rather than restoring the function.

- [ ] **Step 6: Look at it at both scale extremes**

Run: `NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh`, launch `NotchPill Dev.app`, open the panel with agent sessions running.

Check, at the smallest and the largest pill size and readability settings:
- every text line in a row starts at the same x
- the right margin does not move between rows with different models or permission modes
- the metadata line truncates with an ellipsis rather than pushing the badge off the card

- [ ] **Step 7: Commit**

```bash
git add NotchPill/Views/Tiles.swift
git commit -m "feat: give the agent row one left edge and one right column

A row drew three text lines at three left edges — the card's edge, a
glyph plus a gap, and a hardcoded 12pt indent — and three right edges,
two of them fixedSize, so the right margin re-ragged for every session
with a different model or permission mode. The status dot now occupies a
named gutter every line shares, and runtime, context, model and effort
collapse into one tertiary line."
```

---

### Task 6: Morph the status badge

**Files:**
- Modify: `NotchPill/Views/Tiles.swift` — `agentStatusBadge` and its enclosing view struct
- Test: manual, plus the existing suite

**Interfaces:**
- Consumes: `NotchMotion.settle(reduceMotion:)` (Task 1), `agentStatusBadge` (Task 5).
- Produces: no new symbols. A `@Namespace private var agentBadgeNamespace` is added to the view struct that owns `agentRow`.

**Known risk, stated in the spec:** `matchedGeometryEffect` may glitch or silently no-op across the collapse/expand boundary, because collapsed and expanded content live in different branches of a `ZStack` driven by `expansionProgress` rather than in a shared namespace. Within one agent row, both badge states are siblings under a single `ForEach`, so it should hold. **If it does not hold, the fallback is Step 4 — take it, and say so in the commit body. Do not quietly drop the effect and commit as though it shipped.**

- [ ] **Step 1: Find the view struct that owns `agentRow` and add the namespace**

Run: `grep -n "private func agentRow" NotchPill/Views/Tiles.swift` then scan upward for the enclosing `struct ... : View {`.

Add, next to its other stored properties:

```swift
/// Lets the status pill travel between states instead of cross-fading. This
/// is the state the user actually watches change, so it is the one worth
/// spending a transition on.
@Namespace private var agentBadgeNamespace
```

- [ ] **Step 2: Make the badge morph**

Replace `agentStatusBadge` with:

```swift
/// The status pill at the row's trailing edge.
///
/// Keyed on the session rather than on the label, so SwiftUI treats
/// `working` becoming `idle 18m` as one view changing rather than two views
/// swapping. `.contentTransition(.numericText())` covers the digits inside
/// an aging label — `idle 18m` to `idle 19m` should not blink.
private func agentStatusBadge(_ session: AgentSession) -> some View {
    Text(session.statusLabel)
        .font(font(size: 8, weight: .bold))
        .foregroundStyle(color(for: session.state).opacity(0.95))
        .contentTransition(.numericText())
        .padding(.horizontal, s(5))
        .padding(.vertical, s(NotchSpace.tight))
        .background(color(for: session.state).opacity(0.14), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .matchedGeometryEffect(id: session.id, in: agentBadgeNamespace)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.statusLabel)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.state)
}
```

If `reduceMotion` is not already in scope in this struct, add:

```swift
@Environment(\.accessibilityReduceMotion) private var reduceMotion
```

(`Tiles.swift:391` shows the exact form already used elsewhere in this file.)

- [ ] **Step 3: Build, run the suite, and watch a real state change**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'`

Expected: PASS.

Then `NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh`, launch the dev app, and watch a session go from working to idle with the panel open.

Expected: the pill resizes and its text settles rather than blinking. Also toggle System Settings → Accessibility → Display → Reduce Motion and confirm the change becomes instant.

- [ ] **Step 4: Fallback, only if Step 3 glitches**

If the badge jumps, flickers, or lands in the wrong place, remove the `.matchedGeometryEffect` line and keep the rest:

```swift
        .fixedSize(horizontal: true, vertical: false)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.statusLabel)
        .animation(NotchMotion.settle(reduceMotion: reduceMotion), value: session.state)
```

The frame still animates under `settle` and the digits still transition; only the explicit geometry match is gone. Record what you saw in the commit body.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Views/Tiles.swift
git commit -m "feat: let the agent status pill move between states

working becoming idle 18m was a cross-fade, so the one thing on the card
the user actually watches change was also the thing that changed least
visibly. The pill now resizes under settle and its digits transition
rather than blinking."
```

---

### Task 7: Ship it and look at it together

**Files:**
- Modify: `NotchPill.xcodeproj/project.pbxproj` (`MARKETING_VERSION`, 4 occurrences)

This is not a release task — it is the gate the whole plan exists for. The spec says the aesthetic verdict is the user's, off a build.

- [ ] **Step 1: Run the full suite one more time**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'`

Expected: PASS, no skips.

- [ ] **Step 2: Build and install the dev app**

Run: `NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh`

The `NOTCHPILL_SIGN_IDENTITY` variable is not optional. Without it `build-release.sh` and `build-dev.sh` fall back to ad-hoc signing, which produces a different code identity every build, and macOS silently revokes the Accessibility grant that the keyboard monitors depend on. The symptom looks like an app bug, not a signing one.

- [ ] **Step 3: Kill any old instance before launching**

```bash
pkill -f "NotchPill Dev" || true
open "$HOME/Applications/NotchPill Dev.app" 2>/dev/null || open ./build-dev/"NotchPill Dev.app"
```

A change that "does not work" in this project is usually an old binary still running.

- [ ] **Step 4: Show the user and stop**

Present the agents card and ask directly whether the vocabulary is right — the motion, the single left edge, the demoted metadata line.

Do **not** migrate any other card. That is the explicit rollout decision in the spec: if the vocabulary is wrong, only one card was spent finding out. Rolling it out is a new request, and it gets its own plan.

- [ ] **Step 5: Version bump and release only if the user asks**

If and only if the user asks to cut a release, bump `MARKETING_VERSION` in all four places in `NotchPill.xcodeproj/project.pbxproj`, tag `v<version>`, and follow `docs/RELEASING.md`.
