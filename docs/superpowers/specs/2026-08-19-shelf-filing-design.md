# Shelf Filing — implementation spec

Date: 2026-08-19
Status: approved, not implemented
Audience: an implementing agent with no prior context on this repo

---

## 0. Read this first — the current shelf is half-wired

`NotchPill/Views/Tiles.swift` defines two views, `ShelfTile` (line 192) and
`ShelfChip` (line 255), which between them implement drag-out, remove, AirDrop
via `ShareLink`, and Reveal in Finder.

**Neither view is ever instantiated.** `ShelfTile` is referenced only by its own
declaration; `ShelfChip` only by `ShelfTile`. Verify before starting:

```bash
grep -rn "ShelfTile\|ShelfChip" --include="*.swift" .
```

Every hit will be inside `Tiles.swift`. This is dead code.

What the user actually sees is `shelfCard(count:names:)` (`Tiles.swift:1810`) —
a static card reading "3 files" with up to three filenames. No interaction of
any kind. Files can go onto the shelf and never come off it except by editing
`UserDefaults`.

So the shelf is not a feature that needs polishing. It is a working data layer
(`ShelfStore`) behind a read-only label. This spec wires it up and adds filing.

**Do not delete `ShelfTile`/`ShelfChip` and start over.** Their internals
(`.onDrag` with `NSItemProvider(contentsOf:)`, the `ShareLink`, the hover ✕) are
correct and should be lifted into the new card. Only their placement is wrong —
see §5 for why they cannot simply be dropped into the deck as-is.

---

## 1. Goal

Let the user drop a file on the notch and send it to a folder without opening
Finder. Concretely: drop → the file appears as a chip → click the chip → pick a
destination → the file moves there → a 10-second Undo is offered.

### Non-goals

- Choosing the destination *during* the drag (release onto a folder target).
  Rejected: doubles the drag-time UI surface in a very small window.
- Rule-based auto-filing (`*.png` → Screenshots). Configuring rules is Finder
  browsing moved earlier, not removed.
- Inferred destinations from the frontmost app.
- Reading Finder **sidebar favorites**. Already investigated and ruled out:
  `~/Library/Application Support/com.apple.sharedfilelist/` is empty on the
  target machine and the `LSSharedFileList` API for it is deprecated. Do not
  attempt this. Finder **Recents** is used instead (§3.1) and does work.
- Copy semantics or a per-action move/copy prompt. Move is the behaviour.
- Cutting a release, bumping `MARKETING_VERSION`, or tagging.

---

## 2. Repo conventions you must follow

| Thing | Convention |
|---|---|
| Tests | **Swift Testing** — `import Testing`, `@Suite`, `@Test`, `#expect`. Not XCTest. |
| Test file | Everything goes in `NotchPillTests/NotchPillTests.swift`. Match the existing `@Suite("Name") struct NameTests` style. |
| New files | The `.xcodeproj` uses `PBXFileSystemSynchronizedRootGroup`. **Files under `NotchPill/` are picked up automatically — do not edit `project.pbxproj`.** |
| Deployment target | macOS 14.0. `ShareLink` and `.onDrag` are available; no availability guards needed. |
| Concurrency | UI/state classes are `@MainActor final class … : ObservableObject`. Pure logic is an `enum` with `static` funcs, no state. |
| Persistence | Security-scoped bookmark `Data` arrays in `UserDefaults`, injectable for tests. Copy `ShelfStore.save()`/`load()` exactly. |
| Build | `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill build` |
| Test | `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill test` |

### Hard constraints

- **Never run `Scripts/install-agent-hooks.sh`.** It rewrites
  `~/.claude/settings.json`, `~/.codex/config.toml` and `~/.cursor/hooks.json`
  to point at a dev bundle that is later deleted. It has broken the user's agent
  notifications twice. Nothing in this spec needs it.
- **Do not quit or replace `/Applications/NotchPill.app`.** Use
  `./Scripts/build-dev.sh` if you need a running build; it installs separately as
  `NotchPill Dev.app`.
- Do not bump the version or tag a release.

---

## 3. Architecture

Four new files plus targeted edits. Each new unit is pure or near-pure so it can
be tested without a running app.

```
NotchPill/Core/FinderRecentFolders.swift   (new, ~45 loc)  pure
NotchPill/Core/FileDestination.swift       (new, ~90 loc)  DestinationStore
NotchPill/Core/ShelfFiler.swift            (new, ~110 loc) pure, destructive
NotchPill/Core/ShelfStore.swift            (edit)          filing + undo state
NotchPill/Core/Models.swift                (edit)          .shelf payload
NotchPill/Views/NotchActions.swift         (edit)          3 callbacks
NotchPill/Views/Tiles.swift                (edit)          shelfCard rewrite
NotchPill/Views/NotchRootView.swift        (edit)          wire callbacks
NotchPill/Core/NotchContentSnapshot.swift  (edit)          pass items
NotchPill/Core/Settings.swift              (edit)          default flip
NotchPill/Views/PreferencesView.swift      (edit)          pinned folders UI
```

### 3.1 `FinderRecentFolders.swift` (new)

```swift
import Foundation

/// Finder's "Recent Folders" list, read from its own defaults domain.
///
/// The stored value is an array of dictionaries with a `file-bookmark` Data
/// entry — the same bookmark format ShelfStore already resolves, so no new
/// serialization concept enters the codebase.
enum FinderRecentFolders {
    static let defaultsKey = "FXRecentFolders"

    /// Resolves each bookmark, dropping entries that no longer resolve or are
    /// not directories. A stale Finder recent is not an error.
    static func load(
        defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.finder"),
        limit: Int = 6
    ) -> [URL]
}
```

Implementation notes:

- Read `defaults?.array(forKey: defaultsKey) as? [[String: Any]]`.
- For each element take `["file-bookmark"] as? Data`, resolve with
  `URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` exactly
  as `ShelfStore.load()` does.
- Keep only entries where `isDirectory` resource value is `true`.
- Return at most `limit`, preserving Finder's order (most recent first).
- Any failure anywhere returns `[]`. This is an undocumented plist read; it must
  degrade to "pinned only", never throw or crash.

### 3.2 `FileDestination.swift` (new)

```swift
import Foundation

struct FileDestination: Identifiable, Equatable, Hashable {
    enum Source: Equatable { case pinned, recent }
    let url: URL
    let source: Source
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class DestinationStore: ObservableObject {
    @Published private(set) var pinned: [URL] = []

    init(defaults: UserDefaults = .standard,
         recents: @escaping () -> [URL] = { FinderRecentFolders.load() })

    /// Pinned first, then Finder recents. Resolved lazily at call time so a
    /// folder deleted since launch simply stops appearing.
    func destinations() -> [FileDestination]

    func pin(_ url: URL)
    func unpin(_ url: URL)
    func movePinned(from: IndexSet, to: Int)
}
```

Rules:

- Pinned wins on duplicates: a folder that is both pinned and recent appears
  once, under `.pinned`.
- Pinned persists as `[Data]` bookmarks under key `"shelfPinnedFolders"`.
- Non-existent pinned folders are filtered from `destinations()` but **not**
  removed from storage — an unmounted volume should come back, not be forgotten.
- `recents` is injected so tests never touch the real Finder domain.

### 3.3 `ShelfFiler.swift` (new)

This is the only destructive code in NotchPill. It has no state, no `@Published`,
and no UI dependency, so it is fully testable against a temp directory.

```swift
import Foundation

enum ShelfFiler {
    struct UndoToken: Equatable {
        let from: URL      // where the file was before filing
        let to: URL        // where it ended up (post-collision-rename)
    }

    enum FilingError: Error, Equatable {
        case sourceMissing(URL)
        case destinationUnwritable(URL)   // TCC denial or permissions
        case destinationNotADirectory(URL)
        case undoConflicted               // something changed under us
        case moveFailed(String)           // underlying error, as a message
    }

    @discardableResult
    static func file(_ url: URL, into folder: URL) throws -> UndoToken

    static func undo(_ token: UndoToken) throws
}
```

Required behaviour — each maps to a test in §6:

1. **Collision.** If `folder/name.ext` exists, insert a numeric suffix before the
   extension, matching Finder: `report.pdf` → `report 2.pdf` → `report 3.pdf`.
   Never overwrite. Never use `replaceItem`.
2. **Extensionless and dotfile names.** `README` → `README 2`;
   `.env` is treated as a name with no extension, → `.env 2`.
3. **Source missing.** Throw `.sourceMissing` before touching anything.
4. **Destination not writable.** `FileManager.isWritableFile(atPath:)` is not
   sufficient under TCC — attempt the move and map a thrown `NSError` with
   `NSFileWriteNoPermissionError` to `.destinationUnwritable`. The source must be
   untouched when this throws.
5. **Cross-volume.** `FileManager.moveItem` performs copy+delete. After it
   returns, confirm the source no longer exists; if it does, throw `.moveFailed`
   rather than returning a token that would make Undo destructive.
6. **Undo.** Verify `token.to` exists **and** nothing occupies `token.from`. If
   either check fails, throw `.undoConflicted` — do not guess, do not overwrite.

### 3.4 `ShelfStore.swift` (edit)

Add filing, plus the single-slot undo receipt that drives the toast.

```swift
struct ShelfFilingReceipt: Equatable {
    let token: ShelfFiler.UndoToken
    let destinationName: String       // leaf folder name, for the toast
    let itemName: String
    let expiresAt: Date
}

// on ShelfStore:
@Published private(set) var receipt: ShelfFilingReceipt?   // nil when none/expired
@Published private(set) var lastError: String?             // nil when none

func fileItem(id: UUID, into folder: URL)
func undoLastFiling()
func dismissReceipt()
```

- `fileItem` calls `ShelfFiler.file`, and on success removes the item, saves, and
  sets `receipt` with `expiresAt = .now + 10`.
- On failure it sets `lastError` to a short human string and leaves the item in
  place. `lastError` clears after 6 seconds.
- Expiry is driven by a single `Timer` scheduled on the main run loop; cancel and
  reschedule on each new filing. Only one receipt exists at a time — filing a
  second item replaces the first receipt (documented limitation, §8).
- `undoLastFiling()` calls `ShelfFiler.undo`, re-adds the item to the shelf on
  success, and clears the receipt. On failure it sets `lastError`.

### 3.5 `Models.swift` (edit) — the payload

The expanded deck is snapshot-driven: `ExpandedActivity` is a value enum carrying
plain data, and cards are rendered from it. **Do not pass `ShelfStore` into the
card.** Change the payload instead.

Current:

```swift
case shelf(count: Int, names: [String])                    // line 699
case .shelf: return "shelf"                                // id, line 720
case .shelf(let count, _): return "shelf-\(count)"         // contentKey, line 753
```

New:

```swift
struct ShelfCardItem: Identifiable, Equatable, Hashable {
    let id: UUID
    let name: String
    let url: URL
}

case shelf(items: [ShelfCardItem], receipt: ShelfFilingReceipt?, error: String?)
```

- `id` stays `"shelf"` — it is subject identity, and changing it destroys and
  recreates the view.
- `contentKey` becomes
  `"shelf-\(items.map(\.name).joined(separator: "|"))-\(receipt?.itemName ?? "")-\(error ?? "")"`.
  **Do not include `expiresAt` or any timestamp** — a per-second-changing
  `contentKey` re-animates the whole deck every tick.

> **Why this matters.** `ExpandedActivity.id` previously included volatile
> content, and because `NotchRootView` applies `.id(activities[page].id)` with a
> `.transition`, every content change destroyed and rebuilt the card, firing a
> slide animation. That was a real shipped bug (the "pause slides like a track
> skip" bug). Keep `id` subject-only and put volatile content in `contentKey`.

Deliberately **no `NSImage` in the payload** — it would wreck `Equatable` and the
`contentKey` comparison. The view resolves icons at render time via
`NSWorkspace.shared.icon(forFile:)`, which is internally cached.

### 3.6 `NotchContentSnapshot.swift` (edit)

`expandedActivities` currently receives `shelfCount: Int, shelfNames: [String]`.
Replace both with `shelfItems: [ShelfCardItem]`, and add
`shelfReceipt: ShelfFilingReceipt?` and `shelfError: String?`.

The gating line in `Tiles.swift:985` is currently:

```swift
if showShelf, shelfCount > 0 { items.append(.shelf(count: shelfCount, names: shelfNames)) }
```

It must become:

```swift
if showShelf, !shelfItems.isEmpty || shelfReceipt != nil || shelfError != nil {
    items.append(.shelf(items: shelfItems, receipt: shelfReceipt, error: shelfError))
}
```

**This is load-bearing.** Filing the last item empties the shelf; under the old
condition the card would vanish and take the Undo button with it. The card must
survive while a receipt or error is live.

Also drop the `.prefix(3)` currently applied at
`NotchContentSnapshot.swift:58` — the card now scrolls and shows everything.

### 3.7 `NotchActions.swift` (edit)

Follow the existing default-valued closure style:

```swift
/// Move a shelf item into a folder.
var fileShelfItem: (UUID, URL) -> Void = { _, _ in }
/// Drop a shelf item without filing it.
var removeShelfItem: (UUID) -> Void = { _ in }
/// Put the most recently filed item back where it came from.
var undoShelfFiling: () -> Void = {}
```

Wire them in `NotchRootView.swift` beside the existing `onCancelTimer:` at
line ~524, calling straight through to `shelf`.

---

## 4. UI specification

All sizes go through the existing `s(_:)` scaling helper and `font(size:weight:)`
(`Tiles.swift:1000-1001`). Never hardcode a raw `.font(.system(size:))` inside
the card.

### 4.1 Card with items

Replaces `shelfCard(count:names:)` at `Tiles.swift:1810`.

```
┌──────────────────────────────────────────┐
│ 🗂 Shelf                            ⇪  ✕ │   header
│ ┌──────┐ ┌──────┐ ┌──────┐               │
│ │ 📄   │ │ 🖼   │ │ 📄   │   →  scrolls   │
│ │report│ │shot  │ │notes │               │
│ └──────┘ └──────┘ └──────┘               │
└──────────────────────────────────────────┘
```

- **Header** — `Label("Shelf", systemImage: "tray.full")`, `font(size: 11,
  weight: .medium)`, `.white.opacity(0.45)`. Matches every other card header.
- Trailing header controls, only when items exist:
  `ShareLink(items:)` with `square.and.arrow.up` at `font(size: 10)`,
  `.white.opacity(0.55)`; then a clear-all `xmark.circle.fill` at
  `font(size: 10)`, `.white.opacity(0.35)`. Lift both from `ShelfTile:200-213`.
- **Chips** in a horizontal `ScrollView(showsIndicators: false)`, spacing `s(6)`,
  card height `s(46)`.
- **Chip**: `VStack(spacing: s(2))` of a `s(24)`-square icon and the filename at
  `font(size: 9)`, `.white.opacity(0.6)`, `lineLimit(1)`,
  `.truncationMode(.middle)`, `frame(width: s(40))`.
  Background `RoundedRectangle(cornerRadius: s(6), style: .continuous)` filled
  `.white.opacity(0.06)`; on hover `0.12`.
- **Hover ✕** at `.topTrailing`, `offset(x: s(4), y: -s(4))`, calls
  `removeShelfItem`. Lift from `ShelfChip:274-284`.
- **`.onDrag`** — keep `NSItemProvider(contentsOf: item.url) ?? NSItemProvider()`
  verbatim from `ShelfChip:286`. This is what makes drag-to-any-app work.
- **Left click** opens the destination popover (§4.3).
- **Right click** keeps a context menu: `Move to…` (opens the same popover),
  `Share / AirDrop…`, `Reveal in Finder`, `Remove`.

Truncate filenames in the **middle**, not the tail — `report-final-v3.pdf` and
`report-final-v4.pdf` are indistinguishable when truncated at the end.

### 4.2 Empty card

Only rendered when a receipt or error is live (otherwise the card is not built at
all — §3.6). Show the toast row alone, no dashed drop zone. The dashed
"Drop files" placeholder from `ShelfTile:223-237` is **not** used in the deck; an
empty shelf shows no card.

### 4.3 Destination popover

```
┌────────────────────────┐
│ PINNED                 │
│  📁 Desktop            │
│  📁 Projects           │
├────────────────────────┤
│ RECENT (FINDER)        │
│  🕒 Downloads          │
│  🕒 docs               │
├────────────────────────┤
│  📂 Other Folder…      │
└────────────────────────┘
```

- SwiftUI `.popover(isPresented:arrowEdge: .bottom)` anchored to the chip.
- Section headers: `font(size: 9, weight: .medium)`, `.white.opacity(0.35)`,
  uppercase — deliberately quieter than the 0.6 chip label.
- Rows: folder icon via `NSWorkspace.shared.icon(forFile:)` at `s(14)`, name at
  `font(size: 12)`, `.white.opacity(0.85)`. Row height `s(24)`, hover fill
  `.white.opacity(0.10)`.
- Row label is the **leaf folder name only**. Full path goes in `.help()`.
- Separator between sections: 1px `.white.opacity(0.12)`. Omit a section
  entirely — header included — when it has no entries.
- **Other Folder…** opens `NSOpenPanel` with `canChooseDirectories = true`,
  `canChooseFiles = false`, `allowsMultipleSelection = false`. A folder chosen
  this way files the item but is **not** auto-pinned; the toast offers pinning.
- Max height `s(220)` with vertical scroll. The popover is not constrained by
  notch width.
- Selecting a row calls `fileShelfItem(item.id, destination.url)` and dismisses.

### 4.4 Toast

Rendered **inside the shelf card**, replacing the chip row for its lifetime. Do
not create a new `NSWindow` — that would sit outside the notch's existing
expand/collapse animation and passthrough handling.

```
┌──────────────────────────────────────────┐
│ ✓ Moved to docs        [Pin] [Undo]      │
└──────────────────────────────────────────┘
```

- `checkmark.circle.fill` in `.green.opacity(0.8)` at `font(size: 11)`.
- Text `Moved to <leaf>` at `font(size: 12)`, `.white.opacity(0.85)`.
- **Undo** — plain button, `font(size: 11, weight: .medium)`, accent colour.
  Clickable for the full 10 seconds; **the toast must not dim, shrink, or animate
  its opacity on a timer** — a moving target is worse than no undo.
- **Pin** appears only when the destination came from `Other Folder…` or from
  `.recent`, and calls `DestinationStore.pin`.
- ⌘Z while the notch holds key focus triggers `undoShelfFiling`. Add to the
  existing `keyDown` switch in `NotchContainerView.swift:255` (`keyCode 6` with
  `.command` in `event.modifierFlags`), next to the existing space-bar case.

Error variant, held for 6 seconds, no Undo, no Pin:

```
┌──────────────────────────────────────────┐
│ ⚠ Couldn't move — permission denied      │
└──────────────────────────────────────────┘
```

`exclamationmark.triangle.fill` in `.orange.opacity(0.85)`. The chip stays on the
shelf. **A silent failure here looks exactly like data loss — this path must
always be visible.**

### 4.5 Preferences

In `PreferencesView.swift`, add a **Shelf** section near the expanded-content
toggles (~line 204):

- A `List` of pinned folders with icon + leaf name, full path as `.help()`.
- `+` opens the same directory `NSOpenPanel`; `−` unpins the selection.
- Drag to reorder, bound to `DestinationStore.movePinned(from:to:)`.
- Empty state: `"No pinned folders — recent Finder folders will still appear."`

### 4.6 Default change

In `Settings.swift`, `showExpandedShelf` currently defaults to `false` at lines
400, 507, and is forced `false` at 545. **Change all three to `true`.**

Rationale: `showFileShelf` already defaults to `true`, so files land on a shelf
whose card the user cannot see. That combination is how the current dead-code
state went unnoticed. Leave `showFileShelf` as is.

---

## 5. Why the dead views are not simply reused

`ShelfTile` takes `@ObservedObject var shelf: ShelfStore` and mutates it
directly. The expanded deck renders from an immutable `ExpandedActivity` value
and routes every side effect through `NotchActions` closures. Dropping
`ShelfTile` into the deck would put a live `ObservableObject` inside a snapshot
card and defeat the `contentKey` change-detection the deck relies on.

Lift the *contents* of `ShelfChip` — the `.onDrag`, the hover ✕, the
`ShareLink`, the Reveal-in-Finder menu item — into the new card, restyled to
§4.1, and reach `ShelfStore` only through `NotchActions`.

Delete `ShelfTile` and `ShelfChip` once the new card is working.

---

## 6. Tests

Add to `NotchPillTests/NotchPillTests.swift`, Swift Testing style. Create files
under `FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)`
and clean up in each test.

**`@Suite("ShelfFiler")`** — carries all the risk:

1. files a file into an empty folder; source gone, destination present
2. collision yields `report 2.pdf`, and the pre-existing file is byte-identical
   afterwards
3. a second collision yields `report 3.pdf`
4. extensionless `README` collides to `README 2`
5. undo restores the original path exactly, with original contents
6. undo throws `.undoConflicted` when the filed file no longer exists
7. undo throws `.undoConflicted` when something now occupies the source path
8. filing a non-existent source throws `.sourceMissing` and creates nothing
9. filing into a read-only directory (`chmod 0o500`) throws
   `.destinationUnwritable` and leaves the source in place

**`@Suite("FinderRecentFolders")`** — against an isolated `UserDefaults(suiteName:)`:

10. resolves a synthetic bookmark array to real directories
11. drops entries whose bookmark does not resolve
12. drops entries resolving to a file rather than a directory
13. respects `limit` and preserves order
14. returns `[]` when the key is absent or malformed

**`@Suite("DestinationStore")`**:

15. pinned appear before recents
16. a folder both pinned and recent appears once, as `.pinned`
17. recents are capped at 6
18. a pinned folder that no longer exists is absent from `destinations()` but
    still present in `pinned`

**`@Suite("ExpandedActivityBuilder")`** — extend the existing suite:

19. no shelf card when items are empty and no receipt or error
20. a shelf card **is** built when items are empty but a receipt is live
21. `contentKey` is unchanged across two payloads whose receipts differ only in
    `expiresAt` (guards the re-animation regression from §3.5)

The card UI itself is not unit-tested; it is covered by §7.

The full suite must report `** TEST SUCCEEDED **`, not just the new suites.

---

## 7. Manual verification

1. Drop a file from `~/Downloads` onto the notch → a chip appears in the expanded
   shelf card.
2. Click the chip → popover lists pinned folders, then Finder recents.
3. Pick a folder → chip disappears, toast appears, and the file is really at the
   destination and really gone from `~/Downloads`.
4. Click **Undo** → the file is back in `~/Downloads` and the chip returns.
5. File into `~/Desktop` → a TCC prompt appears. **Deny it**, and confirm the
   error toast shows and the file did not move.
6. File a name that already exists → ` 2` suffix; the original is untouched.
7. Drag a chip onto a Finder window → the real file drags out (regression check
   on the lifted `.onDrag`).
8. Pause and play media while a chip is on the shelf → the deck must **not**
   slide or re-animate. Guards the `contentKey` regression.
9. Quit and relaunch → pinned folders and shelf items both survive.

---

## 8. Known limitations (accept, do not fix)

- **Undo is single-slot.** Filing two items in a row makes the first
  unrecoverable via the toast. Acceptable: the file is moved, not deleted, and
  the toast named its destination.
- **TCC prompts on first use** for Desktop/Documents/Downloads. Unavoidable
  outside a sandbox; the error path in §4.4 is the mitigation.
- **`FXRecentFolders` is undocumented.** It is a plist read with an empty
  fallback, so a format change degrades to "pinned only". No private API is
  called and nothing crashes.
