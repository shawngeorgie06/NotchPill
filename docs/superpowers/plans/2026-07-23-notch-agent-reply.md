# Notch Agent Reply — Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** From a NotchPill "agent finished" peek, type a follow-up and deliver it into that terminal agent's live session (focus terminal → paste → Return). Universal across CLI agents.

**Architecture:** A pure delivery backend (`TerminalReplyInjector`) + a pure compose-state on `NotchState` + a SwiftUI composer surfaced by `NotchRootView` + a reply button on each dev-ready peek row. `NotchController` wires the actions, pauses auto-dismiss while composing, and makes the panel key for typing. Reuses the `bundleId` already present on every `DevReadyAlert`; no hook/signal-format change.

**Tech Stack:** Swift, AppKit (`NSPanel`, `NSRunningApplication`, `NSPasteboard`, `CGEvent`), SwiftUI, Combine. Tests use **Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`) — NOT XCTest.

**Design doc:** `docs/superpowers/specs/2026-07-23-notch-agent-reply-design.md`

## Global Constraints

- **Swift Testing only** in `NotchPillTests/NotchPillTests.swift` — `@Suite` / `@Test` / `#expect`. Never XCTest.
- **No Murmur repo changes.** Phase 1 is typed input only; no dictation.
- **No regression to tap-to-focus:** tapping a peek *row body* must still focus the terminal exactly as today. The reply affordance is an additional, separate control.
- **Never blind-fire:** a reply may only ever target a concrete `bundleId`. If `alert.bundleId` is nil/empty, no reply control is shown and no send is attempted.
- **Clipboard is borrowed, not stolen:** any paste path must save the prior `NSPasteboard.general` string and restore it afterward.
- **Accessibility gate:** posting synthetic keystrokes requires `AccessibilityAuthorization.isGranted`. If not granted, fail with a clear error and route to `AccessibilityAuthorization.requestSystemPrompt()`; never crash.
- **New `.swift` files under `NotchPill/`** are auto-included by the file-system-synchronized Xcode group — no `project.pbxproj` edits needed.
- **Setting default:** `agentReplyEnabled` defaults **on**.

---

## File Structure

**New files:**
- `NotchPill/Core/TerminalReplyInjector.swift` — pure delivery backend + targeting/validation policy.

**Modified files:**
- `NotchPill/Core/NotchState.swift` — `ReplyComposeState` + compose mutators.
- `NotchPill/Core/Settings.swift` — `agentReplyEnabled` setting.
- `NotchPill/Views/PreferencesView.swift` — toggle for the setting.
- `NotchPill/Views/NotchActions.swift` — `beginReply` / `sendReply` actions.
- `NotchPill/Core/NotchController.swift` — wire actions, pause dismiss + make panel key while composing.
- `NotchPill/Core/NotchContentLayout.swift` — `replyComposeLayout`.
- `NotchPill/Views/NotchRootView.swift` — compose branch (background, overlay, layout, animation) + `ReplyComposeView`.
- `NotchPill/Views/Tiles.swift` — reply button on `DevReadyPeekRow`.
- `NotchPillTests/NotchPillTests.swift` — new `@Suite`s.

**Interfaces (locked signatures the tasks share):**

```swift
// TerminalReplyInjector.swift
enum ReplyError: Error, Equatable {
    case emptyText, noTarget, targetNotRunning, accessibilityDenied
}
enum TerminalReplyInjector {
    /// Pure precondition check. Returns nil when a send may proceed.
    static func validate(text: String, bundleId: String?,
                         isRunning: Bool, accessibilityGranted: Bool) -> ReplyError?
    /// True when this alert is targetable (has a concrete terminal bundle id).
    static func canTarget(_ alert: DevReadyAlert) -> Bool
    /// Production entry: focuses the terminal, pastes text, presses Return,
    /// restoring the clipboard. Returns nil on success or a ReplyError.
    @MainActor static func send(text: String, bundleId: String?) -> ReplyError?
}

// NotchState.swift
struct ReplyComposeState: Equatable {
    var targetAlert: DevReadyAlert
    var draft: String = ""
    var errorText: String? = nil
}
extension NotchState {
    var replyCompose: ReplyComposeState? { get }   // @Published private(set)
    func beginReply(to alert: DevReadyAlert)
    func updateReplyDraft(_ text: String)
    func setReplyError(_ message: String)
    func cancelReply()
}

// NotchActions.swift  (added fields)
var beginReply: (DevReadyAlert) -> Void
var sendReply: (DevReadyAlert, String) -> Void

// Settings.swift
var agentReplyEnabled: Bool   // default true
```

**Build / test commands (used throughout):**
- Build: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build`
- Run one suite: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/<SuiteName>`
- (Swift Testing suites are addressed by the `@Suite("Name")` display name via `-only-testing`.)

---

## Task 1: TerminalReplyInjector (pure core + tests)

**Files:**
- Create: `NotchPill/Core/TerminalReplyInjector.swift`
- Test: `NotchPillTests/NotchPillTests.swift`

**Interfaces:**
- Consumes: `DevReadyAlert` (existing, has `bundleId: String?`), `AccessibilityAuthorization.isGranted` (existing).
- Produces: `ReplyError`, `TerminalReplyInjector.validate(...)`, `.canTarget(_:)`, `.send(...)` (see locked signatures).

- [ ] **Step 1: Write the failing tests** (append to `NotchPillTests.swift`)

```swift
@Suite("TerminalReplyInjector")
struct TerminalReplyInjectorTests {
    private func alert(bundleId: String?) -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code", bundleId: bundleId)
    }

    @Test("canTarget requires a non-empty bundle id")
    func canTargetRule() {
        #expect(TerminalReplyInjector.canTarget(alert(bundleId: "com.googlecode.iterm2")))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: nil)))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: "")))
    }

    @Test("validate rejects empty text")
    func rejectsEmpty() {
        #expect(TerminalReplyInjector.validate(text: "   ", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == .emptyText)
    }

    @Test("validate rejects missing target")
    func rejectsNoTarget() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: nil,
            isRunning: true, accessibilityGranted: true) == .noTarget)
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "",
            isRunning: true, accessibilityGranted: true) == .noTarget)
    }

    @Test("validate rejects when target app not running")
    func rejectsNotRunning() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: false, accessibilityGranted: true) == .targetNotRunning)
    }

    @Test("validate rejects when accessibility denied")
    func rejectsAccessibility() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: false) == .accessibilityDenied)
    }

    @Test("validate passes when all preconditions met")
    func passes() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/TerminalReplyInjector`
Expected: FAIL — `TerminalReplyInjector` / `ReplyError` are undefined (compile error).

- [ ] **Step 3: Implement `TerminalReplyInjector.swift`**

```swift
import AppKit

/// Delivers a typed reply into a CLI agent's terminal: focus the terminal app,
/// paste the text, press Return, then restore the clipboard. Targeting policy
/// and precondition checks are pure (unit-tested); the CGEvent posting + timing
/// are validated manually.
enum ReplyError: Error, Equatable {
    case emptyText, noTarget, targetNotRunning, accessibilityDenied
}

enum TerminalReplyInjector {
    /// Settle delay after activating the terminal before pasting.
    private static let activateSettle: TimeInterval = 0.12
    /// Delay after paste before pressing Return.
    private static let pasteToReturn: TimeInterval = 0.05
    /// Delay after Return before restoring the previous clipboard.
    private static let restoreDelay: TimeInterval = 0.30

    static func canTarget(_ alert: DevReadyAlert) -> Bool {
        !(alert.bundleId ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Pure precondition check. nil = ok to send.
    static func validate(text: String, bundleId: String?,
                         isRunning: Bool, accessibilityGranted: Bool) -> ReplyError? {
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .emptyText }
        if (bundleId ?? "").trimmingCharacters(in: .whitespaces).isEmpty { return .noTarget }
        if !accessibilityGranted { return .accessibilityDenied }
        if !isRunning { return .targetNotRunning }
        return nil
    }

    @MainActor
    static func send(text: String, bundleId: String?) -> ReplyError? {
        let app = (bundleId?.isEmpty == false)
            ? NSRunningApplication.runningApplications(withBundleIdentifier: bundleId!).first
            : nil
        if let err = validate(text: text, bundleId: bundleId,
                              isRunning: app != nil,
                              accessibilityGranted: AccessibilityAuthorization.isGranted) {
            return err
        }
        guard let app else { return .targetNotRunning }

        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)
        pb.clearContents()
        pb.setString(text, forType: .string)

        app.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + activateSettle) {
            postCommandV()
            DispatchQueue.main.asyncAfter(deadline: .now() + pasteToReturn) {
                postReturn()
                DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
                    pb.clearContents()
                    if let saved { pb.setString(saved, forType: .string) }
                }
            }
        }
        return nil
    }

    // MARK: - CGEvent posting (virtual keycodes: v = 9, return = 36)

    @MainActor private static func postCommandV() {
        postKey(9, flags: .maskCommand)
    }
    @MainActor private static func postReturn() {
        postKey(36, flags: [])
    }
    @MainActor private static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/TerminalReplyInjector`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Core/TerminalReplyInjector.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: TerminalReplyInjector delivery backend + targeting policy"
```

---

## Task 2: NotchState compose state (+ tests)

**Files:**
- Modify: `NotchPill/Core/NotchState.swift`
- Test: `NotchPillTests/NotchPillTests.swift`

**Interfaces:**
- Consumes: `DevReadyAlert`.
- Produces: `ReplyComposeState`, `NotchState.replyCompose`, `beginReply(to:)`, `updateReplyDraft(_:)`, `setReplyError(_:)`, `cancelReply()`.

- [ ] **Step 1: Write the failing tests** (append to `NotchPillTests.swift`)

```swift
@MainActor
@Suite("NotchState reply compose")
struct NotchStateReplyTests {
    private func alert() -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code",
                      bundleId: "com.googlecode.iterm2")
    }

    @Test("beginReply opens composer targeting the alert")
    func begins() {
        let s = NotchState()
        s.beginReply(to: alert())
        #expect(s.replyCompose?.targetAlert.title == "proj")
        #expect(s.replyCompose?.draft == "")
    }

    @Test("updateReplyDraft records text and clears prior error")
    func updates() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.setReplyError("boom")
        s.updateReplyDraft("hello")
        #expect(s.replyCompose?.draft == "hello")
        #expect(s.replyCompose?.errorText == nil)
    }

    @Test("cancelReply clears the composer")
    func cancels() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.cancelReply()
        #expect(s.replyCompose == nil)
    }

    @Test("mutators no-op when composer is closed")
    func noopWhenClosed() {
        let s = NotchState()
        s.updateReplyDraft("x")
        s.setReplyError("y")
        #expect(s.replyCompose == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests/NotchState_reply_compose`
Expected: FAIL — `ReplyComposeState` / `replyCompose` undefined. (If the suite name with spaces isn't addressable, run the whole `NotchPillTests` target; expect this suite's tests to fail.)

- [ ] **Step 3: Implement in `NotchState.swift`**

Add near the other `@Published` properties (after `devReadyAlerts`):

```swift
    /// Active reply composer, non-nil while the user is typing a reply to a
    /// finished agent. nil = not composing.
    @Published private(set) var replyCompose: ReplyComposeState?
```

Add the struct at file scope (above or below the class) — keep it in this file:

```swift
/// The in-notch reply composer's state: which agent it targets and the draft.
struct ReplyComposeState: Equatable {
    var targetAlert: DevReadyAlert
    var draft: String = ""
    var errorText: String? = nil
}
```

Add mutators inside `NotchState` (new `// MARK: - Reply compose` section):

```swift
    // MARK: - Reply compose

    func beginReply(to alert: DevReadyAlert) {
        replyCompose = ReplyComposeState(targetAlert: alert)
    }

    func updateReplyDraft(_ text: String) {
        guard replyCompose != nil else { return }
        replyCompose?.draft = text
        replyCompose?.errorText = nil
    }

    func setReplyError(_ message: String) {
        guard replyCompose != nil else { return }
        replyCompose?.errorText = message
    }

    func cancelReply() {
        replyCompose = nil
    }
```

- [ ] **Step 4: Run to verify it passes**

Run the `NotchPillTests` target (or the suite): expect the 4 compose tests PASS.

- [ ] **Step 5: Commit**

```bash
git add NotchPill/Core/NotchState.swift NotchPillTests/NotchPillTests.swift
git commit -m "feat: NotchState reply-compose state machine"
```

---

## Task 3: Settings gate + Preferences toggle

**Files:**
- Modify: `NotchPill/Core/Settings.swift`
- Modify: `NotchPill/Views/PreferencesView.swift`

**Interfaces:**
- Produces: `AppSettings.shared.agentReplyEnabled: Bool` (default true).

**Note:** mirror the existing boolean setting `devReadyPlaySound` exactly — same registration in `registerDefaults`/`init`/`reset` and the same `@Published`/`didSet`-persist pattern this file already uses. Read `Settings.swift` and copy that setting's shape for `agentReplyEnabled` (default `true`).

- [ ] **Step 1: Add the setting**

In `Settings.swift`, wherever `devReadyPlaySound` is declared and defaulted, add an analogous `agentReplyEnabled` with default `true` (property, default registration, and reset).

- [ ] **Step 2: Add the Preferences toggle**

In `PreferencesView.swift`, next to the existing dev-ready toggles (e.g. near `Toggle("Play a sound", isOn: $settings.devReadyPlaySound)`), add:

```swift
Toggle("Reply to agents from the notch", isOn: $settings.agentReplyEnabled)
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add NotchPill/Core/Settings.swift NotchPill/Views/PreferencesView.swift
git commit -m "feat: agentReplyEnabled setting + preferences toggle"
```

---

## Task 4: Actions + controller wiring + layout

**Files:**
- Modify: `NotchPill/Views/NotchActions.swift`
- Modify: `NotchPill/Core/NotchContentLayout.swift`
- Modify: `NotchPill/Core/NotchController.swift`

**Interfaces:**
- Consumes: `TerminalReplyInjector.send`, `NotchState.beginReply/cancelReply/setReplyError`, `AccessibilityAuthorization`.
- Produces: `NotchActions.beginReply`, `NotchActions.sendReply`; `NotchContentLayout.replyComposeLayout(metrics:)`; controller behavior — pause auto-dismiss + make panel key while `replyCompose != nil`.

- [ ] **Step 1: Extend `NotchActions`**

In `NotchActions.swift` add two fields and update `.noop`:

```swift
    var beginReply: (DevReadyAlert) -> Void
    var sendReply: (DevReadyAlert, String) -> Void

    static let noop = NotchActions(
        togglePlayPause: {}, next: {}, previous: {},
        focusApp: { _ in }, dismissDevReady: { _ in },
        beginReply: { _ in }, sendReply: { _, _ in }
    )
```

- [ ] **Step 2: Add `replyComposeLayout`**

In `NotchContentLayout.swift`, mirror `updateLayout(metrics:)` (a fixed-size composer panel). Use a width close to the dev-ready width and a height that fits a one-line field + target label + hint (~a bit taller than `updateLayout`). Read `updateLayout` and `devReadyLayout` and produce:

```swift
    static func replyComposeLayout(metrics: NotchMetrics) -> NotchContentLayoutMetrics {
        // Same construction shape as updateLayout; fixed composer size.
        // width: match updateLayout's width; height: notchHeight + topGap + ~92.
        // (Copy updateLayout's field construction; only the size differs.)
    }
```

- [ ] **Step 3: Wire the actions in `NotchController.makeRootView`**

Where `NotchActions(...)` is constructed (currently includes `dismissDevReady: { ... }`), add:

```swift
            beginReply: { [weak self] alert in self?.state.beginReply(to: alert) },
            sendReply: { [weak self] alert, text in self?.performReply(alert: alert, text: text) }
```

Add the `performReply` method to `NotchController`:

```swift
    private func performReply(alert: DevReadyAlert, text: String) {
        if let err = TerminalReplyInjector.send(text: text, bundleId: alert.bundleId) {
            switch err {
            case .accessibilityDenied:
                state.setReplyError("Grant Accessibility to send replies")
                AccessibilityAuthorization.requestSystemPrompt()
            case .targetNotRunning:
                state.setReplyError("\(alert.source ?? "Terminal") isn't running")
            case .emptyText, .noTarget:
                state.setReplyError("Couldn't send reply")
            }
            return
        }
        // Success: close composer and dismiss that agent's peek.
        state.cancelReply()
        dismissDevReady(id: alert.id)
    }
```

- [ ] **Step 4: Pause auto-dismiss + make panel key while composing**

In `NotchController`, subscribe to `state.$replyCompose` (add alongside the existing Combine wiring near line ~121, or in the same place providers are started). On change:

```swift
        state.$replyCompose
            .receive(on: RunLoop.main)
            .sink { [weak self] compose in
                guard let self else { return }
                if compose != nil {
                    self.devReadyDismissItem?.cancel()      // hold the peek open
                    self.window?.makeKeyAndOrderFront(nil)  // accept typing (nonactivating panel → no app switch)
                } else {
                    // Don't call resignKey() directly (system-owned). On send,
                    // performReply activates the terminal which takes key away;
                    // on cancel the nonactivating panel simply stops needing key.
                    self.scheduleDevReadyDismiss()          // resume normal timeout
                }
            }
            .store(in: &cancellables)   // use the controller's existing cancellables set
```

If there is no existing `cancellables` Set on the controller, add `private var cancellables = Set<AnyCancellable>()` and `import Combine`.

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build`
Expected: BUILD SUCCEEDED. (No UI yet triggers `beginReply`; that arrives in Tasks 5–6.)

- [ ] **Step 6: Commit**

```bash
git add NotchPill/Views/NotchActions.swift NotchPill/Core/NotchContentLayout.swift NotchPill/Core/NotchController.swift
git commit -m "feat: wire reply actions, composer layout, dismiss-pause + key window"
```

---

## Task 5: Composer view + NotchRootView branch

**Files:**
- Modify: `NotchPill/Views/NotchRootView.swift`

**Interfaces:**
- Consumes: `NotchState.replyCompose`, `NotchActions.sendReply`, `NotchState.updateReplyDraft/cancelReply`, `NotchContentLayout.replyComposeLayout`.
- Produces: `ReplyComposeView`; compose branch rendered above dev-ready.

- [ ] **Step 1: Add `ReplyComposeView`** (in `NotchRootView.swift`, file scope)

```swift
/// In-notch reply composer: a focused text field targeting the finished agent.
struct ReplyComposeView: View {
    @ObservedObject var state: NotchState
    let compose: ReplyComposeState
    let actions: NotchActions
    @FocusState private var fieldFocused: Bool

    private var targetLabel: String {
        let a = compose.targetAlert
        let terminal = a.source ?? "Terminal"
        return "→ \(a.title) · \(terminal)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NotchDesign.accent)
                Text(targetLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            TextField("Reply…", text: Binding(
                get: { state.replyCompose?.draft ?? "" },
                set: { state.updateReplyDraft($0) }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .focused($fieldFocused)
            .onSubmit { actions.sendReply(compose.targetAlert, state.replyCompose?.draft ?? "") }
            .onExitCommand { state.cancelReply() }   // Esc
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))

            if let err = compose.errorText {
                Text(err)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                Text("Enter to send · Esc to cancel")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { fieldFocused = true }
    }
}
```

- [ ] **Step 2: Add the layout branch** — in `contentLayout` (top of the priority chain, above `updateProgress`? No: keep `updateProgress` highest, place compose above devReady):

```swift
        if state.updateProgress != nil {
            return NotchContentLayout.updateLayout(metrics: metrics)
        }
        if state.replyCompose != nil {
            return NotchContentLayout.replyComposeLayout(metrics: metrics)
        }
        if !state.devReadyAlerts.isEmpty {
            return NotchContentLayout.devReadyLayout(metrics: metrics, alerts: state.devReadyAlerts)
        }
```

- [ ] **Step 3: Add background + overlay branches**

In the background `ZStack` condition (currently `if state.isExpanded || !state.devReadyAlerts.isEmpty || state.updateProgress != nil`), add `|| state.replyCompose != nil`.

In the `.overlay(alignment: .top)` chain, add a branch **above** the devReady branch:

```swift
            } else if let compose = state.replyCompose {
                replyComposeContent(compose)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            } else if !state.devReadyAlerts.isEmpty {
```

Add the content helper (mirror `updateProgressContent`):

```swift
    private func replyComposeContent(_ compose: ReplyComposeState) -> some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: metrics.notchHeight)
            ReplyComposeView(state: state, compose: compose, actions: actions)
                .padding(.top, metrics.topGap + 2)
                .frame(width: frameSize.width,
                       height: frameSize.height - metrics.notchHeight - metrics.topGap,
                       alignment: .top)
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .top)
    }
```

- [ ] **Step 4: Add animation** — add near the other `.animation(...)` modifiers:

```swift
        .animation(expandAnimation, value: state.replyCompose != nil)
```

- [ ] **Step 5: Build + manual check**

Run: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build` → BUILD SUCCEEDED.
Manual (temporary): from a debug run, call `state.beginReply(to:)` via the Preferences test-ping path or a scratch trigger, confirm the composer renders in the notch and the field accepts typing (this validates the key-window path — the primary risk item). Remove any scratch trigger before committing.

- [ ] **Step 6: Commit**

```bash
git add NotchPill/Views/NotchRootView.swift
git commit -m "feat: in-notch reply composer view + render branch"
```

---

## Task 6: Reply button on the peek row

**Files:**
- Modify: `NotchPill/Views/Tiles.swift`

**Interfaces:**
- Consumes: `NotchActions.beginReply`, `TerminalReplyInjector.canTarget`, `AppSettings.shared.agentReplyEnabled`.
- Produces: a reply control on `DevReadyPeekRow` that opens the composer for that alert.

**Note:** the row is currently a single `Button(action: handleTap)`. SwiftUI does not nest buttons cleanly, so restructure: keep the existing content as the tap-to-focus button, and add a **separate** trailing reply `Button` as a sibling in an outer `HStack`, so the two controls don't overlap. The reply button appears only when `AppSettings.shared.agentReplyEnabled && TerminalReplyInjector.canTarget(alert)`.

- [ ] **Step 1: Restructure `DevReadyPeekRow.body`**

Wrap the existing focus `Button` and the new reply button in an outer `HStack(spacing: 0)`. Move the trailing `chevron.right` inside the focus button as today. Add the reply button after it:

```swift
    var body: some View {
        HStack(spacing: 6) {
            Button(action: handleTap) {
                rowContent   // existing HStack content (dot, icon, texts, Spacer, chevron)
            }
            .buttonStyle(.plain)

            if AppSettings.shared.agentReplyEnabled, TerminalReplyInjector.canTarget(alert) {
                Button { actions.beginReply(alert) } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Reply in the notch")
            }
        }
        .padding(.horizontal, 12)
    }
```

Extract the current inner `HStack { … }` (dot + `sourceIcon` + texts + `Spacer` + chevron) into a `private var rowContent: some View`, removing its outer `.padding(.horizontal, 12)` (now applied on the row) so spacing is unchanged. Keep the existing pulse/`onAppear` behavior on `rowContent`.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build` → BUILD SUCCEEDED.

- [ ] **Step 3: Manual verification (E2E)**

1. Ensure `~/.claude/settings.json` has the Stop hook (already wired). Finish a real Claude Code turn in a supported terminal (iTerm/Ghostty/Terminal). A peek with a **reply icon** appears.
2. Tap the reply icon → composer opens, field focused.
3. Type "say the word banana" → Enter → the terminal comes forward, text pastes and submits; the peek dismisses.
4. Confirm tapping the **row body** still just focuses the terminal (no regression).
5. Toggle the setting off in Preferences → reply icon disappears from new peeks.

- [ ] **Step 4: Commit**

```bash
git add NotchPill/Views/Tiles.swift
git commit -m "feat: reply button on dev-ready peek rows"
```

---

## Final Review

After Task 6, dispatch the whole-branch code review (`git merge-base main HEAD` … HEAD). Focus areas for the reviewer:
- Clipboard save/restore always runs, including on early return / error paths.
- No path posts keystrokes without `AccessibilityAuthorization.isGranted`.
- Tap-to-focus on the row body is unchanged (no nested-button regression).
- The `state.$replyCompose` subscription doesn't retain-cycle the controller and correctly reschedules dismiss when composing ends with peeks still present.
- Compose branch priority in `NotchRootView` is consistent across `contentLayout`, background, and overlay (all three updated).

Then use superpowers:finishing-a-development-branch.

## Manual E2E acceptance (whole feature)

- Reply lands + submits in at least two different terminal apps (proves tool-agnostic delivery).
- Unknown-terminal peek (empty `bundleId`) shows **no** reply icon.
- Target terminal quit before send → error line in composer, draft preserved, no crash.
- Accessibility revoked → error line + system prompt, no crash.
