# Murmur Caption Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Surface Murmur's final voice transcripts as a caption peek in the NotchPill notch, via an opt-in local file Murmur broadcasts and NotchPill tails.

**Architecture:** Murmur atomically writes each final transcript (when the user opts in) to `~/Library/Application Support/local-dictation/latest-caption.json`. NotchPill detects Murmur (`com.localdictation`) is running, watches that file with a `DispatchSource`, and flashes the newest caption as a peek that auto-dismisses. Fully idle when Murmur is absent.

**Tech Stack:** Swift/AppKit/SwiftUI/Combine (NotchPill); Rust/Tauri + React/TypeScript (Murmur). No new dependencies (`dirs` + `serde_json` already in Murmur).

## Global Constraints

- Caption file path: `~/Library/Application Support/local-dictation/latest-caption.json` (Murmur's `dirs::data_dir()/local-dictation/`).
- JSON payload: `{ "text": String, "timestamp": <epoch ms>, "app": String? }`. `app` optional/absent.
- Murmur writes **atomically** (temp file in the same dir + `rename`), only when the opt-in setting is on, never for empty/whitespace text, and never in a way that alters dictation when off.
- Murmur bundle id: `com.localdictation`. Murmur setting default: **OFF**.
- NotchPill has no separate on/off — the Murmur setting is the single switch.
- NotchPill: never poll or watch when Murmur isn't running. Ignore captions older than the freshness window (8s) and any with `timestamp <= lastTimestamp`.
- Overlay priority: `updateProgress > murmurCaption > devReady > expanded > collapsed`.
- NotchPill build/test: `xcodebuild -scheme NotchPill -destination 'platform=macOS' build` / `... test`. SourceKit shows false "cannot find type" errors — trust `xcodebuild`, not the editor.
- Murmur Rust test: `cd app/src-tauri && cargo test -- --test-threads=1`.

---

## Phase A — Murmur (broadcast side)

### Task A1: Atomic caption-broadcast helper

**Files:**
- Modify: `~/murmur-app/app/src-tauri/src/injector.rs`
- Test: same file (`#[cfg(test)]` module at bottom)

**Interfaces:**
- Produces: `pub fn mirror_caption(text: &str)` — best-effort write of the caption file. Internally delegates to `fn write_caption_to(dir: &std::path::Path, text: &str) -> bool` (testable).

- [ ] **Step 1: Write the failing test**

Add to the `#[cfg(test)]` module in `injector.rs`:

```rust
#[test]
fn write_caption_to_writes_valid_json() {
    let tmp = std::env::temp_dir().join(format!("murmur-cap-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    assert!(write_caption_to(&tmp, "hello world"));
    let raw = std::fs::read_to_string(tmp.join("latest-caption.json")).unwrap();
    let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
    assert_eq!(v["text"], "hello world");
    assert!(v["timestamp"].as_u64().unwrap() > 0);
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn write_caption_to_skips_empty() {
    let tmp = std::env::temp_dir().join(format!("murmur-cap-empty-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    assert!(!write_caption_to(&tmp, "   "));
    assert!(!tmp.join("latest-caption.json").exists());
    let _ = std::fs::remove_dir_all(&tmp);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/murmur-app/app/src-tauri && cargo test injector::tests::write_caption -- --test-threads=1`
Expected: FAIL — `cannot find function write_caption_to`.

- [ ] **Step 3: Write the implementation**

Add near the top-level functions in `injector.rs`:

```rust
/// Mirror the final transcript to a local file NotchPill can tail. Opt-in and
/// best-effort: any failure is swallowed so dictation is never affected.
pub fn mirror_caption(text: &str) {
    let Some(dir) = dirs::data_dir().map(|d| d.join("local-dictation")) else { return };
    let _ = write_caption_to(&dir, text);
}

/// Atomic write (temp + rename) of the caption JSON. Returns false (no write)
/// for empty/whitespace text. Separated from `mirror_caption` for testability.
fn write_caption_to(dir: &std::path::Path, text: &str) -> bool {
    if text.trim().is_empty() {
        return false;
    }
    if std::fs::create_dir_all(dir).is_err() {
        return false;
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let payload = serde_json::json!({ "text": text, "timestamp": ts });
    let Ok(bytes) = serde_json::to_vec(&payload) else { return false };
    let target = dir.join("latest-caption.json");
    let tmp = dir.join(format!("latest-caption.json.tmp.{}", std::process::id()));
    if std::fs::write(&tmp, &bytes).is_err() {
        return false;
    }
    std::fs::rename(&tmp, &target).is_ok()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/murmur-app/app/src-tauri && cargo test injector::tests::write_caption -- --test-threads=1`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
cd ~/murmur-app && git add app/src-tauri/src/injector.rs
git commit -m "feat(injector): add opt-in caption mirror for NotchPill"
```

---

### Task A2: Setting plumbing + broadcast at the inject site

**Files:**
- Modify: `~/murmur-app/app/src/lib/settings.ts` (interface + default)
- Modify: `~/murmur-app/app/src/lib/dictation.ts` (send option to Rust — locate where `autoPaste` is put into the configure options)
- Modify: `~/murmur-app/app/src-tauri/src/state.rs` and/or the delivery snapshot struct (add `mirror_to_notchpill: bool` sibling to the existing `auto_paste` field)
- Modify: `~/murmur-app/app/src-tauri/src/commands/recording.rs` (parse the option ~line 1214; call the broadcast at the inject site ~line 763)
- Modify: `~/murmur-app/app/src/` Settings UI component that renders the auto-paste checkbox (add a sibling checkbox)

**Interfaces:**
- Consumes: `injector::mirror_caption(&str)` from Task A1.
- Produces: a `mirrorToNotchPill` (TS) / `mirror_to_notchpill` (Rust) opt-in flag, default false, that gates the broadcast.

**Approach:** mirror the existing `autoPaste` / `auto_paste` setting's plumbing **exactly** — the same field travels frontend default → configure options → Rust delivery snapshot → the inject call site. Add `mirror_to_notchpill` everywhere `auto_paste` appears in that chain.

- [ ] **Step 1: Add the setting to TypeScript**

In `app/src/lib/settings.ts`, add to the `Settings` interface (near `autoPaste: boolean;`):

```ts
  mirrorToNotchPill: boolean;
```

and to `DEFAULT_SETTINGS` (near `autoPaste: false,`):

```ts
  mirrorToNotchPill: false,
```

- [ ] **Step 2: Send it to Rust**

In `app/src/lib/dictation.ts`, find where the configure options object is built (it includes `autoPaste`). Add:

```ts
    mirrorToNotchPill: settings.mirrorToNotchPill,
```

- [ ] **Step 3: Parse it in Rust**

In `app/src-tauri/src/commands/recording.rs`, next to the existing `autoPaste` parse (~line 1214):

```rust
    if let Some(mirror) = options.get("mirrorToNotchPill").and_then(|v| v.as_bool()) {
        dictation.mirror_to_notchpill = mirror;
    }
```

Add the `mirror_to_notchpill: bool` field (default false) to the dictation/delivery state struct in `state.rs` wherever `auto_paste` is declared and copied into the per-recording snapshot.

- [ ] **Step 4: Broadcast at the inject site**

In `recording.rs`, right after the `injector::inject_text(...)` dispatch (~line 763), while `text_to_inject` is still in scope, add (reading the same `delivery` snapshot that carries `auto_paste`):

```rust
        if delivery.mirror_to_notchpill {
            injector::mirror_caption(&text_to_inject);
        }
```

- [ ] **Step 5: Add the Settings checkbox**

In the Settings UI component that renders the auto-paste toggle, add a sibling checkbox bound to `settings.mirrorToNotchPill` labelled **"Mirror captions to NotchPill"** with helper text "Show your latest dictation in the NotchPill notch. Stays on this Mac."

- [ ] **Step 6: Verify it builds and type-checks**

Run: `cd ~/murmur-app/app && npx tsc --noEmit && cd src-tauri && cargo build`
Expected: no TS errors; `cargo build` succeeds.

- [ ] **Step 7: Manual smoke test**

Run `cd ~/murmur-app/app && npm run tauri dev`, enable "Mirror captions to NotchPill", dictate one phrase, then:
Run: `cat ~/Library/Application\ Support/local-dictation/latest-caption.json`
Expected: JSON with your spoken `text` and a recent `timestamp`. Toggle the setting off, dictate again, confirm the file's timestamp does **not** change.

- [ ] **Step 8: Commit**

```bash
cd ~/murmur-app && git add -A
git commit -m "feat: opt-in 'Mirror captions to NotchPill' setting"
```

---

## Phase B — NotchPill (display side)

### Task B1: MurmurCaption model (decode + freshness)

**Files:**
- Create: `~/Projects/NotchPill/NotchPill/Core/MurmurCaption.swift`
- Test: `~/Projects/NotchPill/NotchPillTests/NotchPillTests.swift` (add a test group)

**Interfaces:**
- Produces:
  - `struct MurmurCaption: Equatable, Codable { var text: String; var timestamp: Int64; var app: String? }`
  - `static func MurmurCaption.decode(from: Data) -> MurmurCaption?`
  - `func isFresh(now: Date, maxAge: TimeInterval = 8) -> Bool`

- [ ] **Step 1: Write the failing tests**

Add to `NotchPillTests.swift`:

```swift
final class MurmurCaptionTests: XCTestCase {
    func testDecodeValid() {
        let json = #"{"text":"hello","timestamp":1753200000000,"app":"com.apple.Notes"}"#.data(using: .utf8)!
        let c = MurmurCaption.decode(from: json)
        XCTAssertEqual(c?.text, "hello")
        XCTAssertEqual(c?.timestamp, 1753200000000)
        XCTAssertEqual(c?.app, "com.apple.Notes")
    }

    func testDecodeMissingAppIsNil() {
        let json = #"{"text":"hi","timestamp":10}"#.data(using: .utf8)!
        XCTAssertEqual(MurmurCaption.decode(from: json)?.app, nil)
    }

    func testDecodeMalformedReturnsNil() {
        XCTAssertNil(MurmurCaption.decode(from: Data("not json".utf8)))
    }

    func testFreshWithinWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let c = MurmurCaption(text: "x", timestamp: 1000 * 1000, app: nil) // 1000s in ms
        XCTAssertTrue(c.isFresh(now: now))
    }

    func testStaleOutsideWindow() {
        let now = Date(timeIntervalSince1970: 1000)
        let c = MurmurCaption(text: "x", timestamp: 900 * 1000, app: nil) // 100s old
        XCTAssertFalse(c.isFresh(now: now))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' test 2>&1 | grep -E "MurmurCaption|error:" | head`
Expected: compile failure — `cannot find 'MurmurCaption'`.

- [ ] **Step 3: Write the implementation**

Create `NotchPill/Core/MurmurCaption.swift`:

```swift
import Foundation

/// A final voice transcript broadcast by Murmur (com.localdictation).
struct MurmurCaption: Equatable, Codable {
    var text: String
    /// Epoch milliseconds when Murmur finalized the transcript.
    var timestamp: Int64
    /// Bundle id of the app the text was injected into (optional).
    var app: String?

    static func decode(from data: Data) -> MurmurCaption? {
        try? JSONDecoder().decode(MurmurCaption.self, from: data)
    }

    /// True when the caption is recent enough to surface. A small negative
    /// tolerance absorbs minor clock skew between the two apps.
    func isFresh(now: Date, maxAge: TimeInterval = 8) -> Bool {
        let age = now.timeIntervalSince1970 - Double(timestamp) / 1000.0
        return age >= -2 && age <= maxAge
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' test 2>&1 | grep -E "MurmurCaptionTests|Test Suite.*passed|failed" | head`
Expected: MurmurCaptionTests pass.

- [ ] **Step 5: Commit**

```bash
cd ~/Projects/NotchPill && git add NotchPill/Core/MurmurCaption.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: add MurmurCaption model with decode + freshness"
```

---

### Task B2: MurmurCaptionProvider (detect + watch)

**Files:**
- Create: `~/Projects/NotchPill/NotchPill/Providers/MurmurCaptionProvider.swift`

**Interfaces:**
- Consumes: `MurmurCaption` (Task B1).
- Produces: `final class MurmurCaptionProvider { var onCaption: ((MurmurCaption) -> Void)?; func start(); func stop() }`

- [ ] **Step 1: Write the implementation**

Create `NotchPill/Providers/MurmurCaptionProvider.swift`:

```swift
import AppKit

/// Surfaces Murmur's final transcripts. Idle unless Murmur (com.localdictation)
/// is running; only then does it watch the broadcast file. Mirrors the
/// NSWorkspace pattern in AppSwitchProvider and the DispatchSource pattern in
/// MediaRemoteBridge.
final class MurmurCaptionProvider {
    var onCaption: ((MurmurCaption) -> Void)?

    private static let murmurBundleId = "com.localdictation"
    private static let captionURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/local-dictation/latest-caption.json")

    private var launchObs: NSObjectProtocol?
    private var terminateObs: NSObjectProtocol?
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "com.shawngeorgie06.NotchPill.murmur")
    private var lastTimestamp: Int64 = 0

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        launchObs = nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                   object: nil, queue: .main) { [weak self] note in
            guard let self, self.isMurmur(note) else { return }
            self.beginWatching()
        }
        terminateObs = nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                      object: nil, queue: .main) { [weak self] note in
            guard let self, self.isMurmur(note) else { return }
            self.stopWatching()
        }
        if murmurIsRunning() { beginWatching() }
    }

    func stop() {
        let nc = NSWorkspace.shared.notificationCenter
        if let launchObs { nc.removeObserver(launchObs) }
        if let terminateObs { nc.removeObserver(terminateObs) }
        launchObs = nil; terminateObs = nil
        stopWatching()
    }

    private func isMurmur(_ note: Notification) -> Bool {
        (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
            .bundleIdentifier == Self.murmurBundleId
    }

    private func murmurIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.murmurBundleId).isEmpty
    }

    private func beginWatching() {
        guard source == nil else { return }
        // Baseline against the current file so a caption written before we
        // started watching is never replayed.
        if let existing = readCaption() { lastTimestamp = max(lastTimestamp, existing.timestamp) }
        arm()
    }

    /// Watches the parent directory so atomic renames (which swap the inode) are
    /// caught even when the file is replaced wholesale.
    private func arm() {
        let dir = Self.captionURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: queue)
        src.setEventHandler { [weak self] in self?.handleChange() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.fd, fd >= 0 { close(fd) }
            self?.fd = -1
        }
        source = src
        src.resume()
    }

    private func handleChange() {
        guard let c = readCaption(),
              c.timestamp > lastTimestamp,
              c.isFresh(now: Date()),
              !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        lastTimestamp = c.timestamp
        DispatchQueue.main.async { [weak self] in self?.onCaption?(c) }
    }

    private func readCaption() -> MurmurCaption? {
        guard let data = try? Data(contentsOf: Self.captionURL) else { return nil }
        return MurmurCaption.decode(from: data)
    }

    private func stopWatching() {
        source?.cancel()
        source = nil
    }
}
```

- [ ] **Step 2: Verify it builds**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
cd ~/Projects/NotchPill && git add NotchPill/Providers/MurmurCaptionProvider.swift
git commit -m "feat: add MurmurCaptionProvider watching Murmur's broadcast file"
```

---

### Task B3: NotchState + NotchController wiring

**Files:**
- Modify: `~/Projects/NotchPill/NotchPill/Core/NotchState.swift`
- Modify: `~/Projects/NotchPill/NotchPill/Core/NotchController.swift`

**Interfaces:**
- Consumes: `MurmurCaptionProvider` (B2), `MurmurCaption` (B1).
- Produces: `NotchState.murmurCaption: MurmurCaption?` (`@Published`), `NotchState.showMurmurCaption(_:dismissAfter:)`, `NotchState.clearMurmurCaption()`.

- [ ] **Step 1: Add published state + show/hide to NotchState**

In `NotchState.swift`, after the `updateProgress` property (line 36):

```swift
    /// Latest Murmur voice caption, shown as a transient peek. Nil when hidden.
    @Published private(set) var murmurCaption: MurmurCaption?
```

Near the `volumeHideItem` declaration, add:

```swift
    private var murmurCaptionHideItem: DispatchWorkItem?
```

After `showVolume`/`refreshSystemVolume`, add:

```swift
    /// Shows a Murmur caption and auto-dismisses it. While the notch is hovered
    /// (isExpanded), it lingers a little longer so a caption isn't yanked away
    /// mid-read.
    func showMurmurCaption(_ caption: MurmurCaption, dismissAfter seconds: TimeInterval = 6) {
        murmurCaption = caption
        murmurCaptionHideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.isExpanded {
                self.showMurmurCaption(caption, dismissAfter: 2)
            } else {
                self.murmurCaption = nil
            }
        }
        murmurCaptionHideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func clearMurmurCaption() {
        murmurCaptionHideItem?.cancel()
        murmurCaption = nil
    }
```

- [ ] **Step 2: Add the provider to NotchController**

In `NotchController.swift`, with the other providers (~line 28):

```swift
    private let murmurCaption = MurmurCaptionProvider()
```

- [ ] **Step 3: Wire it in `wireProviders()`**

Next to `devReady.onDevReady = ...; devReady.start()` (~line 220):

```swift
        murmurCaption.onCaption = { [weak self] caption in
            self?.state.showMurmurCaption(caption)
        }
        murmurCaption.start()
```

- [ ] **Step 4: Add to the relayout merge**

In the relayout publisher merge that includes `state.$updateProgress.map { _ in () }` (~line 123), add a sibling:

```swift
            state.$murmurCaption.map { _ in () }.eraseToAnyPublisher(),
```

- [ ] **Step 5: Include it in expansion + expanded size**

Find `expandedContentSize()` and the expanded branch of `applyWindowFrame`. Where the code checks `state.updateProgress != nil` to force expansion, extend it to also cover `state.murmurCaption`. In `expandedContentSize()`, before the devReady/expanded branches, add:

```swift
        if let caption = state.murmurCaption {
            return NotchContentLayout.murmurCaptionLayout(metrics: metrics, caption: caption).size
        }
```

And in the expanded-condition used by `applyWindowFrame` (the `|| state.updateProgress != nil` clause), add `|| state.murmurCaption != nil`.

- [ ] **Step 6: Stop it on teardown**

In `NotchController.stop()` (wherever `devReady`/providers are stopped), add:

```swift
        murmurCaption.stop()
```

- [ ] **Step 7: Verify it builds**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd ~/Projects/NotchPill && git add NotchPill/Core/NotchState.swift NotchPill/Core/NotchController.swift
git commit -m "feat: publish + wire Murmur captions through NotchState/Controller"
```

---

### Task B4: Caption peek UI + priority

**Files:**
- Modify: `~/Projects/NotchPill/NotchPill/Core/NotchContentLayout.swift`
- Modify: `~/Projects/NotchPill/NotchPill/Views/NotchRootView.swift`

**Interfaces:**
- Consumes: `NotchState.murmurCaption` (B3), `MurmurCaption` (B1).
- Produces: `NotchContentLayout.murmurCaptionLayout(metrics:caption:) -> NotchContentLayoutMetrics`; `struct MurmurCaptionView`.

- [ ] **Step 1: Add the layout**

In `NotchContentLayout.swift`, after `updateLayout` (line 142):

```swift
    /// Peek sized to the caption text (up to three wrapped lines).
    static func murmurCaptionLayout(metrics: NotchMetrics, caption: MurmurCaption) -> NotchContentLayoutMetrics {
        let width = min(metrics.maxExpandedRenderedWidth, max(metrics.notchWidth + 240, 420))
        let charsPerLine = max(24, Int((width - 44) / 8.5))
        let lineCount = min(3, max(1, (caption.text.count + charsPerLine - 1) / charsPerLine))
        let hasSubtitle = (caption.app?.isEmpty == false)
        let textBlock = CGFloat(lineCount) * 20 + (hasSubtitle ? 16 : 0)
        let height = metrics.notchHeight + metrics.topGap + 34 + textBlock
        return NotchContentLayoutMetrics(
            size: CGSize(width: width, height: height),
            readability: 1.05,
            textScale: 1.05
        )
    }
```

- [ ] **Step 2: Add the caption view**

In `NotchRootView.swift`, after `struct UpdateProgressView` (line 230):

```swift
/// Live Murmur voice caption: waveform glyph, "Murmur" label, and the transcript.
struct MurmurCaptionView: View {
    let caption: MurmurCaption

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(NotchDesign.accent)
                Text("Murmur")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                if let app = caption.app, !app.isEmpty {
                    Text(app)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }
            Text(caption.text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
```

- [ ] **Step 3: Add the content wrapper**

In `NotchRootView.swift`, after `updateProgressContent(_:)` (line 120):

```swift
    private func murmurCaptionContent(_ caption: MurmurCaption) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            MurmurCaptionView(caption: caption)
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width,
                       height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }
```

- [ ] **Step 4: Slot it into the priority chain**

In `contentLayout` (line 23), add **after** the `updateProgress` check and **before** `devReadyAlerts`:

```swift
        if let caption = state.murmurCaption {
            return NotchContentLayout.murmurCaptionLayout(metrics: metrics, caption: caption)
        }
```

In the background `ZStack` condition (line 65), extend it:

```swift
            if state.isExpanded || !state.devReadyAlerts.isEmpty || state.updateProgress != nil || state.murmurCaption != nil {
```

In the `.overlay(alignment: .top)` chain (line 72), add a branch **after** the `updateProgress` branch and **before** the `devReadyAlerts` branch:

```swift
            } else if let caption = state.murmurCaption {
                murmurCaptionContent(caption)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
```

- [ ] **Step 5: Animate the caption**

At the end of the `body` animation chain (after line 107):

```swift
        .animation(expandAnimation, value: state.murmurCaption)
```

- [ ] **Step 6: Verify it builds**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd ~/Projects/NotchPill && git add NotchPill/Core/NotchContentLayout.swift NotchPill/Views/NotchRootView.swift
git commit -m "feat: render Murmur caption peek in the notch"
```

---

### Task B5: End-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Full test suite**

Run: `cd ~/Projects/NotchPill && xcodebuild -scheme NotchPill -destination 'platform=macOS' test 2>&1 | grep -E "Test Suite 'All tests'|failed" | tail -5`
Expected: all tests pass.

- [ ] **Step 2: Simulate a caption without Murmur**

With NotchPill running (a debug build), write a caption file by hand and confirm the peek appears:

```bash
mkdir -p ~/Library/Application\ Support/local-dictation
printf '{"text":"the quick brown fox jumps over the lazy dog","timestamp":%d,"app":"com.apple.Notes"}' "$(($(date +%s)*1000))" \
  > ~/Library/Application\ Support/local-dictation/latest-caption.json
```

Expected: the notch shows a "Murmur" peek with the sentence, then auto-dismisses after ~6s. Re-run with a new sentence + fresh timestamp → the peek updates.

- [ ] **Step 3: Confirm idle when stale**

Re-run Step 2's command but with `timestamp` set to `0`. Expected: **no** peek (staleness guard rejects it).

- [ ] **Step 4: Real Murmur round-trip**

Build/run Murmur with the setting on (Phase A), dictate a phrase, and confirm NotchPill shows it live.

- [ ] **Step 5: Commit any fixups, then wrap**

```bash
cd ~/Projects/NotchPill && git add -A && git commit -m "test: verify Murmur caption end-to-end" --allow-empty
```

---

## Self-Review

- **Spec coverage:** contract file (A1/A2, B1/B2) ✓; atomic write (A1) ✓; opt-in default-off setting (A2) ✓; broadcast at `inject_text` choke point (A2) ✓; provider detect+watch, idle when absent (B2) ✓; staleness guard (B1/B2) ✓; caption peek UI (B4) ✓; auto-dismiss ~6s + hover linger (B3) ✓; priority `updateProgress > murmurCaption > devReady > …` (B4) ✓; no separate NotchPill toggle (design — nothing to build) ✓; edge cases: not running / malformed / empty / deleted-file re-arm (B2) ✓.
- **Type consistency:** `MurmurCaption{text,timestamp:Int64,app:String?}`, `decode(from:)`, `isFresh(now:maxAge:)`, `showMurmurCaption(_:dismissAfter:)`, `murmurCaptionLayout(metrics:caption:)`, `MurmurCaptionView` — names identical across B1–B4. Rust `mirror_caption`/`write_caption_to`, TS `mirrorToNotchPill`, Rust `mirror_to_notchpill` — consistent across A1–A2.
- **Out of scope respected:** no caption history, no write-back, no partial-word streaming.
