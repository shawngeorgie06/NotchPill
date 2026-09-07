# Notch Panel Composed Shelf Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the expanded island read as a composed tray of objects — painted depth on the surface, and the agents page rebuilt as a strip of session tiles with one jump well — without glass, hue changes, or touching the open/close geometry.

**Architecture:** New tokens (`NotchSpace.well`/`tile`, `NotchRadius`, `NotchOpacity.wellFill`/`highlight`/`rim`) land in `NotchTheme.swift`. `NotchDesign.swift` paints a gradient rim on `PillSurface`/`ExpandedPillSurface` and a top-edge highlight only where the pill has a real top edge (no hardware notch). A pure `AgentShelf` value decides the caption and the jump target; `agentsCard` in `Tiles.swift` draws tiles from it. `NotchContentLayout` budgets the agents page as one fixed shelf height instead of N list rows.

**Tech Stack:** Swift 6, SwiftUI, AppKit, Swift Testing (`@Suite`/`@Test`/`#expect`), Xcode project with `PBXFileSystemSynchronizedRootGroup` (new files under `NotchPill/Views/` compile without a pbxproj edit).

**Spec:** `docs/superpowers/specs/2026-09-06-notch-panel-composed-shelf-design.md`

## Global Constraints

- Never edit `NotchPill.xcodeproj/project.pbxproj`.
- Every card dimension goes through `s(_:)`; every font size through `textSize(_:)` or `font(size:)`. No `s(NotchSpace.snug + 2)` expressions.
- New literals go in `NotchTheme.swift` and onto each enum's `all`. Existing literals already in `Tiles.swift` (0.12 / 0.48 waiting tint, `s(5)` dot) may stay.
- `expandAnimation` and `contentFadeAnimation` in `NotchRootView.swift` are untouched.
- Fill stays `Color.black`. No `NSVisualEffectView`, no `ultraThinMaterial`.
- `color(for:)` on `AgentSession.State` is unchanged.
- Only `agentsCard` changes in `Tiles.swift`. Other cards keep their layouts.
- Test command: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/<Suite>`.
- All tests live in `NotchPillTests/NotchPillTests.swift`; append suites at the end.
- Commit after every task: `type: subject` line plus a prose body saying why.

Spec amendments made while planning (recorded here, applied to the spec in Task 1):

1. Top-edge highlight is drawn only on the free-floating pill (`topRadius > 0`). On notched hardware the pill's top edge is the seam with the cutout, and a 14% line there reads as a crack under the notch. The rim on the notched pill is instead a vertical gradient — `hairline` at the top, `rim` at the bottom curve — so the light still comes from above without lighting the seam.
2. `NotchSpace.tile` (72) is added as the tile width. A horizontal strip needs a fixed tile width; a flexible one has nothing to measure against inside a `ScrollView`.
3. The tile carries `statusLabel` as a tertiary caption under the name ("idle 18m"). The dot still carries the state colour; the caption carries the age the old capsule carried, the way Droppy's tile carries "4 weeks ago".
4. `ExpandedView` top inset is `NotchSpace.base`, not `roomy`: the deck height budget has 10pt of slack for top+bottom padding and `roomy + tight` would exceed it.

---

### Task 1: Tokens

**Files:**
- Modify: `NotchPill/Views/NotchTheme.swift`
- Modify: `docs/superpowers/specs/2026-09-06-notch-panel-composed-shelf-design.md` (record the four amendments above)
- Test: `NotchPillTests/NotchPillTests.swift` (`NotchTokenScaleTests`, ~line 9320)

**Interfaces:**
- Produces: `NotchSpace.well: CGFloat = 22`, `NotchSpace.tile: CGFloat = 72`, `enum NotchRadius { well 6, tile 14, all }`, `NotchOpacity.wellFill 0.06`, `.highlight 0.14`, `.rim 0.18`.

- [ ] **Step 1: Write the failing tests** — add to `NotchTokenScaleTests`:

```swift
    @Test("radius roles are distinct and the tile is rounder than its well")
    func radii() {
        #expect(Set(NotchRadius.all).count == NotchRadius.all.count)
        #expect(NotchRadius.tile > NotchRadius.well)
    }

    @Test("chrome opacities sit between hairline and tertiary")
    func chromeOpacities() {
        // A well fill brighter than a separator would make every tile a box
        // again; a rim brighter than tertiary text would outrank the copy.
        #expect(NotchOpacity.wellFill < NotchOpacity.hairline)
        #expect(NotchOpacity.hairline < NotchOpacity.highlight)
        #expect(NotchOpacity.highlight < NotchOpacity.rim)
        #expect(NotchOpacity.rim < NotchOpacity.tertiary)
    }

    @Test("a tile is wide enough for its well and padding")
    func tileHoldsWell() {
        #expect(NotchSpace.tile > NotchSpace.well + NotchSpace.base * 2)
        #expect(NotchSpace.all.contains(NotchSpace.well))
        #expect(NotchSpace.all.contains(NotchSpace.tile))
    }
```

- [ ] **Step 2: Run** `-only-testing:NotchPillTests/NotchTokenScaleTests` — expect build failure, `NotchRadius` not in scope.
- [ ] **Step 3: Implement** in `NotchTheme.swift`: add `well`, `tile` to `NotchSpace` and its `all`; add `enum NotchRadius`; add `wellFill`, `highlight`, `rim` to `NotchOpacity` and its `all`.
- [ ] **Step 4: Run** the suite — expect PASS.
- [ ] **Step 5: Amend the spec** with the four items above, then commit: `feat: add well, tile, radius and chrome opacity tokens`.

---

### Task 2: Painted island chrome

**Files:**
- Modify: `NotchPill/Views/NotchDesign.swift` (`pillStroke`, `PillSurface`, `ExpandedPillSurface`)
- Modify: `NotchPill/Views/NotchRootView.swift:509-511` (`ExpandedView` padding)

**Interfaces:**
- Consumes: `NotchOpacity.hairline/highlight/rim`, `NotchSpace.base/roomy/tight`.
- Produces: `enum NotchIslandChrome { static var rim: LinearGradient; static var highlight: some View }`.

- [ ] **Step 1: Implement** in `NotchDesign.swift`:

```swift
/// Painted depth for the opaque island. Not a material: the surface stays
/// `Color.black` so it reads as one object with the hardware cutout.
enum NotchIslandChrome {
    /// Hairline at the top and the full rim at the bottom curve. On notched
    /// hardware the top edge is the seam with the cutout, and a bright line
    /// there reads as a crack under the notch; the light still comes from
    /// above, it just does not land on the seam.
    static var rim: LinearGradient {
        LinearGradient(colors: [.white.opacity(NotchOpacity.hairline),
                                .white.opacity(NotchOpacity.rim)],
                       startPoint: .top, endPoint: .bottom)
    }

    /// The sheen along a real top edge, gone within `NotchSpace.base`. Only
    /// drawn where the pill has one — the free-floating island.
    static var highlight: some View {
        LinearGradient(colors: [.white.opacity(NotchOpacity.highlight), .clear],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: NotchSpace.base)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}
```

`pillStroke` becomes `Color.white.opacity(NotchOpacity.rim)`. Both surfaces:

```swift
        shape
            .fill(Color.black)
            .overlay {
                if hasTopEdge { NotchIslandChrome.highlight.clipShape(shape) }
            }
            .overlay { shape.stroke(NotchIslandChrome.rim, lineWidth: 0.5) }
```

where `hasTopEdge` is `topRadius > 0` on `PillSurface` and `!hasPhysicalNotch` on `ExpandedPillSurface`.

- [ ] **Step 2: `ExpandedView`** padding: `.padding(.horizontal, NotchSpace.roomy * readability)`, `.padding(.top, NotchSpace.base * readability)`, `.padding(.bottom, NotchSpace.tight * readability)`.
- [ ] **Step 3: Build** `xcodebuild build -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS'` — expect success. Run `NotchRectTests` (uses `NotchShape`) to confirm nothing moved.
- [ ] **Step 4: Commit**: `feat: paint a rim and top highlight on the island`.

---

### Task 3: `AgentShelf` value

**Files:**
- Create: `NotchPill/Views/AgentShelf.swift`
- Test: append `@Suite("AgentShelf")` to `NotchPillTests/NotchPillTests.swift`

**Interfaces:**
- Consumes: `AgentSession` (`isWaiting`, `isCompleted`, `state`).
- Produces: `struct AgentShelf: Equatable { let caption: String?; let jumpTarget: AgentSession?; init(_ sessions: [AgentSession]) }`.

- [ ] **Step 1: Failing tests**

```swift
@Suite("AgentShelf")
struct AgentShelfTests {
    private func session(_ id: String, _ state: AgentSession.State) -> AgentSession {
        AgentSession(id: id, agent: "claude-code", project: "p", state: state, lastActivity: Date())
    }

    @Test("an empty shelf has no caption and nowhere to jump")
    func empty() {
        let shelf = AgentShelf([])
        #expect(shelf.caption == nil)
        #expect(shelf.jumpTarget == nil)
    }

    @Test("the caption counts states in a fixed order")
    func caption() {
        let shelf = AgentShelf([session("a", .completed(since: Date())),
                                session("b", .idle(since: Date())),
                                session("c", .working),
                                session("d", .waiting(since: nil)),
                                session("e", .working)])
        #expect(shelf.caption == "1 needs you · 2 working · 1 idle · 1 completed")
    }

    @Test("the jump well prefers waiting, then working, then whatever is first")
    func jumpTarget() {
        let idle = session("i", .idle(since: Date()))
        let working = session("w", .working)
        let waiting = session("x", .waiting(since: nil))
        #expect(AgentShelf([idle, working, waiting]).jumpTarget?.id == "x")
        #expect(AgentShelf([idle, working]).jumpTarget?.id == "w")
        #expect(AgentShelf([idle]).jumpTarget?.id == "i")
    }
}
```

- [ ] **Step 2: Run** `-only-testing:NotchPillTests/AgentShelfTests` — build failure, `AgentShelf` not in scope.
- [ ] **Step 3: Implement** `NotchPill/Views/AgentShelf.swift`:

```swift
import Foundation

/// What the agents page says above its tiles and where its one action goes.
///
/// The old card built the summary inline and hinted "tap to jump" at every
/// row. A shelf has one well, so choosing its target is a content decision
/// worth testing: the session blocked on you, else one that is working,
/// else the first — never nothing while there is a session to reach.
struct AgentShelf: Equatable {
    /// "1 needs you · 2 working". Nil when there is nothing to count.
    let caption: String?
    /// Where the jump well takes you.
    let jumpTarget: AgentSession?

    init(_ sessions: [AgentSession]) {
        let working = sessions.filter { if case .working = $0.state { return true }; return false }
        let idle = sessions.filter { if case .idle = $0.state { return true }; return false }
        let waiting = sessions.filter(\.isWaiting)
        let completed = sessions.filter(\.isCompleted)
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
```

- [ ] **Step 4: Run** the suite — PASS.
- [ ] **Step 5: Commit**: `feat: model the agents shelf caption and jump target as a value`.

---

### Task 4: Fixed shelf height in the layout budget

**Files:**
- Modify: `NotchPill/Core/NotchContentLayout.swift:748, 794-795, 846`
- Test: `NotchPillTests/NotchPillTests.swift` `ExpandedHeightTests` (~3817-3890)

**Interfaces:**
- Produces: `NotchContentLayout.agentsShelf: CGFloat = 88`. Removes `agentsHeader`, `agentsRow`. `expandedContentCeiling` becomes the literal `144`.

- [ ] **Step 1: Rewrite the tests that encode the list model.** Replace `reportedCase`, `threeRowsFit`, and `growsThenCaps` with:

```swift
    // A horizontal strip scrolls sideways, so a tenth session must not make
    // the notch taller than a first.
    @Test("the agents shelf is one height however many sessions it holds")
    func shelfHeightIsFixed() {
        let one = NotchContentLayout.expandedContentBaseHeight([agents(1)])
        let three = NotchContentLayout.expandedContentBaseHeight([agents(3)])
        let ten = NotchContentLayout.expandedContentBaseHeight([agents(10)])
        #expect(one == NotchContentLayout.agentsShelf)
        #expect(three == one)
        #expect(ten == one)
    }

    @Test("the shelf fits under the ceiling other cards still cap at")
    func shelfUnderCeiling() {
        #expect(NotchContentLayout.agentsShelf < NotchContentLayout.expandedContentCeiling)
    }
```

`tallestWins` and `clamped` stay as they are.

- [ ] **Step 2: Run** `-only-testing:NotchPillTests/ExpandedHeightTests` — build failure on `agentsShelf`.
- [ ] **Step 3: Implement.** In `NotchContentLayout.swift`:

```swift
    /// The cap on a card's height. This was two rows of the old agents list,
    /// and clipboard and terminal cards still cap here; the number stays so
    /// they do not move when the agents page stops being a list.
    static let expandedContentCeiling: CGFloat = 144
```

replace `agentsHeader`/`agentsRow` with:

```swift
    /// The agents page as a shelf: a caption over one row of tiles that
    /// scrolls sideways, so its height is independent of session count.
    ///
    /// Caption 14 + 4 gap, then a tile of 8 pad, 22 well, 4, ~14 name, 4,
    /// ~12 status, 8 pad = 72. Total 88, well under the 144 ceiling.
    static let agentsShelf: CGFloat = 88
```

and `case .agents: return agentsShelf`.

- [ ] **Step 4: Run** `ExpandedHeightTests` and `DeckPageHeightTests` — PASS.
- [ ] **Step 5: Commit**: `feat: budget the agents page as one shelf height`.

---

### Task 5: Draw the shelf

**Files:**
- Modify: `NotchPill/Views/Tiles.swift` — `agentsCard` (~1115-1172), `agentRow` and helpers (~1752-1921), `agentBadgeNamespace` (~1003).

**Interfaces:**
- Consumes: `AgentShelf`, tokens from Task 1, `color(for: AgentSession.State)`, `actions.focusAgentSession`.

- [ ] **Step 1: Replace `agentsCard`:**

```swift
    /// The agents page is a shelf, not a list: one row of session tiles that
    /// scrolls sideways, and one well to jump to the session that wants you.
    private func agentsCard(_ sessions: [AgentSession]) -> some View {
        let shelf = AgentShelf(sessions)
        return VStack(alignment: .leading, spacing: s(NotchSpace.snug)) {
            // Same slot every other card's header occupies, so the first line
            // of tiles shares a baseline with the first line of any other card.
            Text(shelf.caption ?? "")
                .font(font(size: NotchType.caption, weight: .medium))
                .foregroundStyle(.white.opacity(NotchOpacity.tertiary))
                .lineLimit(1)
                .frame(height: headerHeight, alignment: .leading)
            HStack(spacing: s(NotchSpace.base)) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: s(NotchSpace.snug)) {
                        ForEach(sessions) { session in
                            agentTile(session)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                if let target = shelf.jumpTarget {
                    agentJumpWell(target)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
```

- [ ] **Step 2: Replace `agentRow`, `agentStatusBadge`, `agentActivityLine`, `agentMetricsLine`, `agentPermissionBadge`** with `agentTile`, `agentVendorWell`, `agentJumpWell` (code in the executing commit; tile is `s(NotchSpace.tile)` wide, padded `s(NotchSpace.base)`, `NotchRadius.tile` continuous rect filled `wellFill` and stroked `hairline`; waiting keeps `tint.opacity(0.12)` / `tint.opacity(0.48)`; well is `s(NotchSpace.well)` square at `NotchRadius.well`; jump well is a `Circle` of `s(NotchSpace.well)` stroked at `rim`). Remove `@Namespace private var agentBadgeNamespace`.
- [ ] **Step 3: Build and run the whole test target** — PASS.
- [ ] **Step 4: Install** `NOTCHPILL_SIGN_IDENTITY="NotchPill Self-Signed" ./Scripts/build-dev.sh`.
- [ ] **Step 5: Commit**: `feat: draw the agents page as a shelf of session tiles`.
