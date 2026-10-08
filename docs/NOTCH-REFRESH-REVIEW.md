# Notch refresh review and Wave 3 handoff

Reviewed the shared uncommitted workspace against the Wave 1/Wave 2 handoff on October 8, 2026. Luna agents investigated issues first; Sol agents implemented verified fixes. Existing work was preserved. No app installation, release publication, or Git commit was performed.

## Fixes

- Returning collapsed chips now use their own short opacity insertion transition. Opening removal still inherits the existing handoff, and the surface retains its shared opening/closing spring. Rendered tests cover the intermediate fade, re-hover, unchanged surface progress, and Reduce Motion.
- The dev build script locates processes by executable path, verifies bundle identity and start time, and uses bounded shutdown without System Events. Prebuild shutdown covers only source/staged apps being overwritten. The installed dev app remains running until installation; `--no-install` does not stop it. Lookup/shutdown failures abort replacement.
- Claude/Cursor usage cards hide immediately when their own switches are disabled, even if agents or CI keep the scanner alive. Disabled quota state is cleared, stale publications are suppressed, and snapshots gate cached quota values.
- Process timeout/cancellation signals only an owned process group, with a direct-PID fallback when ownership cannot be established. Escalation reaches descendants even after the direct child exits. PID-file tests verify cleanup and normal-success behavior.
- Update downloads validate the initial origin, every redirect, and the final HTTP 200 response before staging. The trusted origins include GitHub's release-assets CDN, with host-boundary checks.
- External-display visual fixtures now correctly use `hasPhysicalNotch: false`.
- PTY launch prepares shell/directory strings, login arguments, and the environment before `forkpty`. The child only uses prepared C pointers and `chdir`, `execve`, and `_exit`. Tests use explicit `/bin/sh`, completion markers, and neutral prompts to avoid login-profile output and echoed commands falsely satisfying assertions. New checks cover environment, directory, login arguments, exec failure, and six concurrent launches.

## Wave 3 layout dependency

The polished shoulder path is currently used by the compact surface. Hover and peek backgrounds/masks still use the rectangular `PillSurface`/`NotchShape` geometry. A direct shoulder swap clips existing content: the ledge starts about 17 points below the notch and full width is reached at about 31 points, while tray headers begin at about 12 points and peeks at about 2 points.

Keep the shoulder geometry, header/peek clearance, content height, artwork clipping, and content mask changes together in Wave 3. Comparison fixtures (`wave1-*.png`) make the clipping visible; they are a development comparison, not the current production appearance. The generic `ExpandedPillSurface` backdrop supports those fixtures with one rim above artwork.

Wave 3 should also improve spacing, type hierarchy and small-text contrast while preserving true black, readable size preferences, pixel alignment, Reduce Motion, and the existing interruptible surface spring. Validate both notched and floating displays plus reduced-size layouts. Do not treat these fixtures as an OLED hardware measurement.

## Validation

The pre-fix baseline passed all 902 test cases. Focused updater, runtime, and visual checks passed, including 42 rendered comparison/current fixtures and mocked build-script process checks. The first combined run passed 912 of 913 test cases; only the pre-existing controlling-terminal test failed with blank output. Its isolated suite then passed.

A subsequent Luna review found unsafe Swift/Foundation allocation in the PTY child after `forkpty`. That bug is now fixed; it fits the blank-output symptom but the cause of the earlier failing run was not proven. All 20 focused PTY/terminal-store checks passed after the fix. Failed-exec coverage checks bounded termination, rather than exact status, because existing EOF and wait-status delivery can race.

The final combined suite passed all **918 test cases** (926 executions including parameterized cases), with zero failures or skips. It regenerated 42 visual fixtures. `bash -n Scripts/build-dev.sh` and `git diff --check` also passed. The final log is `/tmp/notchpill-final-verified-tests.log`; the Xcode result bundle is `build/Review/Logs/Test/Test-NotchPill-2026.10.08_11-05-21--0400.xcresult`.

Logs and fixtures from this review are under `/tmp/notchpill-*-tests.log`, `/tmp/notchpill-final-visuals`, and `/tmp/notchpill-review-visuals`. Xcode result bundles are under `build/Review/Logs/Test` and the per-agent `build/Sol*` directories.

## Wave 3

The production expanded background and content mask now share `ExpandedNotchShape` on a fixed final canvas. A single `surfaceTopInset` clears the entire shoulder and supplies the same top spacer and height budget for decks, peeks, replies, and update progress. Card body/footer budgets remain intact; compact chip sizing and the reviewed opening/collapse spring are preserved.

Titles are now 14pt, body text 12pt, and captions/monospaced metadata 10pt before user compensation. Supporting white text uses 0.72 opacity and metadata 0.60 on black. Decorative paint retains its existing opacity. Shared headings, picker controls, clipboard states, CI metadata, and quota scrolling were refined; collapsed media artist text and peek pin instructions use the readable roles.

All **928 unique tests** passed (936 executions, no failures or skips) in `build/Wave3Review/Logs/Test/Test-NotchPill-2026.10.08_11-20-01--0400.xcresult`; log `/tmp/notchpill-wave3-verified.log`. The 54 current/legacy fixtures in `/tmp/notchpill-wave3-visuals` include dense agents and usage, media, notification, clipboard states, and picker across built-in, floating, and scaled displays. Captures wait for the short Reduce Motion reveal before recording. Inspected captures show clear shoulders and legible headers without unintended clipping. The surface remains vector-drawn and black; this is not a physical OLED panel calibration or an increase in display hardware resolution.

Wave 3 Dev installation completed with `Scripts/build-dev.sh`; `/Applications/NotchPill Dev.app` is running. Its executable SHA-256 matches the freshly staged build (`f0b88a34e9988ab1252e37797b31b39ae3e572875f4ac1c083ac76f18326b15b`), and strict code-signature verification passed. Build/install log: `/tmp/notchpill-wave3-install.log`.

## Whole-notch expansion and usage fit follow-up

Per the visual feedback, expanded cards now use the entire hardware notch as their starting outline. Side walls widen at hardware height while the bottom descends with the same spring progress. Compact chips retain their original shallow shoulders; floating displays retain their capsule. The expanded background, artwork clip, and content mask use the same outline. Hardware content clearance is now 12pt rather than the old 36pt shoulder allowance.

Claude, Codex, and Cursor summaries no longer use a scroll view. `UsageCardFit` measures all existing summary/detail rows and uniformly fits overflow to the chosen card canvas while retaining its full available width. Larger summaries therefore scale down when necessary; no rows require vertical scrolling. Fixtures now exercise token totals, cached tokens, model breakdown, and credits together and reserve the same footer allowance as production.

All **930 unique tests** passed (938 executions, zero failures or skips). Result: `build/Wave3Review/Logs/Test/Test-NotchPill-2026.10.08_11-42-15--0400.xcresult`; log `/tmp/notchpill-whole-notch-final.log`. New coverage checks widening at hardware height throughout expansion and verifies a tall usage summary's last row remains visible without an AppKit scroll view on three canvas heights. Visual fixtures: `/tmp/notchpill-whole-notch-visuals`. Rebuilt and launched NotchPill Dev; build/install log `/tmp/notchpill-whole-notch-install.log`.
