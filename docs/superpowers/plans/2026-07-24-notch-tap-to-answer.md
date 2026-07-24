# Notch Tap-to-Answer — Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a CLI agent blocks waiting for a permission/choice answer, show a "waiting" peek in the notch (question text + Yes/No/1/2/3 buttons + free-text) and deliver a one-tap answer into the terminal.

**Architecture:** A new Claude Code **Notification hook** posts a `kind=waiting` signal (with the notification `message`) through the existing `notify-notchpill.sh` → `DevReadyProvider` → `DevReadyAlert` path. `DevReadyAlert` gains `kind` (`finished`|`waiting`, default `finished`) + `message`. A `.waiting` alert renders a distinct peek with answer buttons that reuse Phase 1's `TerminalReplyInjector` to send the keystroke + Return.

**Tech Stack:** Swift, AppKit/SwiftUI, Combine, bash. Tests: **Swift Testing** (`@Suite`/`@Test`/`#expect`), NOT XCTest.

**Design doc:** `docs/superpowers/specs/2026-07-24-notch-tap-to-answer-design.md`

## Global Constraints

- **Swift Testing only** (never XCTest).
- **Backward compatibility:** existing "finished" signals omit `kind`/`message` and MUST still decode (→ `kind == .finished`, `message == nil`). No behavior change to Phase 1 finished pings.
- **Never blind-fire:** answer buttons appear only when `bundleId` is targetable (reuse `TerminalReplyInjector.canTarget`). Reuse Phase 1's Accessibility gate and clipboard save/restore (already in `send`).
- **Reuse, don't fork:** answers go through the existing `TerminalReplyInjector.send`. Do not add a second delivery path.
- **One gate:** `AppSettings.shared.agentReplyEnabled` governs both reply and answer UI. No new setting.
- **New `.swift` files under `NotchPill/`** auto-include (no `.xcodeproj` edits).
- Build: `xcodebuild -project NotchPill.xcodeproj -scheme NotchPill -configuration Debug build`
- Tests: `xcodebuild test -project NotchPill.xcodeproj -scheme NotchPill -destination 'platform=macOS' -only-testing:NotchPillTests`

---

## File Structure

**Modify:**
- `Scripts/notify-notchpill.sh` — carry optional `kind` + `message`.
- `Scripts/claude-code-notify.sh` — add a `Notification` event branch.
- `NotchPill/Core/Models.swift` — `AlertKind` + `message` on `DevReadyAlert`, backward-compat decode.
- `NotchPill/Core/NotchState.swift` — waiting-peek lifecycle (replace-per-terminal, answer clears).
- `NotchPill/Views/NotchActions.swift` — an `answer` action.
- `NotchPill/Core/NotchController.swift` — wire the answer action to `TerminalReplyInjector`; keep waiting peeks from short auto-dismiss.
- `NotchPill/Core/NotchContentLayout.swift` — `waitingLayout`.
- `NotchPill/Views/NotchRootView.swift` / `NotchPill/Views/Tiles.swift` — waiting-peek render + answer buttons.
- `docs/CLAUDE-CODE-HOOK.md` — document the Notification hook.

**Create:**
- `NotchPill/Core/AgentAnswer.swift` — pure button→keystroke mapping.

**Interfaces (locked):**

```swift
// Models.swift
enum AlertKind: String, Codable { case finished, waiting }
// DevReadyAlert gains: var kind: AlertKind (default .finished), var message: String?

// AgentAnswer.swift
enum AgentAnswer: Equatable {
    case yes, no, digit(Int)
    var keystroke: String            // "y", "n", "1"…
    var appendsReturn: Bool          // decided by Task 1 spike; default true
    var label: String                // "Yes","No","1"…
    static var standardSet: [AgentAnswer]   // [.yes,.no,.digit(1),.digit(2),.digit(3)]
}

// NotchActions.swift (added)
var answer: (DevReadyAlert, AgentAnswer) -> Void

// NotchState.swift (added)
func enqueueWaiting(_ alert: DevReadyAlert)   // replaces any prior waiting alert for the same bundleId
```

---

## Task 1: Spike — capture the Notification-hook payload (controller-run)

**This task is run by the controller directly, not a dispatched implementer** — it observes THIS Claude Code session's own notifications and edits `~/.claude/settings.json`.

**Goal:** Learn the real payload before building on it, and decide the `appendsReturn` default.

- [ ] **Step 1:** Add a temporary Notification hook to `~/.claude/settings.json` that appends stdin to a log:
  `"Notification": [ { "hooks": [ { "type": "command", "command": "cat >> /tmp/np-notif-payload.log; echo '---' >> /tmp/np-notif-payload.log" } ] } ]`
  (Back up settings.json first; this is additive.)
- [ ] **Step 2:** Trigger notifications: let the session go idle (idle "waiting for input" notification), and if reachable, a permission prompt. Read `/tmp/np-notif-payload.log`.
- [ ] **Step 3:** Record findings to `docs/superpowers/plans/phase2-spike-findings.md` (commit): does the payload include a usable `message`? a `cwd`? a `session_id`? Does it fire on permission prompts? What fields exist verbatim.
- [ ] **Step 4:** Decide `appendsReturn` default by testing delivery into a Claude Code permission prompt vs a raw `read -p "(y/n)"` prompt (manually fire a `kind=waiting` signal after Task 3, or reason from the TUI behavior): does a digit keypress self-confirm (no Return) or need Return? Record the decision; it sets `AgentAnswer.appendsReturn`.
- [ ] **Step 5:** Remove the temporary logging hook (restore settings.json backup). **Go/no-go:** if the Notification hook does not fire on permission prompts at all, STOP and escalate — the feature's detection premise fails. If it fires but carries no useful `message`, proceed with the generic-peek fallback (message is optional throughout).
- [ ] **Step 6:** Commit the findings doc.

**Downstream:** Tasks 3, 5, 6 read this doc. The `message: String?` optionality means tasks 2/4/6 are correct regardless of message availability.

---

## Task 2: `AlertKind` + `message` on `DevReadyAlert` (backward-compat decode)

**Files:** Modify `NotchPill/Core/Models.swift`; Test `NotchPillTests/NotchPillTests.swift`.

**Interfaces:** Produces `AlertKind`, `DevReadyAlert.kind`, `DevReadyAlert.message`.

- [ ] **Step 1: Write failing tests** (append to `NotchPillTests.swift`)

```swift
@Suite("DevReadyAlert kind/message")
struct DevReadyAlertKindTests {
    @Test("legacy JSON without kind decodes as .finished, no message")
    func legacyDecodes() {
        let data = #"{"id":"a","title":"proj","subtitle":"finished","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a != nil)
        #expect(a?.kind == .finished)
        #expect(a?.message == nil)
    }

    @Test("waiting JSON decodes kind + message")
    func waitingDecodes() {
        let data = #"{"id":"b","title":"proj","kind":"waiting","message":"Claude needs permission to run Bash","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a?.kind == .waiting)
        #expect(a?.message == "Claude needs permission to run Bash")
    }

    @Test("unknown kind falls back to .finished")
    func unknownKind() {
        let data = #"{"id":"c","title":"proj","kind":"bogus"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: data)?.kind == .finished)
    }

    @Test("userInfo path reads kind + message")
    func userInfoDecodes() {
        let a = DevReadyAlert.parse(userInfo: ["title":"proj","kind":"waiting","message":"pick one"])
        #expect(a?.kind == .waiting)
        #expect(a?.message == "pick one")
    }
}
```

- [ ] **Step 2: Run to verify fail.** Expected: `kind`/`message` undefined → compile error.

- [ ] **Step 3: Implement in `Models.swift`.**

Add the enum at file scope:
```swift
/// Whether an agent alert is a completed task (finished) or a pending question (waiting).
enum AlertKind: String, Codable { case finished, waiting }
```

Add stored properties to `DevReadyAlert` (after `bundleId`):
```swift
    var kind: AlertKind = .finished
    var message: String?
```
Add `kind`/`message` params (defaulted) to the memberwise `init(...)` so existing call sites are unaffected.

Because `kind` must default when absent, add a custom decoder (Swift won't default a missing key with synthesized Codable):
```swift
    enum CodingKeys: String, CodingKey { case id, title, subtitle, source, agent, bundleId, kind, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(String.self, forKey: .id)) ?? UUID().uuidString
        title = try c.decode(String.self, forKey: .title)
        subtitle = try? c.decode(String.self, forKey: .subtitle)
        source = try? c.decode(String.self, forKey: .source)
        agent = try? c.decode(String.self, forKey: .agent)
        bundleId = try? c.decode(String.self, forKey: .bundleId)
        kind = (try? c.decode(AlertKind.self, forKey: .kind)) ?? .finished
        message = try? c.decode(String.self, forKey: .message)
    }
```
(Keep the existing `parse(from:)` using `JSONDecoder().decode` — it now routes through this initializer, so an unknown `kind` string makes `decode(AlertKind...)` fail → `?? .finished`.)

In `parse(userInfo:)`, add after the existing fields:
```swift
        let kindRaw = userInfo["kind"] as? String
        // ... pass into the constructor:
        kind: AlertKind(rawValue: kindRaw ?? "") ?? .finished,
        message: userInfo["message"] as? String
```

- [ ] **Step 4: Run tests → pass.**

- [ ] **Step 5: Commit** (`git add Models.swift NotchPillTests…; git commit -m "feat: DevReadyAlert kind (finished|waiting) + message, backward-compatible"`)

---

## Task 3: Signal scripts + Notification hook

**Files:** Modify `Scripts/notify-notchpill.sh`, `Scripts/claude-code-notify.sh`, `docs/CLAUDE-CODE-HOOK.md`.

**Consumes:** Task 1 findings (exact `message`/`cwd` field names). **Produces:** `kind=waiting` signals reaching `DevReadyAlert`.

- [ ] **Step 1: `notify-notchpill.sh` — carry `kind` + `message`.** Add positional args `KIND="${6:-finished}"` and `MESSAGE="${7:-}"`. Thread them into BOTH payload builders (the swift `info` dict and the python `payload`), adding `if !kind.isEmpty && kind != "finished" { info["kind"] = kind }` / `if !message.isEmpty { info["message"] = message }` (and the python equivalents). Update the usage comment. For `kind=waiting`, **bypass the finished-dedup**: guard `notchpill_should_skip_notify`/`notchpill_record_notify` with `if [ "$KIND" != "waiting" ]` (waiting prompts must not be swallowed by the finished dedup window).

- [ ] **Step 2: `claude-code-notify.sh` — `Notification` branch.** Where `EVENT` is handled, add:
  ```bash
  if [[ "$EVENT" == "Notification" ]]; then
    MESSAGE="$(json_field message)"   # field name per Task 1 findings
    [[ -n "$MESSAGE" ]] || MESSAGE="Waiting for your input"
    exec "$ROOT/Scripts/notify-notchpill.sh" "$PROJECT" "${BRANCH:-}" "$TERM_NAME" "$TERM_BUNDLE" "claude-code" "waiting" "$MESSAGE"
  fi
  ```
  (Place it after `CWD`/`PROJECT`/`BRANCH`/`TERM_*` are resolved and before the Stop/SubagentStop title logic.)

- [ ] **Step 2b:** If Task 1 found `cwd` is NOT in the Notification payload, resolve `CWD` from `${CLAUDE_PROJECT_DIR:-$PWD}` for this branch (note it explicitly).

- [ ] **Step 3: Document** in `docs/CLAUDE-CODE-HOOK.md`: the new `Notification` hook line for `~/.claude/settings.json`:
  ```json
  "Notification": [ { "hooks": [ { "type": "command", "command": ".../Scripts/claude-code-notify.sh Notification", "timeout": 15, "async": true } ] } ]
  ```

- [ ] **Step 4: Manual verify (no unit tests for bash here):** fire `Scripts/notify-notchpill.sh "proj" "waiting" "Terminal" "com.apple.Terminal" "claude-code" "waiting" "Test question?"` and confirm (with the app running) a `kind=waiting` alert arrives (log/observe). State the result in the report.

- [ ] **Step 5: Commit.**

---

## Task 4: NotchState waiting-peek lifecycle

**Files:** Modify `NotchPill/Core/NotchState.swift`; Test `NotchPillTests`.

**Consumes:** `DevReadyAlert.kind`. **Produces:** `enqueueWaiting`, replace-per-bundleId semantics.

- [ ] **Step 1: Failing tests.**
```swift
@MainActor @Suite("NotchState waiting peeks")
struct NotchStateWaitingTests {
    private func waiting(_ msg: String, bundle: String = "com.apple.Terminal") -> DevReadyAlert {
        DevReadyAlert(title: "proj", bundleId: bundle, kind: .waiting, message: msg)
    }
    @Test("a new waiting alert replaces a prior waiting alert for the same terminal")
    func replacesPerTerminal() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1"))
        s.enqueueWaiting(waiting("q2"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 1)
        #expect(waits.first?.message == "q2")
    }
    @Test("waiting alerts for different terminals coexist")
    func differentTerminals() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", bundle: "com.apple.Terminal"))
        s.enqueueWaiting(waiting("q2", bundle: "com.googlecode.iterm2"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 2)
    }
    @Test("removeDevReady clears a waiting alert (answered)")
    func answeredClears() {
        let s = NotchState()
        let a = waiting("q1")
        s.enqueueWaiting(a)
        s.removeDevReady(id: a.id)
        #expect(s.devReadyAlerts.isEmpty)
    }
}
```

- [ ] **Step 2: Run → fail** (`enqueueWaiting` undefined).

- [ ] **Step 3: Implement `enqueueWaiting` in `NotchState`.** Mirror `enqueueDevReady` but replace any existing `.waiting` alert with the same `bundleId`:
```swift
    func enqueueWaiting(_ alert: DevReadyAlert) {
        devReadyAlerts.removeAll { $0.kind == .waiting && $0.bundleId == alert.bundleId }
        devReadyAlerts.append(alert)
    }
```
(`removeDevReady(id:)` already exists and clears by id — used for "answered".)

- [ ] **Step 4: Run → pass. Step 5: Commit.**

---

## Task 5: Answer delivery mapping + wiring

**Files:** Create `NotchPill/Core/AgentAnswer.swift`; Modify `NotchPill/Views/NotchActions.swift`, `NotchPill/Core/NotchController.swift`; Test `NotchPillTests`.

**Consumes:** `TerminalReplyInjector.send`, Task 1's `appendsReturn` decision. **Produces:** `AgentAnswer`, `NotchActions.answer`, controller delivery.

- [ ] **Step 1: Failing tests** for the pure mapping.
```swift
@Suite("AgentAnswer")
struct AgentAnswerTests {
    @Test("keystrokes map correctly")
    func keystrokes() {
        #expect(AgentAnswer.yes.keystroke == "y")
        #expect(AgentAnswer.no.keystroke == "n")
        #expect(AgentAnswer.digit(2).keystroke == "2")
    }
    @Test("labels")
    func labels() {
        #expect(AgentAnswer.yes.label == "Yes")
        #expect(AgentAnswer.digit(3).label == "3")
    }
    @Test("standard set is Yes/No/1/2/3")
    func standard() {
        #expect(AgentAnswer.standardSet == [.yes, .no, .digit(1), .digit(2), .digit(3)])
    }
}
```

- [ ] **Step 2: Run → fail.**

- [ ] **Step 3: Implement `AgentAnswer.swift`.**
```swift
/// A quick-answer choice sent to a waiting agent. Pure mapping to a keystroke.
enum AgentAnswer: Equatable {
    case yes, no, digit(Int)

    var keystroke: String {
        switch self {
        case .yes: return "y"
        case .no: return "n"
        case .digit(let n): return String(n)
        }
    }
    var label: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .digit(let n): return String(n)
        }
    }
    /// Whether Return is appended after the keystroke. Set per Task 1 spike
    /// (default true — raw y/n readline prompts need it; adjust if the target
    /// TUI self-confirms on keypress).
    var appendsReturn: Bool { true }

    static let standardSet: [AgentAnswer] = [.yes, .no, .digit(1), .digit(2), .digit(3)]
}
```
(If Task 1 decided digits must NOT append Return, change `appendsReturn` to `case .digit: return false` and add a test asserting it.)

- [ ] **Step 4: Extend `NotchActions`** with `var answer: (DevReadyAlert, AgentAnswer) -> Void` and update `.noop`.

- [ ] **Step 5: Wire in `NotchController.makeRootView`** (alongside `sendReply`):
```swift
            answer: { [weak self] alert, ans in self?.performAnswer(alert: alert, answer: ans) }
```
and add:
```swift
    private func performAnswer(alert: DevReadyAlert, answer: AgentAnswer) {
        if let err = TerminalReplyInjector.send(text: answer.keystroke, bundleId: alert.bundleId,
                                                appendReturn: answer.appendsReturn) {
            switch err {
            case .accessibilityDenied: state.setReplyError("Grant Accessibility to answer"); AccessibilityAuthorization.requestSystemPrompt()
            case .targetNotRunning: state.setReplyError("\(alert.source ?? "Terminal") isn't running")
            case .emptyText, .noTarget: state.setReplyError("Couldn't send answer")
            }
            return
        }
        state.removeDevReady(id: alert.id)   // dismiss the answered waiting peek (existing public method)
    }
```
- [ ] **Step 5b:** `TerminalReplyInjector.send` currently always appends Return. Add an `appendReturn: Bool = true` parameter; when false, skip the `postReturn()` call. Existing callers keep working via the default. (Small edit to `send`; the frontmost-poll and clipboard logic are unchanged.) Note: `setReplyError` requires an open composer — for a button answer there's no composer, so instead surface answer errors by keeping the waiting peek visible and (optionally) stashing the error on the alert; simplest for v1: on error, do NOT remove the peek and rely on the Accessibility system prompt / the user retrying. Decide during implementation; do not force `setReplyError` when `replyCompose` is nil.

- [ ] **Step 6: Run tests → pass. Build. Commit.**

---

## Task 6: Waiting-peek UI

**Files:** Modify `NotchPill/Views/Tiles.swift`, `NotchPill/Views/NotchRootView.swift`, `NotchPill/Core/NotchContentLayout.swift`.

**Consumes:** `AgentAnswer.standardSet`, `NotchActions.answer`, `DevReadyAlert.kind/message`. **Produces:** the `.waiting` peek render.

- [ ] **Step 1: `waitingLayout`** in `NotchContentLayout` — mirror `devReadyLayout`/`replyComposeLayout`; sized for a message line + a button row (height ≈ notchHeight + topGap + ~70). Read `devReadyLayout` and match the `NotchContentLayoutMetrics` field construction.

- [ ] **Step 2: Render branch.** Waiting and finished alerts both live in `state.devReadyAlerts` and are rendered by the existing `DevReadyPeekListView` → `DevReadyPeekRow`; the row branches on `alert.kind` (Step 3). **Sizing rule (pin — do NOT leave open):** in the four Phase-1 layout sites (`NotchRootView.contentLayout`, the background `ZStack` condition, the `.overlay` chain, and `NotchController.expandedContentSize`), when `state.devReadyAlerts.contains(where: { $0.kind == .waiting })`, use `NotchContentLayout.waitingLayout(metrics:)` (taller — fits the message + button row); otherwise the existing `devReadyLayout`. Keep this condition identical across all four sites (the Phase-1 final review caught an inconsistency here — match all four). The `.waiting` sizing takes precedence over the finished `devReadyLayout` but stays BELOW `replyCompose` and `updateProgress` in the priority chain.

- [ ] **Step 3: Answer buttons UI** in `DevReadyPeekRow` (gated by `AppSettings.shared.agentReplyEnabled && TerminalReplyInjector.canTarget(alert)`):
```swift
if alert.kind == .waiting {
    if let m = alert.message, !m.isEmpty {
        Text(m).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(2)
    }
    HStack(spacing: 6) {
        ForEach(AgentAnswer.standardSet.indices, id: \.self) { i in
            let ans = AgentAnswer.standardSet[i]
            Button { actions.answer(alert, ans) } label: {
                Text(ans.label).font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
            }.buttonStyle(.plain)
        }
    }
    // plus the existing reply ↰ button for free-text
}
```

- [ ] **Step 4: Build → BUILD SUCCEEDED.** Run test target (no regressions).

- [ ] **Step 5: Manual E2E** (with Task 1/3 hook installed): trigger a real Claude Code permission prompt → waiting peek shows message + buttons → tap **Yes** → Claude proceeds; tap **No** on another → denied. Also fire a manual `kind=waiting` signal and confirm buttons deliver `y`/`n`/digit+Return into a live terminal.

- [ ] **Step 6: Commit.**

---

## Final Review

Dispatch the whole-branch review (`git merge-base main HEAD`..HEAD). Focus: backward-compat decode (finished pings unaffected), waiting-peek lifecycle (no stuck/duplicate waiting peeks), the `appendReturn` change to `send` doesn't regress Phase 1 reply (default true), render-branch consistency across the 4 layout sites, and the never-blind-fire gate on answer buttons. Then superpowers:finishing-a-development-branch.

## Manual E2E acceptance (whole feature)

- Real Claude Code permission prompt → tap Yes proceeds, tap No denies.
- Finished pings still behave exactly as v1.3.0 (no regression).
- Waiting peek for terminal A isn't replaced by a finished ping for terminal B.
- Unknown-terminal (no bundleId) waiting alert shows no answer buttons.
