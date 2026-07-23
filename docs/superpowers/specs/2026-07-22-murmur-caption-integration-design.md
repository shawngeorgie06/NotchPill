# Murmur Caption Integration — Design

**Date:** 2026-07-22
**Status:** Approved (pending spec review)
**Repos touched:** `NotchPill` (Swift, primary), `murmur-app` (Rust/Tauri, small change)

## Summary

When Murmur (the local voice-to-text app) finishes a dictation, NotchPill shows
the just-transcribed text as a caption peek in the notch. Murmur broadcasts each
final transcript to a small local file when the user opts in; NotchPill detects
Murmur is running, tails that file, and flashes the caption. If Murmur isn't
installed, running, or opted in, NotchPill does nothing extra.

## Why this approach

Murmur is privacy-first and **strips transcript text from its own release logs**
(`telemetry.rs`), so there is no existing on-disk artifact NotchPill could
passively tail to obtain caption text. The only clean way to get exact, reliable
caption text is for Murmur to broadcast it deliberately from the one place it
already holds the final string: `injector.rs::inject_text`.

Alternatives rejected:

- **Clipboard watching (NotchPill-only):** cannot distinguish a Murmur
  transcription from any other `Cmd+C`, and requires reading all clipboard
  content continuously — the opposite of Murmur's privacy posture.
- **DistributedNotificationCenter:** same result as the file, but posting from
  Rust/Tauri means dropping into the Objective-C runtime for no benefit over an
  atomic file write.

## The contract (shared surface)

A single file, written by Murmur, read by NotchPill:

```
~/Library/Application Support/local-dictation/latest-caption.json
```

```json
{
  "text": "the transcript that was just injected",
  "timestamp": 1753200000000,
  "app": "com.apple.Notes"
}
```

- `text` — the final transcript string (non-empty; Murmur skips empties).
- `timestamp` — epoch milliseconds when the transcript was finalized.
- `app` — optional bundle id of the app the text was injected into, for an
  optional subtitle. May be absent.

**Write discipline:** Murmur writes to a temp file in the same directory and
`rename(2)`s it over the target, so NotchPill never observes a partially written
file. `~/Library/Application Support/local-dictation/` is Murmur's existing
`dirs::data_dir()` root (already used for `logs/`).

This is the entire cross-app surface: no sockets, no ports, no daemon.

## Murmur side (Rust/Tauri)

Small and localized:

1. **Setting:** a Settings checkbox **"Mirror captions to NotchPill"**, default
   **OFF**. Persisted like other Murmur settings and plumbed to Rust.
2. **Broadcast:** when the setting is on, `injector.rs::inject_text` (the single
   choke point that already receives the final `&str` before copying to the
   clipboard) writes `latest-caption.json` atomically. Guarded so that when the
   setting is off, behavior is byte-for-byte unchanged.
3. **No new dependencies** — uses `serde_json` (already present) and std fs.

Empty/whitespace-only transcripts are not written (mirrors `inject_text`'s
existing empty-skip).

## NotchPill side (Swift)

### MurmurCaptionProvider (new)

- Observes running applications via `NSWorkspace` for bundle id
  `com.localdictation` (Murmur). Reuses the pattern in `AppSwitchProvider`.
- Only while Murmur is running does it `DispatchSource`-watch the caption file
  (same `DispatchSource` approach as `MediaRemoteBridge`). Watches for
  writes/renames; re-arms the source after a rename (atomic writes replace the
  inode).
- On change: read + JSON-decode the file. **Staleness guard:** ignore any
  caption whose `timestamp` is older than a few seconds relative to now, so a
  leftover file never surfaces a stale caption (especially at launch).
- Publishes the latest `MurmurCaption` to `NotchState`.
- Fully idle (no watcher, no polling) when Murmur is absent or not running.

### Caption peek UI (new)

- A new peek in the same family as the dev-ready and update-progress peeks:
  a small soundwave/mic glyph, a "Murmur" label, and the transcript text
  (up to ~3 lines, then truncate with ellipsis). Optional subtitle from `app`.
- **Auto-dismiss ≈ 6 seconds**, extended while the pointer is hovering the
  notch. New caption replaces the current one and resets the timer.

### Overlay priority

`updateProgress > murmurCaption > devReady > expanded > collapsed`.

Rationale: Murmur's *own* overlay shows the waveform while speaking; NotchPill's
caption fires the instant text is final — a hand-off, not a collision. Caption
sits below an in-progress app update (never interrupt an update) but above
routine expanded/collapsed content.

### Settings

No separate NotchPill on/off. The Murmur checkbox is the single source of truth:
captions arriving ⇒ NotchPill shows them; toggled off in Murmur ⇒ they stop.

## Edge cases

- **Murmur not installed / not running:** provider idle; zero cost.
- **Stale file at launch:** timestamp guard suppresses it.
- **Empty text:** Murmur never writes it; NotchPill also skips empty defensively.
- **Malformed JSON / partial read:** decode failure is ignored (next atomic
  write supersedes it); atomic rename makes partial reads unlikely regardless.
- **File deleted while watching:** source cancels; provider re-arms when the
  file reappears (or when Murmur relaunches).

## Out of scope (YAGNI)

- Scrollback / history of past captions in the notch (only the latest live one).
- Editing, copying, or acting on the caption from NotchPill.
- Any streaming/partial-word live captioning — only the final transcript.
- Bidirectional communication (NotchPill never writes back to Murmur).

## Testing

- **NotchPill:** unit-test JSON decode (valid, missing `app`, malformed) and the
  staleness guard (fresh vs. old timestamp). Manual: enable in Murmur, dictate,
  confirm caption appears within the peek and auto-dismisses.
- **Murmur:** unit-test the atomic write helper (temp+rename, correct JSON) and
  that it is a no-op when the setting is off.
