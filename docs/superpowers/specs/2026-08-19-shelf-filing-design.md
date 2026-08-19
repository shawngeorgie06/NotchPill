# Shelf Filing — send dropped files to a folder without opening Finder

Date: 2026-08-19
Status: design approved, not implemented

## Summary

NotchPill's file shelf already accepts drops, persists them, and drags them back
out. It has no way to *file* an item — to say "put this in `~/Projects/docs`" —
without opening a Finder window and dragging.

This adds that: every shelf chip gains a **Move to…** menu listing pinned folders
and Finder's recent folders. Choosing one moves the file and offers a 10-second
Undo.

## What already exists (do not rebuild)

| Capability | Location |
|---|---|
| Accept file drags onto the notch | `NotchContainerView.performDragOperation` |
| Expand the notch while a drag hovers | `NotchController` → `onDragTargetingChanged` |
| Persist across launches (bookmarks) | `ShelfStore.save()` / `load()` |
| Drag an item back out to any app | `ShelfChip.onDrag` |
| Reveal in Finder, AirDrop / Share | `ShelfChip.contextMenu` |

The shelf is a *holding pen*. This spec makes it a *router*.

## Non-goals

- Drop-onto-a-target-during-drag. Rejected in favour of drop-then-choose: it
  doubles the drag-time UI surface and the notch is small.
- Rule-based auto-filing (`*.png` → Screenshots). Configuring rules is Finder
  browsing moved earlier, not removed.
- Inferred / "smart" destinations from the frontmost app. Revisit only if the
  pinned + recents list proves insufficient in real use.
- Reading Finder **sidebar favorites**. Verified unavailable: the backing
  `~/Library/Application Support/com.apple.sharedfilelist/` directory is empty on
  the target machine and the `LSSharedFileList` API for it is deprecated. Finder
  *Recents* is used instead.
- Copy semantics, or a per-action move/copy prompt. Move is the behaviour.

## Decisions

| Question | Decision | Why |
|---|---|---|
| When to choose a destination | After the drop, from the chip | Smaller change; allows batching several files |
| Destination list source | Pinned folders + Finder Recents | Useful with zero config, stable once pinned |
| Original file | Moved, with 10s Undo | Filing that leaves a copy behind isn't filing |

## Architecture

Four units. Only the last touches existing code.

### `FinderRecentFolders` (new)

```swift
enum FinderRecentFolders {
    /// Reads `com.apple.finder FXRecentFolders`, resolves each entry's
    /// `file-bookmark`, and returns the folders that still exist.
    static func load(defaults: UserDefaults = UserDefaults(suiteName: "com.apple.finder")) -> [URL]
}
```

Pure and injectable. The stored value is an array of dictionaries with a
`file-bookmark` `Data` key — the same bookmark format `ShelfStore` already
resolves, so no new serialization concepts enter the codebase.

Entries that fail to resolve, or that resolve to something that is not a
directory, are dropped silently — a stale Finder recent is not an error.

### `Destination` + `DestinationStore` (new)

```swift
struct Destination: Identifiable, Equatable {
    enum Source { case pinned, recent }
    let url: URL
    let source: Source
    var name: String { url.lastPathComponent }
}

@MainActor
final class DestinationStore: ObservableObject {
    @Published private(set) var pinned: [URL]
    func destinations() -> [Destination]   // pinned first, then recents
    func pin(_ url: URL)
    func unpin(_ url: URL)
}
```

`destinations()` resolves lazily when the menu opens, so a folder deleted since
launch simply stops appearing. Pinned entries win on duplicates — a folder that
is both pinned and recent shows once, under PINNED. Recents are capped at 6 to
keep the menu inside the notch.

Pinned folders persist as bookmark data under a new `shelfPinnedFolders` key,
mirroring `ShelfStore`'s existing approach.

### `ShelfFiler` (new)

The only destructive code in NotchPill. Deliberately has no `@Published` state
and no UI dependency, so it is testable against a temp directory.

```swift
enum ShelfFiler {
    struct UndoToken { let from: URL; let to: URL }

    enum FilingError: Error {
        case destinationUnwritable(URL)   // TCC denial or permissions
        case sourceMissing(URL)
        case moveFailed(underlying: Error)
    }

    static func file(_ url: URL, into folder: URL) throws -> UndoToken
    static func undo(_ token: UndoToken) throws
}
```

Behaviour:

- **Collision** — if `folder/name` exists, insert a numeric suffix before the
  extension (`report.pdf` → `report 2.pdf`), matching Finder. Never overwrite.
- **Undo** — verifies `token.to` still exists *and* `token.from` does not before
  moving back. If the file was touched in between, throw rather than guess.
- **Cross-volume** — `FileManager.moveItem` handles it as copy+delete; success is
  confirmed by checking the source is actually gone before returning a token.

### `ShelfStore` (existing, minimal change)

Gains one method:

```swift
func fileItem(_ item: Item, into folder: URL) throws -> ShelfFiler.UndoToken
```

which calls `ShelfFiler`, removes the item on success, and re-adds it on undo.
Persistence is unchanged — a moved file's old bookmark is simply dropped.

## Data flow

```
drop ──▶ ShelfStore.add ──▶ chip appears
                                │
                     user opens chip menu
                                │
                  DestinationStore.destinations()
                     ├── pinned  (UserDefaults bookmarks)
                     └── recents (com.apple.finder FXRecentFolders)
                                │
                        user picks a folder
                                │
                        ShelfFiler.file()
                          ├── success ─▶ remove chip, show Undo toast (10s)
                          └── throws  ─▶ show error toast, chip stays
```

## UI specification

### Chip menu

Left-clicking a chip (currently inert) opens the destination popover; the
existing right-click context menu gains **Move to…** as its first item, so both
paths reach the same list.

```
┌────────────────────────┐
│ PINNED                 │
│  📁 Desktop            │
│  📁 ~/Projects         │
├────────────────────────┤
│ RECENT (Finder)        │
│  🕒 Downloads          │
│  🕒 NotchPill/docs     │
├────────────────────────┤
│  📂 Other Folder…      │
└────────────────────────┘
```

- Section headers are 9pt, `.white.opacity(0.35)`, uppercase — quieter than the
  existing chip label at 10pt/0.7.
- Rows use `NSWorkspace.icon(forFile:)` at 14pt, matching chip icon sourcing.
- Long paths truncate in the **middle** (`~/Projects/…/docs`), not the tail — the
  leaf folder name is the identifying part.
- **Other Folder…** opens `NSOpenPanel` in directory mode. A folder chosen this
  way is offered for pinning via the toast, not pinned automatically.
- Max height ~220pt with scroll; the popover is not constrained by notch width.

### Undo toast

Reuses the notch's existing transient-content path rather than a new window, so
it inherits current expand/collapse animation behaviour.

```
┌───────────────────────────────┐
│ ✓ Moved to docs        [Undo] │
└───────────────────────────────┘
        auto-dismisses after 10s
```

- Text is the destination's **leaf name only** — the full path is too wide.
- Undo remains clickable for the full 10s; the toast does not dim on hover.
- ⌘Z while the notch has key focus triggers the same action.
- On error, the same toast shows `⚠ Couldn't move — <reason>` with no Undo, and
  holds for 6s. The chip stays on the shelf.

### Settings

`Preferences → Shelf` gains a pinned-folders list: add via `NSOpenPanel`, remove
via `−`, reorder by drag. Empty state reads "No pinned folders — recent Finder
folders will still appear."

### Default-on change

`showFileShelf` currently defaults to `true` in `registerDefaults` but is `0` on
the developer's machine, and `showExpandedShelf` defaults to `false` — so the
shelf is invisible in the expanded notch unless explicitly enabled. **Flip
`showExpandedShelf` to `true`.** A shelf that must be discovered in Settings
before it can be used will not be used.

## Testing

`ShelfFiler` carries the risk and gets the coverage, all against `FileManager`
temp directories with no app running:

- files a file into an empty folder; source gone, destination present
- collision produces `name 2.ext`, leaving the existing file untouched
- undo restores the original path exactly
- undo refuses when the destination file no longer exists
- undo refuses when something now occupies the source path
- unwritable destination throws `destinationUnwritable`, source untouched

`FinderRecentFolders` is tested by writing a synthetic bookmark array into an
isolated `UserDefaults` suite, asserting unresolvable and non-directory entries
are dropped.

`DestinationStore` is tested for pinned-wins-on-duplicate and the 6-item recents
cap.

The notch UI is not unit-tested; it is verified by hand against the checklist
below.

## Manual verification

1. Drop a file from Downloads onto the notch → chip appears.
2. Chip menu lists pinned folders, then Finder recents.
3. File it into `~/Projects` → chip disappears, toast shows, file is really
   there and really gone from Downloads.
4. Undo → file is back in Downloads, chip returns.
5. File into `~/Desktop` → TCC prompt appears; deny it once and confirm the
   error toast is shown and the file did not move.
6. File a name that already exists → ` 2` suffix, original intact.
7. Quit and relaunch → pinned folders survive.

## Open risks

- **TCC first-use friction.** The first move into Desktop/Documents/Downloads
  prompts. Acceptable, but the error path must be visible — a silent failure
  here looks like data loss.
- **`FXRecentFolders` is undocumented.** It is a plist read with a graceful
  empty fallback, so a format change degrades to "pinned only" rather than
  breaking. No private API is called.
- **Undo is single-slot.** Filing two items in a row makes the first
  unrecoverable via the toast. Judged acceptable; the file is not deleted, only
  moved, and its location is shown.
