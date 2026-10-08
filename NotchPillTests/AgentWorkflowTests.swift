import Testing
import Foundation
import Combine
import CoreAudio
import AppKit
import SwiftUI
@testable import NotchPill

@Suite("Focused activity ordering")
struct FocusedActivityTests {
    @Test("known agents retain a jump target when an old hook omits its host")
    func knownAgentJumpFallbacks() {
        let codex = DevReadyAlert(title: "Done", agent: "codex")
        let cursor = DevReadyAlert(title: "Done", agent: "cursor")
        let claudeInCmux = DevReadyAlert(title: "Done", source: "cmux", agent: "claude-code")
        #expect(codex.jumpTargetBundleIds == ["com.openai.codex"])
        #expect(cursor.jumpTargetBundleIds == ["com.todesktop.230313mzl4w4u92"])
        #expect(claudeInCmux.jumpTargetBundleIds == ["com.cmuxterm.app"])
    }

    @Test("notification history strips a past approval payload")
    func notificationHistoryIsPresentationOnly() {
        let alert = DevReadyAlert(title: "Ship", subtitle: "Done", kind: .waiting,
                                  requestId: "request-123", permissionPayload: "sensitive")
        let history = NotchState.historyEntry(for: alert)
        #expect(history.kind == .finished)
        #expect(history.requestId == nil)
        #expect(history.permissionPayload == nil)
    }

    @Test("Focus timer carries its focused presentation state")
    func focusTimerState() {
        let focus = ActiveTimer(label: "Focus", endDate: .now.addingTimeInterval(60))
        let regular = ActiveTimer(label: "Timer", endDate: .now.addingTimeInterval(60))
        #expect(focus.isFocusSession)
        #expect(!regular.isFocusSession)
    }

    @Test("a blocked agent becomes the focused item ahead of completions")
    func waitingWins() {
        let finished = DevReadyAlert(title: "build", kind: .finished, createdAt: 20)
        let waiting = DevReadyAlert(title: "approval", kind: .waiting, createdAt: 10)
        #expect(DevReadyAlert.focusOrdered([finished, waiting]).first?.id == waiting.id)
    }

    @Test("the newest completion leads when nothing needs attention")
    func newestFinishedWins() {
        let older = DevReadyAlert(title: "older", kind: .finished, createdAt: 10)
        let newer = DevReadyAlert(title: "newer", kind: .finished, createdAt: 20)
        #expect(DevReadyAlert.focusOrdered([older, newer]).first?.id == newer.id)
    }
}

@Suite("Media swipe controls")
struct MediaSwipeTests {
    @Test("horizontal swipes select the matching transport action")
    func horizontalDirections() {
        #expect(MediaSwipeDirection.from(translation: CGSize(width: -48, height: 3)) == .next)
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 48, height: 3)) == .previous)
    }

    @Test("short and vertical drags do not change playback")
    func ignoresAmbiguousDrags() {
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 20, height: 0)) == nil)
        #expect(MediaSwipeDirection.from(translation: CGSize(width: 42, height: 72)) == nil)
    }
}

@Suite("Live agent sessions")
struct AgentSessionTests {
    private func session(_ id: String, _ state: AgentSession.State,
                         at: Date, agent: String = "claude-code") -> AgentSession {
        AgentSession(id: id, agent: agent, project: id, state: state, lastActivity: at)
    }

    @Test("a transcript written seconds ago is working, not idle")
    func recentIsWorking() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-2),
                                   blocked: false, now: now) == .working)
    }

    // An agent thinking between two tool calls writes nothing for a few
    // seconds. Flickering working→idle→working reads as a bug.
    @Test("a short pause mid-turn stays working")
    func shortPauseStaysWorking() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-7),
                                   blocked: false, now: now) == .working)
    }

    @Test("a long pause becomes idle, dated from the last write")
    func longPauseIsIdle() {
        let now = Date()
        let last = now.addingTimeInterval(-120)
        #expect(AgentSession.state(lastWrite: last, blocked: false, now: now) == .idle(since: last))
    }

    // Blocked beats everything: a session waiting on you has by definition not
    // written anything recently, so time alone would call it idle.
    @Test("blocked wins over quiet")
    func blockedWins() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now.addingTimeInterval(-600),
                                   blocked: true, now: now) == .waiting(since: nil))
    }

    @Test("waiting sessions float above newer working ones")
    func waitingSortsFirst() {
        let now = Date()
        let ordered = AgentSession.ordered([
            session("fresh", .working, at: now),
            session("blocked", .waiting(since: nil), at: now.addingTimeInterval(-300)),
            session("old", .idle(since: now.addingTimeInterval(-600)),
                    at: now.addingTimeInterval(-600))
        ])
        #expect(ordered.map(\.id) == ["blocked", "fresh", "old"])
    }

    @Test("the card keeps completed turns without calling them live")
    func completedTurnsAreShownAsCompleted() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "done")
        let rows = AgentSession.displaySessions(
            live: [session("working", .working, at: now)], waitingAlerts: [],
            completedAlerts: [completed])
        #expect(rows.map(\.id) == ["working", "done"])
        #expect(rows.last?.isCompleted == true)
        #expect(rows.last?.statusLabel.hasPrefix("completed") == true)
    }

    @Test("an unanswered prompt wins over a completed turn for the same session")
    func waitingPromptReplacesCompletedTurn() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "session")
        let waiting = DevReadyAlert(
            id: "question", title: "Release", subtitle: nil, source: "Codex",
            agent: "codex", bundleId: nil, kind: .waiting,
            message: "Ship it?", createdAt: now.timeIntervalSince1970,
            sessionId: "session")
        let rows = AgentSession.displaySessions(live: [], waitingAlerts: [waiting],
                                                completedAlerts: [completed])
        #expect(rows.count == 1)
        #expect(rows[0].isWaiting)
    }

    @Test("a newer live transcript beats an older completion")
    func resumedSessionBeatsOldCompletion() {
        let now = Date()
        let completed = DevReadyAlert(
            id: "done", title: "Release", subtitle: "finished", source: "Codex",
            agent: "codex", bundleId: nil, kind: .finished,
            createdAt: now.addingTimeInterval(-60).timeIntervalSince1970,
            sessionId: "session")
        let rows = AgentSession.displaySessions(
            live: [session("session", .working, at: now)], waitingAlerts: [],
            completedAlerts: [completed])
        #expect(rows.count == 1)
        #expect(rows[0].state == .working)
    }

    @Test("durations stay short enough for a notch row")
    func durationsAreCompact() {
        let now = Date()
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-45), now: now) == "45s")
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-240), now: now) == "4m")
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(-7200), now: now) == "2h")
        // A clock skew must not render "-3s".
        #expect(AgentSession.shortDuration(since: now.addingTimeInterval(3), now: now) == "0s")
    }

    @Test("the card is only offered when something is running")
    func emptyListShowsNoCard() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.isEmpty)
    }

    @Test("live agents lead the card row")
    func agentsComeFirst() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: "Xcode",
            systemVolume: 40, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session("a", .working, at: Date())],
            showMedia: false, showActiveApp: true, showVolume: true, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        // Asked of `kind`, as the sibling ordering tests do. This used to read
        // the id's prefix, which only worked while the id carried the session
        // list — content the id deliberately no longer encodes.
        #expect(items.first?.kind == "agents")
    }

    @Test("OpenCode usage keeps its page beside live agents")
    func openCodeUsageFollowsAgents() {
        let usage = OpenCodeUsage(inputTokens: 900, outputTokens: 100, reasoningTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session("a", .working, at: Date())], openCodeUsage: usage,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["agents", "openCodeUsage"])
    }

    @Test("OpenCode usage keeps its page when it is the content")
    func openCodeUsageWithoutAgents() {
        let usage = OpenCodeUsage(inputTokens: 900, outputTokens: 100, reasoningTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [], openCodeUsage: usage,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["openCodeUsage"])
    }

    @Test("the toggle actually suppresses the card")
    func toggleOffHidesCard() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session("a", .working, at: Date())],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: false)
        #expect(items.isEmpty)
    }
}

@Suite("Notch size preference")
struct NotchScaleTests {
    @Test("out-of-range values are clamped, not honoured")
    func clamps() {
        // A hand-edited plist must not be able to produce a pill that is
        // invisible or wider than the display.
        #expect(AppSettings.clampNotchScale(0.1) == AppSettings.notchScaleRange.lowerBound)
        #expect(AppSettings.clampNotchScale(9.0) == AppSettings.notchScaleRange.upperBound)
        #expect(AppSettings.clampNotchScale(1.0) == 1.0)
    }

    @Test("a corrupt value falls back to the default")
    func nonFiniteIsSafe() {
        // `defaults.double(forKey:)` returns 0 for a missing or non-numeric key,
        // and NaN survives a plist round trip — both would otherwise collapse
        // the pill to nothing.
        #expect(AppSettings.clampNotchScale(.nan) == 1.0)
        #expect(AppSettings.clampNotchScale(0) == AppSettings.notchScaleRange.lowerBound)
    }
}

@Suite("Shrinking adapts content, not just size")
struct NotchScaleAdaptationTests {
    // Shrinking the pill shrinks type with it, which makes text the first thing
    // to stop being readable. Compensation gives most of it back.
    @Test("smaller pill keeps type readable")
    func typeResistsShrinking() {
        let small = NotchContentLayout.textCompensation(forUserScale: 0.7)
        let mid = NotchContentLayout.textCompensation(forUserScale: 0.85)
        #expect(small > mid)
        #expect(small > 1.15)
        #expect(0.7 * small < 1.0)
    }

    @Test("enlarging is left alone")
    func growingIsUncompensated() {
        #expect(NotchContentLayout.textCompensation(forUserScale: 1.0) == 1)
        #expect(NotchContentLayout.textCompensation(forUserScale: 1.3) == 1)
    }

    @Test("a corrupt scale cannot produce a divide-by-zero")
    func zeroScaleIsSafe() {
        #expect(NotchContentLayout.textCompensation(forUserScale: 0) == 1)
        #expect(NotchContentLayout.textCompensation(forUserScale: -1) == 1)
    }

    /// Every card gets the same fixed canvas, so page changes and a larger
    /// deck never resize the expanded notch or shrink card text.
    @Test("all cards share the same fixed expanded canvas")
    func deckSizeIsIndependentOfCardCount() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 1.0)
        let one = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: [.clock])
        let all = NotchContentLayout.expandedDeckLayout(
            metrics: metrics,
            activities: Array(repeating: ExpandedActivity.clock,
                              count: ExpandedActivity.allKinds.count))
        #expect(one.size == all.size)
        #expect(one.readability == all.readability)
        #expect(one.textScale == all.textScale)
    }
}

@Suite("Agent names and task text")
struct AgentTaskTests {
    private func s(_ agent: String) -> AgentSession {
        AgentSession(id: "x", agent: agent, project: "p", state: .working, lastActivity: Date())
    }

    // "claude-code" is a wire identifier, not a label.
    @Test("wire ids become readable names")
    func names() {
        #expect(s("claude-code").agentName == "Claude")
        #expect(s("codex").agentName == "Codex")
        #expect(s("cursor").agentName == "Cursor")
        #expect(s("some-new-tool").agentName == "some-new-tool")
        #expect(s("").agentName == "Agent")
    }

    @Test("Sessions list uses Fetch-style activity copy")
    func glanceActivity() {
        var waiting = s("claude-code")
        waiting.state = .waiting(since: Date())
        #expect(waiting.glanceActivityLabel == "Waiting for you")
        #expect(waiting.sessionsGroupTitle == "CLAUDE CODE")

        var working = s("codex")
        working.state = .working
        working.task = "Wire the overlay"
        #expect(working.glanceActivityLabel == "Wire the overlay")
        #expect(working.sessionsGroupTitle == "CODEX")
        working.startedAt = Date().addingTimeInterval(-367)
        #expect(working.glanceElapsedLabel == "6:07")
    }

    @Test("a short prompt is shown whole")
    func shortPromptKept() {
        #expect(AgentSession.summarize("fix the login bug") == "fix the login bug")
    }

    // Claude Code brackets pasted text and command output; without stripping,
    // rows would read "<command-name> …" instead of the actual request.
    @Test("wrapper tags are stripped")
    func tagsStripped() {
        #expect(AgentSession.summarize("<command-name>/compact</command-name> tidy up") == "tidy up")
        #expect(AgentSession.summarize("line one\nline two") == "line one line two")
    }

    @Test("long prompts truncate on a word boundary")
    func truncatesCleanly() {
        let long = "please refactor the authentication module and split it into smaller files"
        let out = AgentSession.summarize(long)!
        #expect(out.count <= 53)
        #expect(out.hasSuffix("…"))
        #expect(!out.contains("  "))
        // Never ends mid-word before the ellipsis.
        #expect(!out.dropLast().hasSuffix("refacto"))
    }

    @Test("nothing to show stays nil rather than becoming an empty row")
    func emptyIsNil() {
        #expect(AgentSession.summarize(nil) == nil)
        #expect(AgentSession.summarize("") == nil)
        #expect(AgentSession.summarize("   \n  ") == nil)
        #expect(AgentSession.summarize("<only><tags/></only>") == nil)
    }
}

@Suite("Sub-agent naming and session location")
struct AgentIdentityTests {
    private func session(subagent: String?) -> AgentSession {
        AgentSession(id: "x", agent: "claude-code", project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("a running sub-agent names the row")
    func subagentWins() {
        #expect(session(subagent: "code-reviewer").displayName == "Code Reviewer")
        #expect(session(subagent: "gsd-doc-writer").displayName == "Gsd Doc Writer")
        #expect(session(subagent: nil).displayName == "Claude")
        #expect(session(subagent: "").displayName == "Claude")
    }

    private func line(_ json: String) -> String { json }

    // A sub-agent is only "running" until its result comes back. Without the
    // pairing, a row would name a reviewer that finished twenty minutes ago.
    @Test("the parent's description separates same-type sub-agents")
    func descriptionDistinguishesRuns() {
        let parent = [
            #"{"message":{"content":[{"type":"tool_use","id":"t1","name":"Agent","input":{"subagent_type":"Explore","description":"Explore notch view layer"}}]}}"#,
            #"{"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"agentId: aaa111"}]}}"#,
            #"{"message":{"content":[{"type":"tool_use","id":"t2","name":"Agent","input":{"subagent_type":"Explore","description":"Explore hover and window code"}}]}}"#,
            #"{"message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"agentId: bbb222"}]}}"#
        ].joined(separator: "\n")
        let first = AgentSessionScanner.subagentInfo(inParent: parent, agentId: "aaa111")
        let second = AgentSessionScanner.subagentInfo(inParent: parent, agentId: "bbb222")
        #expect(first?.type == "Explore")
        #expect(second?.type == "Explore")
        #expect(first?.task == "Explore notch view layer")
        #expect(second?.task == "Explore hover and window code")
        #expect(first?.task != second?.task)
    }

    @Test("noise never yields a name")
    func noiseIsSafe() {
        #expect(AgentSessionScanner.subagentInfo(inParent: "", agentId: "a") == nil)
        #expect(AgentSessionScanner.subagentInfo(inParent: "not json", agentId: "a") == nil)
        #expect(AgentSessionScanner.subagentInfo(
            inParent: #"{"message":{"content":[]}}"#, agentId: "a") == nil)
    }

    // MARK: - Locating the hosting app

    private static let table = """
    2186   685 /Users/me/.local/bin/claude --session-id ABC123 --settings {}
     685   681 /bin/zsh -lic something
     681   680 -/bin/zsh /var/folders/x/cmux-surface-resume/claude-F331
     680   504 /usr/bin/login -flp me /bin/bash
     504     1 /Applications/cmux.app/Contents/MacOS/cmux
    """

    @Test("the hosting app is found by walking parents")
    func walksToApp() {
        let entries = AgentSessionLocator.parse(Self.table)
        #expect(entries.count == 5)
        #expect(AgentSessionLocator.appBundlePath(in: entries.last!.args) == "/Applications/cmux.app")
    }

    @Test("a cycle or a rootless chain terminates")
    func malformedTreeTerminates() {
        // Two processes claiming each other as parent must not spin: this runs
        // on a tap, in front of the user.
        let cyclic = AgentSessionLocator.parse("""
        10 11 /bin/a
        11 10 /bin/b
        """)
        #expect(AgentSessionLocator.bundleId(walkingUpFrom: 10, in: cyclic) == nil)
        #expect(AgentSessionLocator.bundleId(walkingUpFrom: 999, in: cyclic) == nil)
    }

    @Test("a non-app process yields nothing rather than a guess")
    func noAppNoAnswer() {
        #expect(AgentSessionLocator.appBundlePath(in: "/usr/bin/login -flp me") == nil)
        #expect(AgentSessionLocator.appBundlePath(in: "") == nil)
    }
}

@Suite("Choosing the right process to focus")
struct LocatorChoiceTests {
    private let sid = "SESSION-42"

    // A grep, an editor with the transcript open, or a diagnostic all mention
    // the session id. Focusing whatever those descend from sends you somewhere
    // random, so the real agent binary has to win.
    @Test("the agent process beats a bystander that merely mentions the id")
    func prefersAgentProcess() {
        let table = AgentSessionLocator.parse("""
        900 901 /usr/bin/grep SESSION-42 /tmp/log
        901 902 /Applications/Notes.app/Contents/MacOS/Notes
        800 801 /Users/me/.local/bin/claude --session-id SESSION-42
        801 504 /bin/zsh -lic x
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table)
                == Bundle(path: "/Applications/cmux.app")?.bundleIdentifier)
    }

    // The agentish filter listed only claude and codex, and matched on a bare
    // substring. So an OpenCode session ranked its own binary no higher than a
    // `tail` on its transcript — and whichever `ps` happened to list first won.
    @Test("opencode's own process outranks a bystander holding its transcript")
    func prefersOpenCodeProcess() {
        let table = AgentSessionLocator.parse("""
        900 901 /usr/bin/tail -f /tmp/SESSION-42.jsonl
        901 902 /Applications/Notes.app/Contents/MacOS/Notes
        800 801 /Users/me/.local/bin/opencode --session SESSION-42
        801 504 /bin/zsh -lic x
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table)
                == Bundle(path: "/Applications/cmux.app")?.bundleIdentifier)
    }

    // Substring matching also counted a process whose *arguments* named the
    // binary. `codex` appearing in a path is not a codex process.
    @Test("a path merely containing an agent name is not an agent")
    func argumentMentionIsNotTheBinary() {
        let table = AgentSessionLocator.parse("""
        900 504 /usr/bin/vim /Users/me/codex/notes-SESSION-42.md
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        let ranked = AgentSessionLocator.candidates(forSessionId: sid, in: table)
        #expect(ranked.count == 1)
        #expect(!AgentSessionLocator.isProcess(ranked[0].args, named: "codex"))
    }

    @Test("a bystander is still used when it is the only match")
    func fallsBackToAnyMatch() {
        let table = AgentSessionLocator.parse("""
        900 504 /usr/bin/tail -f SESSION-42.jsonl
        504   1 /Applications/cmux.app/Contents/MacOS/cmux
        """)
        // Candidate ranking is pure; resolving the host bundle depends on the
        // referenced app being installed, which is not true on CI runners.
        let candidates = AgentSessionLocator.candidates(forSessionId: sid, in: table)
        #expect(candidates.map(\.pid) == [900])
    }

    @Test("no match yields nothing rather than an arbitrary app")
    func noMatchNoGuess() {
        let table = AgentSessionLocator.parse("504 1 /Applications/cmux.app/Contents/MacOS/cmux")
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: sid, in: table) == nil)
        #expect(AgentSessionLocator.hostingBundleId(forSessionId: "", in: table) == nil)
    }

    @Test("Terminal tab script targets only the session TTY")
    func terminalTabScriptUsesEscapedTTY() {
        let script = AgentSessionLocator.terminalFocusScript(tty: #"/dev/ttys\"012"#)
        // Raw string: `\"` is literal here, so the quotes around the value are
        // plain. Only the escaping *inside* it is the thing under test.
        #expect(script.contains(#"tty of terminalTab is "/dev/ttys\\\"012""#))
        #expect(script.contains("set selected tab of terminalWindow to terminalTab"))
    }

    // Reported: tapping a live-agent row did nothing. `focus` selects a tab
    // inside cmux and says nothing about which app is frontmost, so the script
    // matched, focused, returned true — and the caller, treating true as
    // success, returned before the activation fallback. cmux stayed behind
    // whatever you were looking at. Terminal and iTerm always activated first.
    @Test("the cmux script brings cmux to the front, not just the tab")
    func cmuxScriptActivates() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/Users/me/proj")
        #expect(script.contains("activate"))
        // Before the match loop: focusing a tab in a background app is the bug.
        let activate = script.range(of: "activate")
        let loop = script.range(of: "repeat with cmuxWindow")
        #expect(activate != nil && loop != nil)
        if let activate, let loop { #expect(activate.lowerBound < loop.lowerBound) }
    }

    @Test("cmux script matches on the working directory it was given")
    func cmuxScriptUsesDirectory() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/Users/me/proj")
        #expect(script.contains(#"working directory of cmuxTerminal is "/Users/me/proj""#))
        #expect(script.contains("focus (item 1 of matches)"))
    }

    /// Two tabs on one directory are indistinguishable, and focusing the wrong
    /// one is worse than focusing the app — so the script declines to choose.
    @Test("cmux script refuses to guess between duplicate matches")
    func cmuxScriptRefusesAmbiguity() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: "/tmp")
        #expect(script.contains("if (count of matches) is 1 then"))
        #expect(script.contains("return false"))
    }

    @Test("cmux script escapes a directory containing a quote")
    func cmuxScriptEscapesDirectory() {
        let script = AgentSessionLocator.cmuxFocusScript(directory: #"/tmp/a"b"#)
        #expect(script.contains(#"is "/tmp/a\"b""#))
    }

    @Test("iTerm script selects the exact split-pane session")
    func iTermSessionScriptUsesTTY() {
        let script = AgentSessionLocator.iTermFocusScript(tty: "/dev/ttys012")
        #expect(script.contains("tty of terminalSession is \"/dev/ttys012\""))
        #expect(script.contains("tell terminalWindow to select"))
        #expect(script.contains("tell terminalTab to select"))
        #expect(script.contains("tell terminalSession to select"))
    }
}

@Suite("Sub-agent path parsing")
struct SubagentPathTests {
    private let side = "/Users/me/.claude/projects/-Users-me-proj/SESSION/subagents/agent-abc123.jsonl"

    @Test("a sidechain reveals its agent and its parent session")
    func parsesSidechain() {
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: side)) == "abc123")
        #expect(AgentSessionScanner.parentSessionId(ofPath: side) == "SESSION")
    }

    // A normal session must not be mistaken for a sub-agent, or it would be
    // located via a parent that does not exist.
    @Test("a normal session is not a sidechain")
    func normalSessionIsNot() {
        let normal = "/Users/me/.claude/projects/-Users-me-proj/SESSION.jsonl"
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: normal)) == nil)
        #expect(AgentSessionScanner.parentSessionId(ofPath: normal) == nil)
    }

    @Test("a file in the right folder but the wrong shape is rejected")
    func wrongPrefixRejected() {
        let odd = "/Users/me/.claude/projects/p/S/subagents/notes.jsonl"
        #expect(AgentSessionScanner.subagentId(from: URL(fileURLWithPath: odd)) == nil)
    }
}

@Suite("cmux session index")
struct CmuxIndexTests {
    /// Shaped after the real file: title and tty sit on the panel, the agent's
    /// session id sits under `terminal.agent`.
    private let real = Data("""
    {"windows":[{"tabManager":{"workspaces":[{"panels":[
      {"id":"10F486A2","title":"⠐ finish-approvals-toggle","ttyName":"ttys000",
       "directory":"/Users/me","terminal":{"agent":{"kind":"claude","sessionId":"796e84e2"}}},
      {"id":"64FF7B2E","title":"✳ Improve NJIT room finder usability","ttyName":"ttys002",
       "directory":"/Users/me/Downloads","terminal":{"agent":{"sessionId":"3d9a4039"}}}
    ]}]}}]}
    """.utf8)

    @Test("a session resolves to its pane, name and directory")
    func parsesPanes() {
        let index = CmuxIndex.parse(real)
        let pane = index.pane(forSession: "796e84e2")
        #expect(pane?.panelId == "10F486A2")
        #expect(pane?.title == "finish-approvals-toggle")
        #expect(pane?.ttyName == "ttys000")
        #expect(index.pane(forSession: "3d9a4039")?.title == "Improve NJIT room finder usability")
    }

    // cmux prefixes the title with a spinner frame that changes while the agent
    // works. Keeping it would make the row's name flicker every tick.
    @Test("the status glyph is stripped, the words are kept")
    func stripsGlyph() {
        #expect(CmuxIndex.cleanTitle("✳ Improve things") == "Improve things")
        #expect(CmuxIndex.cleanTitle("⠐ finish-approvals-toggle") == "finish-approvals-toggle")
        #expect(CmuxIndex.cleanTitle("no glyph here") == "no glyph here")
        #expect(CmuxIndex.cleanTitle("✳   ") == nil)
        #expect(CmuxIndex.cleanTitle(nil) == nil)
    }

    // Another app's private state file. A shape we do not recognise must yield
    // nothing rather than a wrong pane — focusing the wrong terminal is worse
    // than focusing none.
    @Test("unknown or broken shapes yield nothing")
    func toleratesJunk() {
        #expect(CmuxIndex.parse(Data("not json".utf8)).isEmpty)
        #expect(CmuxIndex.parse(Data("{}".utf8)).isEmpty)
        #expect(CmuxIndex.parse(Data(#"{"windows":[{"tabManager":{"workspaces":[]}}]}"#.utf8)).isEmpty)
        // A pane with no agent is a plain shell, not a session.
        let shell = #"{"windows":[{"tabManager":{"workspaces":[{"panels":[{"id":"A","title":"zsh"}]}]}}]}"#
        #expect(CmuxIndex.parse(Data(shell.utf8)).isEmpty)
    }

    @Test("an unknown session has no pane")
    func unknownSession() {
        let index = CmuxIndex.parse(real)
        #expect(index.pane(forSession: "nope") == nil)
        #expect(index.pane(forSession: nil) == nil)
        #expect(index.pane(forSession: "") == nil)
    }
}

@Suite("Agent row naming")
struct AgentDisplayNameTests {
    private func session(
        agent: String = "claude-code",
        project: String = "NotchPill",
        subagent: String? = nil,
        task: String? = nil,
        title: String? = nil
    ) -> AgentSession {
        AgentSession(id: "s", agent: agent, project: project,
                     state: .working, lastActivity: Date(),
                     subagent: subagent, task: task, sessionTitle: title)
    }

    // The complaint: three sessions in one repo were three rows all reading
    // "Claude", separable only by a task line that is often missing.
    @Test("the terminal's name for the session beats the vendor")
    func titleBeatsVendor() {
        #expect(session().displayName == "Claude")
        #expect(session(title: "Improve room finder").displayName == "Improve room finder")
    }

    // "which agent is this?" means the persona doing the work.
    @Test("a running sub-agent is still the most specific answer")
    func subagentWins() {
        #expect(session(subagent: "code-reviewer", title: "Improve room finder")
            .displayName == "Code Reviewer")
    }

    @Test("an empty title is not a name")
    func emptyTitleIgnored() {
        #expect(session(title: "").displayName == "Claude")
    }

    /// Cursor names untitled composers after the session id. That is an
    /// identifier, not the work, and it used to be the whole tile.
    @Test("Cursor's attach-session title is not a name")
    func attachSessionRejected() {
        let junk = "Attach session 1e82e7"
        #expect(!AgentSession.isHumanTitle(junk))
        #expect(session(agent: "cursor", title: junk).displayName == "Cursor")
        #expect(session(agent: "cursor", task: "Wire the overlay", title: junk)
            .displayName == "Wire the overlay")
    }

    @Test("a hex session id is not a name")
    func hexIdRejected() {
        #expect(!AgentSession.isHumanTitle("1e82e7"))
        #expect(session(agent: "cursor", title: "session 1e82e7").displayName == "Cursor")
    }

    @Test("a UUID is not a name")
    func uuidRejected() {
        #expect(!AgentSession.isHumanTitle("550e8400-e29b-41d4-a716-446655440000"))
        #expect(session(title: "550e8400-e29b-41d4-a716-446655440000").displayName == "Claude")
    }

    @Test("a sub-agent still wins over a junk title")
    func subagentWinsOverJunk() {
        #expect(session(subagent: "code-reviewer", title: "Attach session 1e82e7")
            .displayName == "Code Reviewer")
    }

    /// `access` is six hex letters. Rejecting every hex-looking word would
    /// hide real titles.
    @Test("English that happens to look like hex is still a name")
    func hexLookingEnglishKept() {
        #expect(AgentSession.isHumanTitle("access control review"))
        #expect(session(title: "access control review").displayName
                == "access control review")
    }

    @Test("a conventional-commit title is still a name")
    func conventionalCommitKept() {
        #expect(session(title: "fix: handle empty shelf").displayName
                == "fix: handle empty shelf")
    }

    @Test("New Chat and Composer are host defaults, not names")
    func hostDefaultsRejected() {
        #expect(!AgentSession.isHumanTitle("New Chat"))
        #expect(!AgentSession.isHumanTitle("Composer"))
        #expect(session(agent: "cursor", title: "New Chat").displayName == "Cursor")
    }
}

@Suite("Finished peek wording")
struct FinishedSubtitleTests {
    private func identity(sidechain: Bool, type: String? = nil)
    -> AgentSessionScanner.SidechainIdentity {
        AgentSessionScanner.SidechainIdentity(isSidechain: sidechain, agentType: type)
    }

    @Test("the orchestrator finishing says only that")
    func orchestrator() {
        #expect(AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: false), branch: "main") == "finished · main")
    }

    // The bug: a sub-agent's transcript sits under the session's directory and
    // the walk is recursive, so four Explores fired four peeks that read
    // exactly like the turn being over.
    @Test("a named sub-agent says which one finished")
    func namedSubagent() {
        #expect(AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: true, type: "code-reviewer"),
            branch: "main") == "Code Reviewer finished · main")
    }

    @Test("an unnamed sub-agent still does not borrow the orchestrator's wording")
    func unnamedSubagent() {
        #expect(AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: true), branch: nil) == "subagent finished")
        #expect(AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: true, type: ""), branch: nil) == "subagent finished")
    }

    @Test("no branch, no separator left dangling")
    func branchless() {
        #expect(AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: false), branch: nil) == "finished")
    }

    // Whatever else changes, these two must never render the same string —
    // that identity is the entire point of the fix.
    @Test("the two can never be confused")
    func neverEqual() {
        let orchestrator = AgentTranscriptProvider.finishedSubtitle(
            identity: identity(sidechain: false), branch: "main")
        for type in ["general-purpose", "Explore", "code-reviewer", ""] {
            let sub = AgentTranscriptProvider.finishedSubtitle(
                identity: identity(sidechain: true, type: type), branch: "main")
            #expect(sub != orchestrator)
        }
    }
}

@Suite("Media track identity")
struct TrackKeyTests {
    private func song(_ title: String, _ artist: String, playing: Bool) -> NowPlaying {
        NowPlaying(title: title, artist: artist, isPlaying: playing)
    }

    // The bug this exists to prevent: the deck animated on the whole
    // `NowPlaying` value, so hitting pause reflowed the card exactly the way a
    // new track does — it read as a skip.
    @Test("pausing is not a track change")
    func pauseKeepsTheKey() {
        let playing = song("Friends", "Chase Atlantic", playing: true)
        let paused = song("Friends", "Chase Atlantic", playing: false)
        #expect(playing != paused)          // the value does change…
        #expect(playing.trackKey == paused.trackKey)  // …but the track does not
    }

    @Test("a different song is a different key")
    func differentSongDiffers() {
        #expect(song("A", "X", playing: true).trackKey != song("B", "X", playing: true).trackKey)
        #expect(song("A", "X", playing: true).trackKey != song("A", "Y", playing: true).trackKey)
    }

    // Two songs must not collide just because their title and artist can be
    // concatenated the same way — hence a separator no metadata contains.
    @Test("the title and artist boundary cannot be forged")
    func noBoundaryCollision() {
        #expect(song("A", "BC", playing: true).trackKey != song("AB", "C", playing: true).trackKey)
    }
}

@Suite("Sub-agent identity from the transcript")
struct SidechainIdentityTests {
    /// Shaped after a real sidechain record: the flag, the agent's own id, the
    /// *parent's* id under `sessionId`, and the agent kind on a later record.
    private let sidechain = """
    {"isSidechain":true,"agentId":"a085a38d","sessionId":"796e84e2","type":"user","cwd":"/p"}
    {"isSidechain":true,"attributionAgent":"code-reviewer","type":"assistant"}
    """

    @Test("a sidechain names its agent, its kind, and the session that owns it")
    func readsIdentity() {
        let id = AgentSessionScanner.sidechainIdentity(in: sidechain)
        #expect(id.isSidechain)
        #expect(id.agentId == "a085a38d")
        #expect(id.parentSessionId == "796e84e2")
        #expect(id.agentType == "code-reviewer")
    }

    // The whole point of reading the flag rather than the path: a top-level
    // session promoted to a sub-agent would be located through a parent that
    // does not exist, and one demoted the other way would be a ping claiming
    // to be the thing the user was waiting on.
    @Test("a top-level session is not a sidechain whatever else it carries")
    func topLevelIsNot() {
        let text = """
        {"isSidechain":false,"sessionId":"796e84e2","type":"user"}
        {"isSidechain":false,"type":"assistant"}
        """
        let id = AgentSessionScanner.sidechainIdentity(in: text)
        #expect(!id.isSidechain)
        #expect(id.agentId == nil)
    }

    @Test("the first flag wins, so a later record cannot flip it")
    func firstFlagWins() {
        let text = """
        {"isSidechain":true,"agentId":"aaa"}
        {"isSidechain":false}
        """
        #expect(AgentSessionScanner.sidechainIdentity(in: text).isSidechain)
    }

    // A transcript that says nothing must read as "not a sidechain" rather
    // than crash or guess — the path fallback covers that case.
    @Test("garbage and silence are answered with nothing, not a guess")
    func toleratesJunk() {
        #expect(AgentSessionScanner.sidechainIdentity(in: "") == AgentSessionScanner.SidechainIdentity())
        #expect(AgentSessionScanner.sidechainIdentity(in: "not json\n{oops") ==
                AgentSessionScanner.SidechainIdentity())
        // A record with no flag at all leaves the default in place.
        let partial = AgentSessionScanner.sidechainIdentity(in: #"{"sessionId":"S","type":"user"}"#)
        #expect(!partial.isSidechain)
        #expect(partial.parentSessionId == "S")
    }

    @Test("empty strings do not count as answers")
    func emptyValuesIgnored() {
        let id = AgentSessionScanner.sidechainIdentity(
            in: #"{"isSidechain":true,"agentId":"","attributionAgent":"","sessionId":""}"#)
        #expect(id.isSidechain)
        #expect(id.agentId == nil)
        #expect(id.agentType == nil)
        #expect(id.parentSessionId == nil)
    }
}

@Suite("Pill hit rule")
struct HitRuleTests {
    private let bounds = CGRect(x: 0, y: 0, width: 500, height: 200)
    private let notchW: CGFloat = 200
    private let notchH: CGFloat = 32
    private let expandedSize = CGSize(width: 400, height: 160)
    private let collapsedSize = CGSize(width: 200, height: 40)

    private func accepts(_ p: NSPoint, expanded: Bool = true) -> Bool {
        NotchContainerView.accepts(p, bounds: bounds,
                                   notchWidth: notchW, notchHeight: notchH,
                                   expanded: expanded,
                                   collapsedSize: collapsedSize,
                                   expandedSize: expandedSize)
    }

    @Test("clicks land on the pill body")
    func bodyAccepts() {
        #expect(accepts(NSPoint(x: 250, y: 80)))
    }

    // REGRESSION: the passthrough check grew the rects by 2pt while hitTest used
    // them exact, leaving a band around every edge where the window swallowed a
    // click and routed it nowhere. The peek's ✕ sits ~8pt from that edge, which
    // is exactly how it came to feel unreliable. Both callers now share this
    // rule, so the band can only come back if the slack itself is dropped.
    @Test("the slack band just outside the body is still clickable")
    func slackBandAccepts() {
        let bodyRight: CGFloat = 250 + 400 / 2      // 450
        #expect(accepts(NSPoint(x: bodyRight - 1, y: 80)))   // inside
        #expect(accepts(NSPoint(x: bodyRight + 1, y: 80)))   // within slack
    }

    @Test("well outside the pill is not clickable")
    func outsideRejected() {
        #expect(!accepts(NSPoint(x: 490, y: 80)))
        #expect(!accepts(NSPoint(x: 10, y: 80)))
    }

    // The strip beside the physical notch must stay with the browser, or
    // clicking a tab hits the overlay instead.
    @Test("tab ears beside the notch never accept")
    func tabEarsRejected() {
        let earY = bounds.height - notchH / 2
        #expect(!accepts(NSPoint(x: 20, y: earY)))
        #expect(!accepts(NSPoint(x: 480, y: earY)))
        // …but the notch column between them does.
        #expect(accepts(NSPoint(x: 250, y: earY)))
    }

    @Test("collapsed only accepts the collapsed pill")
    func collapsedRule() {
        #expect(accepts(NSPoint(x: 250, y: 190), expanded: false))
        #expect(!accepts(NSPoint(x: 250, y: 80), expanded: false))
    }

    // A rect list that disagrees with the accept rule is how the two paths
    // drifted apart the first time.
    @Test("every interactive rect's centre is accepted")
    func rectsAgreeWithRule() {
        let rects = NotchContainerView.interactiveRects(
            bounds: bounds, notchWidth: notchW, notchHeight: notchH,
            expanded: true, collapsedSize: collapsedSize, expandedSize: expandedSize)
        #expect(rects.count == 2)
        for rect in rects {
            #expect(accepts(NSPoint(x: rect.midX, y: rect.midY)))
        }
    }
}

@Suite("Media payload parsing")
struct MediaPayloadTests {
    // Micros must win over seconds. If the precedence flips, a 3-minute track
    // reports 180 million seconds and the scrubber is off by 10^6 — visible as
    // a progress bar that never moves.
    @Test("microsecond keys take precedence over second keys")
    func microsWin() {
        let payload: [String: Any] = ["durationMicros": NSNumber(value: 180_000_000),
                                      "duration": NSNumber(value: 999)]
        #expect(MediaRemoteBridge.parseDuration(payload) == 180)
    }

    @Test("seconds are used when micros are absent")
    func secondsFallback() {
        #expect(MediaRemoteBridge.parseDuration(["duration": NSNumber(value: 210)]) == 210)
        #expect(MediaRemoteBridge.parseDuration([:]) == nil)
    }

    // Four keys in a documented order; "now" variants are fresher than the
    // plain ones and must be preferred.
    @Test("elapsed prefers the freshest key available")
    func elapsedPrecedence() {
        let all: [String: Any] = [
            "elapsedTimeNowMicros": NSNumber(value: 30_000_000),
            "elapsedTimeMicros": NSNumber(value: 20_000_000),
            "elapsedTimeNow": NSNumber(value: 10),
            "elapsedTime": NSNumber(value: 5)
        ]
        #expect(MediaRemoteBridge.parseElapsed(all) == 30)
        var without = all; without["elapsedTimeNowMicros"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 20)
        without["elapsedTimeMicros"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 10)
        without["elapsedTimeNow"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == 5)
        without["elapsedTime"] = nil
        #expect(MediaRemoteBridge.parseElapsed(without) == nil)
    }

    @Test("timestamps convert from epoch micros")
    func timestampConversion() {
        let d = MediaRemoteBridge.parseTimestamp(["timestampEpochMicros": NSNumber(value: 1_700_000_000_000_000)])
        #expect(d?.timeIntervalSince1970 == 1_700_000_000)
        let plain = MediaRemoteBridge.parseTimestamp(["timestamp": NSNumber(value: 1_700_000_000)])
        #expect(plain?.timeIntervalSince1970 == 1_700_000_000)
    }

    @Test("wrong types are ignored rather than coerced")
    func wrongTypesIgnored() {
        // A string here would previously read as nil, not as a bogus number —
        // pin it, because `as? NSNumber` on a numeric string is a classic trap.
        #expect(MediaRemoteBridge.parseDuration(["duration": "210"]) == nil)
        #expect(MediaRemoteBridge.parseElapsed(["elapsedTime": NSNull()]) == nil)
    }
}

/// Characterization tests: these record what the resolver does *today*, so a
/// cleanup can be proven not to change behaviour.
@Suite("Now playing video titles")
struct VideoTitleTests {
    private func resolve(_ t: String, _ a: String, _ al: String) -> (title: String, artist: String)? {
        NowPlayingDisplayResolver.resolve(title: t, artist: a, album: al,
                                          mediaType: "video",
                                          bundleIdentifier: "com.apple.Safari")
    }

    // The case the dead branch was reaching for: a player putting a site domain
    // in the title and the real name in the artist. The title must not survive
    // as the artist line — showing "netflix.com" under the show is the bug.
    @Test("a domain title is replaced, not demoted to the artist line")
    func domainTitleReplaced() {
        let out = resolve("netflix.com", "Stranger Things", "")
        #expect(out?.title == "Stranger Things")
        #expect(out?.artist == "")
    }

    @Test("a real title is left alone")
    func realTitleKept() {
        let out = resolve("Chapter One", "Stranger Things", "")
        #expect(out?.title == "Chapter One")
        #expect(out?.artist == "Stranger Things")
    }

    @Test("the album supplies the show when the title is noise")
    func albumSuppliesShow() {
        let out = resolve("youtube.com", "", "Stranger Things, Season 1")
        #expect(out?.title == "Stranger Things")
    }

    @Test("nothing at all resolves to nothing")
    func emptyIsNil() {
        #expect(NowPlayingDisplayResolver.resolve(title: "", artist: "", album: "") == nil)
        #expect(NowPlayingDisplayResolver.resolve(title: nil, artist: nil, album: nil) == nil)
    }
}

@Suite("Hover forgiveness follows the size setting")
struct HoverPaddingTests {
    // A smaller pill is a smaller target. Leaving the slack at a flat 14/10pt
    // shrank the forgiveness twice over — smaller target, same absolute margin —
    // and the pointer slipped out while reaching for a control.
    @Test("shrinking the pill widens the slack")
    func smallerGetsMoreSlack() {
        let full = NotchController.hoverPadding(forUserScale: 1.0)
        let small = NotchController.hoverPadding(forUserScale: 0.75)
        #expect(small.x > full.x)
        #expect(small.y > full.y)
        #expect(small.collapsedX > full.collapsedX)
    }

    @Test("the default is unchanged")
    func defaultUnchanged() {
        let p = NotchController.hoverPadding(forUserScale: 1.0)
        #expect(p.x == 14)
        #expect(p.y == 10)
        #expect(p.collapsedX == 10)
        #expect(p.collapsedY == 6)
    }

    // Enlarging must not make hovering fussier than it is at 100%.
    @Test("growing never reduces the slack")
    func growingKeepsSlack() {
        let big = NotchController.hoverPadding(forUserScale: 1.3)
        #expect(big.x == 14)
        #expect(big.y == 10)
    }

    @Test("a corrupt scale cannot produce a runaway or zero zone")
    func corruptScaleClamped() {
        let zero = NotchController.hoverPadding(forUserScale: 0)
        #expect(zero.x == 28)          // clamped at 0.5, not divided by zero
        #expect(zero.x.isFinite)
        let negative = NotchController.hoverPadding(forUserScale: -5)
        #expect(negative.x == 28)
    }
}

@Suite("CI status")
struct CIStatusTests {
    // gh reports an in-flight run as queued/in_progress with an *empty*
    // conclusion. Reading the conclusion alone would paint every running build
    // as a failure — the loudest possible wrong answer.
    @Test("a running build is not a failure")
    func runningIsNotFailure() {
        #expect(CIRun.state(status: "in_progress", conclusion: "") == .running)
        #expect(CIRun.state(status: "queued", conclusion: "") == .running)
        #expect(CIRun.state(status: "completed", conclusion: "") == .running)
    }

    @Test("finished states map correctly")
    func finishedStates() {
        #expect(CIRun.state(status: "completed", conclusion: "success") == .passed)
        #expect(CIRun.state(status: "completed", conclusion: "failure") == .failed)
        #expect(CIRun.state(status: "completed", conclusion: "startup_failure") == .failed)
        #expect(CIRun.state(status: "completed", conclusion: "cancelled") == .other("cancelled"))
    }

    @Test("failures sort above everything, then running")
    func ordering() {
        let now = Date()
        func run(_ id: String, _ st: CIRun.State, _ age: TimeInterval) -> CIRun {
            CIRun(id: id, repo: "o/r", workflow: id, branch: "main",
                  state: st, started: now.addingTimeInterval(-age))
        }
        let ordered = CIRun.ordered([
            run("newest-pass", .passed, 10),
            run("running", .running, 300),
            run("failed", .failed, 900)
        ])
        #expect(ordered.map(\.id) == ["failed", "running", "newest-pass"])
    }

    @Test("both remote forms yield the repo slug")
    func slugParsing() {
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner/name.git") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner/name") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "git@github.com:owner/name.git") == "owner/name")
        #expect(CIRun.repoSlug(fromRemote: "  git@github.com:owner/name.git\n") == "owner/name")
    }

    // A non-GitHub remote has no runs to fetch, and guessing a slug would send
    // `gh` after a repo that does not exist.
    @Test("non-GitHub remotes are declined")
    func nonGitHubDeclined() {
        #expect(CIRun.repoSlug(fromRemote: "git@gitlab.com:owner/name.git") == nil)
        #expect(CIRun.repoSlug(fromRemote: "/local/path/repo") == nil)
        #expect(CIRun.repoSlug(fromRemote: "") == nil)
        #expect(CIRun.repoSlug(fromRemote: "https://github.com/owner") == nil)
    }
}

@Suite("CI repo memory")
struct CIRepoMemoryTests {
    // A release is tagged and then walked away from: the agent session ends in
    // seconds, the build takes minutes. Tying the card to the session made CI
    // disappear exactly when it mattered.
    @Test("a repo outlives the session that introduced it")
    func repoIsRemembered() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("owner/repo", at: now)
        #expect(await p.repos(at: now.addingTimeInterval(1800)) == ["owner/repo"])
    }

    @Test("but not forever")
    func repoExpires() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("owner/repo", at: now)
        #expect(await p.repos(at: now.addingTimeInterval(7200)).isEmpty)
    }

    @Test("the most recent repo wins the budget")
    func newestFirst() async {
        let p = CIStatusProvider()
        let now = Date()
        await p.remember("old/one", at: now.addingTimeInterval(-600))
        await p.remember("new/two", at: now)
        #expect(await p.repos(at: now).first == "new/two")
    }
}

// MARK: - Onboarding

@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test("walks forward and stops at the end")
    func walksForward() {
        var flow = OnboardingFlow()
        #expect(flow.current == .welcome)
        #expect(flow.isFirst)
        for _ in 0..<20 { flow.next() }
        #expect(flow.current == .finish)
        #expect(flow.isLast)
    }

    @Test("walks back and stops at the start")
    func walksBack() {
        var flow = OnboardingFlow()
        flow.next()
        #expect(flow.current == .accessibility)
        for _ in 0..<20 { flow.back() }
        #expect(flow.current == .welcome)
    }

    // Dividing by steps.count - 1 is one off-by-one away from dividing by zero,
    // and a one-step flow is exactly what an all-satisfied guide would be.
    @Test("a single-step flow has finite progress")
    func singleStep() {
        let flow = OnboardingFlow(steps: [.finish])
        #expect(flow.progress == 0)
        #expect(flow.isFirst && flow.isLast)
    }

    @Test("an empty flow still has a step to show")
    func emptyFlow() {
        let flow = OnboardingFlow(steps: [])
        #expect(flow.current == .finish)
    }

    @Test("progress ends at 1")
    func progressCompletes() {
        var flow = OnboardingFlow()
        while !flow.isLast { flow.next() }
        #expect(flow.progress == 1)
    }

    @Test("every step says something")
    func everyStepHasCopy() {
        for step in OnboardingStep.allCases {
            #expect(!step.title.isEmpty)
            #expect(step.detail.count > 20)
        }
    }
}

@Suite("Onboarding gating")
struct OnboardingGateTests {
    @Test("a fresh install sees the guide")
    func freshInstall() {
        #expect(Onboarding.shouldShow(completedVersion: 0))
    }

    @Test("a completed install does not")
    func alreadyDone() {
        #expect(!Onboarding.shouldShow(completedVersion: Onboarding.currentVersion))
    }
}

@Suite("Agent hook detection")
struct AgentHookDetectionTests {
    // Detection must agree with the installer's own --status, which greps
    // case-insensitively for the same word.
    @Test("finds the marker whatever the case")
    func findsMarker() {
        #expect(AgentHooks.isInstalled(inConfig: #"{"command": "notchpill-agent-question.sh"}"#))
        #expect(AgentHooks.isInstalled(inConfig: "command = \"/x/NotchPill/hook.sh\""))
    }

    @Test("an unrelated config is not wired up")
    func noMarker() {
        #expect(!AgentHooks.isInstalled(inConfig: #"{"hooks": {"Stop": []}}"#))
        #expect(!AgentHooks.isInstalled(inConfig: ""))
    }

    @Test("ANSI colouring is stripped from the transcript")
    func stripsAnsi() {
        #expect(AgentHooks.cleanOutput("\u{1B}[32m✓\u{1B}[0m Claude Code — wired up\n")
                == "✓ Claude Code — wired up")
    }
}

// MARK: - Shortcut arming

@Suite("Shortcut arming")
struct ShortcutArmingTests {
    // `#expect` captures its operand immutably, so each step is taken first.
    private func step(_ arming: inout ShortcutArming, _ x: CGFloat, _ y: CGFloat,
                      inZone: Bool) -> Bool {
        arming.update(point: CGPoint(x: x, y: y), inZone: inZone)
    }

    // The bug: a peek arrives, the pill's hot zone grows over a parked cursor,
    // and the next Space is eaten and sent to the browser as play/pause — in
    // the middle of someone typing.
    @Test("a zone that grows under a still pointer does not arm")
    func zoneGrowsUnderStillPointer() {
        var a = ShortcutArming()
        #expect(step(&a, 700, 900, inZone: false) == false)
        // The peek lands; same cursor, now inside the zone.
        #expect(step(&a, 700, 900, inZone: true) == false)
        #expect(step(&a, 700, 900, inZone: true) == false)
    }

    @Test("moving into the zone arms immediately")
    func movingInArms() {
        var a = ShortcutArming()
        #expect(step(&a, 700, 400, inZone: false) == false)
        #expect(step(&a, 700, 900, inZone: true) == true)
    }

    // Once armed, holding the mouse perfectly still must not disarm — that is
    // exactly what watching a video with the pointer on the pill looks like.
    @Test("staying still while armed keeps the shortcuts")
    func staysArmed() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 900, inZone: true) == true)
    }

    @Test("leaving the zone disarms")
    func leavingDisarms() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        #expect(step(&a, 700, 300, inZone: false) == false)
        // And a re-entry under a still pointer stays disarmed.
        #expect(step(&a, 700, 300, inZone: true) == false)
    }

    @Test("explicit disarm forgets the movement history")
    func explicitDisarm() {
        var a = ShortcutArming()
        _ = step(&a, 700, 400, inZone: false)
        #expect(step(&a, 700, 900, inZone: true) == true)
        a.disarm()
        #expect(a.isArmed == false)
        // No prior point, so the first sample after a disarm cannot re-arm.
        #expect(step(&a, 700, 900, inZone: true) == false)
    }

    @Test("wiggling inside the zone re-arms after a disarm")
    func rearmsOnMovement() {
        var a = ShortcutArming()
        a.disarm()
        #expect(step(&a, 700, 900, inZone: true) == false)
        #expect(step(&a, 702, 900, inZone: true) == true)
    }
}

// MARK: - Log store

@Suite("Log ring buffer")
struct LogStoreTests {
    private func entries(_ n: Int) -> [LogEntry] {
        (0..<n).map { LogEntry(id: UInt64($0), date: Date(), level: .info,
                               category: "test", message: "m\($0)") }
    }

    @Test("under capacity, nothing is dropped")
    func keepsEverything() {
        let kept = LogStore.trim(entries(10), to: 600)
        #expect(kept.count == 10)
    }

    // The oldest lines go, not the newest — the tail is what you were doing
    // when the thing you are chasing happened.
    @Test("over capacity, the oldest go first")
    func dropsOldest() {
        let kept = LogStore.trim(entries(700), to: 600)
        #expect(kept.count == 600)
        #expect(kept.first?.message == "m100")
        #expect(kept.last?.message == "m699")
    }

    @Test("a zero capacity keeps nothing rather than crashing")
    func zeroCapacity() {
        #expect(LogStore.trim(entries(5), to: 0).isEmpty)
    }

    @Test("a line carries its level, category and message")
    func lineFormat() {
        let e = LogEntry(id: 1, date: Date(timeIntervalSince1970: 0), level: .error,
                         category: "peek", message: "boom")
        let line = e.line(formatter: LogStore.lineFormatter)
        #expect(line.contains("[peek]"))
        #expect(line.contains("boom"))
        #expect(line.contains(LogEntry.Level.error.symbol))
    }
}

@Suite("Diagnostics report")
struct DiagnosticsReportTests {
    private var facts: DiagnosticsReport.Facts {
        .init(appVersion: "1.13.0", systemVersion: "Version 26.0",
              accessibilityGranted: true, hooksInstalled: false, ghAvailable: true,
              enabledCards: ["agents", "ci"], notchScale: 0.9,
              logLines: "12:00:00.000 · [app] launched",
              home: "/Users/someone")
    }

    // The whole point is that it can be pasted into a public issue without
    // thinking about it, and the account name is the thing that would leak.
    @Test("home paths are collapsed to ~")
    func redactsHome() {
        let text = DiagnosticsReport.redact(
            "hook at /Users/someone/.claude/settings.json", home: "/Users/someone")
        #expect(text == "hook at ~/.claude/settings.json")
        #expect(!text.contains("someone"))
    }

    @Test("a report redacts the log it carries too")
    func redactsInsideLog() {
        var f = facts
        f.logLines = "· [hooks] wrote /Users/someone/.codex/config.toml"
        let report = DiagnosticsReport.build(f)
        #expect(!report.contains("/Users/someone"))
        #expect(report.contains("~/.codex/config.toml"))
    }

    @Test("an empty or root home is left alone")
    func degenerateHome() {
        #expect(DiagnosticsReport.redact("/a/b", home: "") == "/a/b")
        #expect(DiagnosticsReport.redact("/a/b", home: "/") == "/a/b")
    }

    // Every field here has explained a real bug report at least once.
    @Test("the report states the facts that decide most problems")
    func statesTheFacts() {
        let report = DiagnosticsReport.build(facts)
        #expect(report.contains("1.13.0"))
        #expect(report.contains("granted"))
        #expect(report.contains("not installed"))
        #expect(report.contains("agents, ci"))
        #expect(report.contains("90%"))
    }

    @Test("an empty log says so rather than trailing off")
    func emptyLog() {
        var f = facts
        f.logLines = ""
        #expect(DiagnosticsReport.build(f).contains("(empty"))
    }
}

// MARK: - Expanded pill height

// MARK: - Agent liveness windows

@Suite("Agent state windows")
struct AgentStateWindowTests {
    // Reported: four agents running, one row, and it said idle. Both halves of
    // that were the thresholds, not the detection.
    @Test("an agent mid tool call is still working, not idle")
    func longToolCallStaysWorking() {
        let now = Date()
        // A build, a test run, a slow search — nothing is written meanwhile.
        let state = AgentSession.state(lastWrite: now.addingTimeInterval(-30),
                                       blocked: false, now: now)
        #expect(state == .working)
    }

    @Test("but a genuinely quiet session does go idle")
    func quietGoesIdle() {
        let now = Date()
        let state = AgentSession.state(lastWrite: now.addingTimeInterval(-300),
                                       blocked: false, now: now)
        if case .idle = state {} else { Issue.record("expected idle, got \(state)") }
    }

    @Test("blocked still beats both")
    func blockedWins() {
        let now = Date()
        #expect(AgentSession.state(lastWrite: now, blocked: true, now: now) == .waiting(since: nil))
    }

    // A session that has gone quiet for an hour is still one you are "in" —
    // dropping it made a running agent vanish from the card entirely.
    @Test("an hour of quiet still counts as live")
    func quietHourIsStillLive() {
        #expect(AgentSession.liveWindow > 3600)
    }

    @Test("the working window is shorter than the live window")
    func windowsAreOrdered() {
        #expect(AgentSession.workingWindow < AgentSession.liveWindow)
    }
}

// MARK: - CI run lifetime

@Suite("CI run lifetime")
struct CIRunLifetimeTests {
    private func run(_ state: CIRun.State, ageMinutes: Double, now: Date) -> CIRun {
        CIRun(id: "r\(ageMinutes)\(state)", repo: "o/r", workflow: "Release", branch: "main",
              state: state, started: now.addingTimeInterval(-ageMinutes * 60))
    }

    // Reported: the same three "Release — passed" rows sitting there forever.
    // `gh run list` has no notion of age, so a repo built once kept showing
    // last week's green ticks every time an agent opened in it.
    @Test("a pass stops being news")
    func passedAgesOut() {
        let now = Date()
        let fresh = run(.passed, ageMinutes: 0.5, now: now)
        let stale = run(.passed, ageMinutes: 10, now: now)
        let kept = CIRun.current([fresh, stale], now: now)
        #expect(kept.map(\.id) == [fresh.id])
    }

    // The one you have not dealt with yet is worth keeping around.
    @Test("a failure sticks around far longer than a pass")
    func failureOutlivesPass() {
        #expect(CIRun.failedLifetime > CIRun.passedLifetime)
        let now = Date()
        let failed = run(.failed, ageMinutes: 90, now: now)
        #expect(CIRun.current([failed], now: now).count == 1)
    }

    @Test("but not forever")
    func failureAlsoAgesOut() {
        let now = Date()
        #expect(CIRun.current([run(.failed, ageMinutes: 600, now: now)], now: now).isEmpty)
    }

    // A build going for two hours is exactly the one you want on screen.
    @Test("a long-running build is never aged out")
    func runningAlwaysStays() {
        let now = Date()
        let old = run(.running, ageMinutes: 240, now: now)
        #expect(CIRun.current([old], now: now).map(\.id) == [old.id])
    }

    @Test("cancelled and skipped age out like a pass")
    func otherAgesOut() {
        let now = Date()
        #expect(CIRun.current([run(.other("cancelled"), ageMinutes: 10, now: now)],
                              now: now).isEmpty)
    }

    // Everything aging out has to reach the card as an empty list, so the
    // card can take itself off the row instead of showing a stale header.
    @Test("an all-stale repo yields nothing at all")
    func emptiesCompletely() {
        let now = Date()
        let stale = [run(.passed, ageMinutes: 20, now: now),
                     run(.passed, ageMinutes: 30, now: now)]
        #expect(CIRun.current(stale, now: now).isEmpty)
    }
}

// MARK: - Peek hit testing

@Suite("Peek ✕ hit testing")
struct PeekDismissHitTests {
    // Geometry of a real peek: much wider than the notch, with its ✕ ~20pt in
    // from the trailing edge.
    private let bounds = CGRect(x: 0, y: 0, width: 720, height: 200)
    private let collapsed = CGSize(width: 240, height: 92)
    private let peek = CGSize(width: 420, height: 110)
    private let notchW: CGFloat = 200
    private let notchH: CGFloat = 32

    /// Where the ✕ actually sits: inside the peek, well outside the collapsed pill.
    private var dismissPoint: CGPoint {
        CGPoint(x: bounds.midX + peek.width / 2 - 20, y: bounds.maxY - 60)
    }

    private func accepts(expanded: Bool) -> Bool {
        NotchContainerView.accepts(dismissPoint,
                                   bounds: bounds,
                                   notchWidth: notchW, notchHeight: notchH,
                                   expanded: expanded,
                                   collapsedSize: collapsed,
                                   expandedSize: peek)
    }

    // The bug: a peek never sets `isExpanded`, so this rule was asked with
    // `expanded: false` while a peek was on screen. It then measured the ✕
    // against the *collapsed* pill, found it outside, and returned nil from
    // hitTest — dropping the click onto whatever was behind the notch.
    @Test("the ✕ is outside the collapsed pill")
    func outsideCollapsed() {
        #expect(accepts(expanded: false) == false)
    }

    @Test("but inside the pill a peek actually draws")
    func insidePeek() {
        #expect(accepts(expanded: true) == true)
    }

    // Which is why the controller must report "rendering large content" rather
    // than "expanded" — the two are not the same thing for a peek.
    @Test("the two answers genuinely differ, so the flag matters")
    func flagDecidesIt() {
        #expect(accepts(expanded: true) != accepts(expanded: false))
    }
}

// MARK: - Notch detection

// The reported bug: on a Mac with no cutout the pill was a flat-topped black
// slab hanging under the menu bar. `NotchShape` draws square top corners flush
// to the top edge, which is right on notched hardware — they sit inside the
// physical notch — and wrong everywhere else, where they meet open wallpaper.
@Suite("Pill silhouette without a notch")
struct FloatingPillShapeTests {
    private let box = CGRect(x: 0, y: 0, width: 300, height: 120)

    /// Whether the path covers a point, used to ask about the corners.
    private func covers(_ shape: NotchShape, _ point: CGPoint) -> Bool {
        shape.path(in: box).contains(point)
    }

    @Test("on notched hardware the top corners stay square")
    func notchedKeepsSquareTop() {
        let shape = NotchShape(bottomRadius: 22)
        // A point 2pt in from the very top-left corner.
        #expect(covers(shape, CGPoint(x: 2, y: 2)))
        #expect(covers(shape, CGPoint(x: box.maxX - 2, y: 2)))
    }

    @Test("without a notch the top corners are rounded away")
    func floatingRoundsTop() {
        let shape = NotchShape(bottomRadius: 22, topRadius: 22)
        // The same corner points now fall outside the rounded silhouette —
        // this is the difference between "attached" and "slab".
        #expect(!covers(shape, CGPoint(x: 2, y: 2)))
        #expect(!covers(shape, CGPoint(x: box.maxX - 2, y: 2)))
        // The body is still solid.
        #expect(covers(shape, CGPoint(x: box.midX, y: box.midY)))
        #expect(covers(shape, CGPoint(x: box.midX, y: 2)))
    }

    // Both kinds of display round the bottom; only the top differs.
    @Test("the bottom is rounded either way")
    func bottomUnchanged() {
        for top in [CGFloat(0), 22] {
            let shape = NotchShape(bottomRadius: 22, topRadius: top)
            #expect(!covers(shape, CGPoint(x: 2, y: box.maxY - 2)))
        }
    }
}

@Suite("Notch detection")
struct NotchRectTests {
    // A 14" MacBook Pro in points.
    private let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let safeTop: CGFloat = 37

    private func rect(left: CGRect?, right: CGRect?) -> CGRect? {
        NotchGeometry.notchRect(inFrame: frame, safeTop: safeTop, left: left, right: right)
    }

    private func source(left: CGRect?, right: CGRect?) -> NotchGeometry.Source? {
        NotchGeometry.resolveNotch(inFrame: frame, safeTop: safeTop,
                                   left: left, right: right)?.source
    }

    // On a 14" Pro the guess and the measurement are both 200pt wide, so every
    // assertion in this suite passed either way and nothing distinguished "read
    // the display" from "could not read the display". That is what made a
    // report of the pill hanging detached from the notch impossible to check:
    // the fallback is silent, and on a Mac whose notch is not 200pt it is also
    // wrong.
    @Test("a real reading is reported as measured")
    func measuredIsLabelled() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 856, y: 945, width: 656, height: 37)
        #expect(source(left: left, right: right) == .measured)
    }

    @Test("every rejected reading is reported as assumed")
    func fallbacksAreLabelled() {
        // Degenerate, off-centre, absurdly wide, and absent — the four ways the
        // rule declines. All of them are guesses and must say so.
        #expect(source(left: CGRect(x: 0, y: 945, width: 656, height: 37),
                       right: CGRect(x: 1512, y: 945, width: 0, height: 0)) == .assumed)
        #expect(source(left: CGRect(x: 0, y: 945, width: 1100, height: 37),
                       right: CGRect(x: 1350, y: 945, width: 162, height: 37)) == .assumed)
        #expect(source(left: CGRect(x: 0, y: 945, width: 200, height: 37),
                       right: CGRect(x: 1312, y: 945, width: 200, height: 37)) == .assumed)
        #expect(source(left: nil, right: nil) == .assumed)
    }

    // A narrower notch than the guess is the case that shows: the pill's neck
    // is built from this width, so a 200pt guess on a 160pt notch paints black
    // proud of the cutout on both sides.
    @Test("a narrower real notch is measured, not rounded up to the guess")
    func narrowNotchIsMeasured() {
        let left = CGRect(x: 0, y: 945, width: 676, height: 37)
        let right = CGRect(x: 836, y: 945, width: 676, height: 37)
        let resolved = NotchGeometry.resolveNotch(inFrame: frame, safeTop: safeTop,
                                                  left: left, right: right)
        #expect(resolved?.rect.width == 160)
        #expect(resolved?.source == .measured)
    }

    @Test("a normal pair of auxiliary areas gives a centred notch")
    func normalCase() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 856, y: 945, width: 656, height: 37)
        let notch = rect(left: left, right: right)
        #expect(notch?.width == 200)
        #expect(notch?.midX == frame.midX)
    }

    // The reported failure: a degenerate right-hand area made the "notch" run
    // to the right edge of the display. The pill centres on that rect and is
    // sized from it — a black bar, off to the right.
    @Test("a zero-width right area does not become a screen-wide notch")
    func degenerateRightArea() {
        let left = CGRect(x: 0, y: 945, width: 656, height: 37)
        let right = CGRect(x: 1512, y: 945, width: 0, height: 0)
        let notch = rect(left: left, right: right)
        #expect(notch?.width == 200)          // fell back
        #expect(notch?.midX == frame.midX)    // and is centred
    }

    @Test("an off-centre reading is rejected")
    func offCentreRejected() {
        // Left area far too wide: the gap would sit well right of centre.
        let left = CGRect(x: 0, y: 945, width: 1100, height: 37)
        let right = CGRect(x: 1350, y: 945, width: 162, height: 37)
        #expect(rect(left: left, right: right)?.midX == frame.midX)
    }

    @Test("an absurdly wide gap is rejected")
    func tooWideRejected() {
        let left = CGRect(x: 0, y: 945, width: 200, height: 37)
        let right = CGRect(x: 1312, y: 945, width: 200, height: 37)
        // Gap of 1112pt is not a notch.
        #expect(rect(left: left, right: right)?.width == 200)
    }

    @Test("missing areas fall back to a centred notch")
    func missingAreas() {
        #expect(rect(left: nil, right: nil)?.midX == frame.midX)
    }

    @Test("no safe-area inset means no notch at all")
    func noInset() {
        #expect(NotchGeometry.notchRect(inFrame: frame, safeTop: 0,
                                        left: nil, right: nil) == nil)
    }

    // Edges, not widths: an area that does not start at the screen edge used to
    // be measured as though it did.
    @Test("the gap is measured from the areas' facing edges")
    func usesFacingEdges() {
        let left = CGRect(x: 10, y: 945, width: 646, height: 37)   // inset by 10
        let right = CGRect(x: 856, y: 945, width: 646, height: 37)
        let notch = rect(left: left, right: right)
        #expect(notch?.minX == 656)
        #expect(notch?.width == 200)
    }
}

// MARK: - Secret redaction

@Suite("Secret redaction")
struct SecretRedactorTests {
    // This is not hypothetical. A GitHub PAT pasted into an agent session was
    // rendered on the notch as the task line — an overlay that sits above every
    // window and ends up in screenshots and screen shares.
    @Test("a GitHub token never reaches the screen")
    func githubToken() {
        let text = "use " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " to push"
        let out = SecretRedactor.redact(text)
        #expect(!out.contains("ghp_"))
        #expect(out.contains(SecretRedactor.placeholder))
    }

    @Test("fine-grained tokens too")
    func fineGrained() {
        #expect(!SecretRedactor.redact(fixture("github_pat_", "11ABCDEFG0abcdefghij_KLMNOPQRSTUVWXYZ"))
            .contains("github_pat_"))
    }

    // Fixtures are assembled from pieces on purpose. Written as literals they
    // are realistic enough that GitHub's own push protection rejects the
    // commit — which is a fair verdict on a file full of credential shapes,
    // and a neat confirmation that the patterns match what scanners match.
    private func fixture(_ prefix: String, _ body: String) -> String { prefix + body }

    @Test("and the other vendors")
    func otherVendors() {
        let secrets = [
            fixture("sk-ant-", "api03-abcdefghijklmnopqrstuvwxyz012345"),
            fixture("AKIA", "IOSFODNN7EXAMPLE"),
            fixture("xox", "b-123456789012-abcdefghijklmnop"),
            fixture("AIza", "SyA1234567890abcdefghijklmnopqrstuv"),
        ]
        for secret in secrets {
            #expect(SecretRedactor.containsSecret(secret), "missed \(secret.prefix(4))…")
        }
    }

    // Permission-request peeks quote the command an agent wants to run, which
    // is exactly where a credential ends up.
    @Test("a token on a command line, and one in a URL")
    func inCommands() {
        #expect(!SecretRedactor.redact("curl -H 'Authorization: Bearer abcdefghijklmnopqrstuvwxyz012345'")
            .contains("abcdefghijklmnopqrstuvwxyz"))
        #expect(SecretRedactor.containsSecret("git clone https://x-access-token:" + fixture("ghp_", "secret") + "@github.com/o/r"))
    }

    // A rule that ate ordinary text would be noise, and noise gets ignored.
    @Test("ordinary task text is left completely alone")
    func leavesNormalText() {
        for ordinary in ["fix the hover zone depending on size",
                        "Review this change for security vulnerabilities",
                        "commit 6cdcad6 and tag v1.18.0",
                        "session 93a48a21-849b-4f5b-986a-a3bb5794a63d"] {
            #expect(SecretRedactor.redact(ordinary) == ordinary)
        }
    }

    @Test("the task line on the card is redacted before it is truncated")
    func summarizeRedacts() {
        let task = AgentSession.summarize("push with " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " please")
        #expect(task?.contains("ghp_") == false)
    }

    @Test("a peek's question is redacted")
    func questionRedacted() {
        let alert = DevReadyAlert(id: "1", title: "repo", kind: .waiting,
                                  message: "run: curl -u " + fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345") + " api?")
        #expect(alert.questionText?.contains("ghp_") == false)
    }

    @Test("empty input is not a special case")
    func empty() {
        #expect(SecretRedactor.redact("") == "")
    }
}

@Suite("CI row identity")
struct CIRowIdentityTests {
    private func run(repo: String) -> CIRun {
        CIRun(id: "u", repo: repo, workflow: "Release", branch: "main",
              state: .passed, started: Date())
    }

    // Reported: someone watching a build in their own project saw a green
    // "Release — passed" and believed it. It was another repo's — the card
    // follows whichever repos your agents are in, and the row never said which.
    @Test("a row names its repository")
    func namesRepo() {
        #expect(run(repo: "someone/their-project").repoName == "their-project")
    }

    @Test("a slug without an owner still yields something")
    func bareSlug() {
        #expect(run(repo: "solo").repoName == "solo")
    }

    // A finished run's lifetime runs from when it finished. Measuring from the
    // start would expire a three-minute build before it ever completed.
    @Test("a build that took longer than the lifetime still gets shown")
    func longBuildStillAppears() {
        let now = Date()
        let slow = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                         state: .passed,
                         started: now.addingTimeInterval(-600),   // started 10 min ago
                         updated: now.addingTimeInterval(-10))    // finished 10s ago
        #expect(CIRun.current([slow], now: now).count == 1)
    }

    @Test("and disappears two minutes after it finished")
    func goesAwayAfterTwoMinutes() {
        let now = Date()
        let done = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                         state: .passed,
                         started: now.addingTimeInterval(-900),
                         updated: now.addingTimeInterval(-150))   // finished 2.5 min ago
        #expect(CIRun.current([done], now: now).isEmpty)
    }

    @Test("with no finish time it falls back to the start")
    func fallsBackToStarted() {
        let now = Date()
        let old = CIRun(id: "u", repo: "o/r", workflow: "Release", branch: "main",
                        state: .passed, started: now.addingTimeInterval(-600), updated: nil)
        #expect(CIRun.current([old], now: now).isEmpty)
    }
}

@Suite("Redaction has no gaps")
struct SecretRedactorGapTests {
    private func fixture(_ prefix: String, _ body: String) -> String { prefix + body }

    private var samples: [String] {
        [fixture("ghp_", "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"),
         fixture("github_pat_", "11ABCDEFG0abcdefghij_KLMNOPQRSTUVWXYZ"),
         fixture("sk-ant-", "api03-abcdefghijklmnopqrstuvwxyz012345"),
         fixture("AKIA", "IOSFODNN7EXAMPLE"),
         fixture("xox", "b-123456789012-abcdefghijklmnop")]
    }

    // A second pass must not find anything a first pass missed. If it does, the
    // patterns are rewriting text into new matches and the first answer was a
    // lie about what reached the screen.
    @Test("redaction is idempotent")
    func idempotent() {
        var report: [String] = []
        for s in samples {
            let once = SecretRedactor.redact("token \(s) end")
            #expect(SecretRedactor.redact(once) == once)
        }
    }

    // Whatever the surrounding punctuation, no fragment of the secret survives.
    @Test("no fragment survives any surrounding context")
    func noFragmentSurvives() {
        let contexts = ["%@", "(%@)", "\"%@\"", "run --token=%@ now",
                        "line1\n%@\nline3", "a,%@;b", "<%@>", "  %@  "]
        var report: [String] = []
        for s in samples {
            let body = String(s.dropFirst(4))   // the random-looking part
            for context in contexts {
                let text = context.replacingOccurrences(of: "%@", with: s)
                let out = SecretRedactor.redact(text)
                #expect(!out.contains(body), "survived in \(context)")
            }
        }
    }

    @Test("several secrets in one string all go")
    func multipleSecrets() {
        let text = samples.joined(separator: " and ")
        let out = SecretRedactor.redact(text)
        var report: [String] = []
        for s in samples {
            #expect(!out.contains(String(s.dropFirst(4))))
        }
    }

    // The card truncates; redaction runs first, so a half-token cannot appear.
    @Test("truncation cannot resurrect a partial token")
    func truncationSafe() {
        var report: [String] = []
        for s in samples {
            let task = AgentSession.summarize("please push using \(s) to the remote")
            #expect(task?.contains(String(s.dropFirst(4))) != true)
        }
    }
}

@Suite("Peek identity")
struct PeekIdentityTests {
    private func alert(agent: String?, source: String?) -> DevReadyAlert {
        DevReadyAlert(id: "1", title: "project", source: source, agent: agent)
    }

    // Reported: a task finished in Cursor and the peek wore the Claude Code
    // mark, badged "claude-code", then badged "cursor" beside it. Both facts
    // are true — Cursor runs Claude Code as its backend — but together they
    // read as two agents arguing about who did the work.
    @Test("a Claude agent hosted in Cursor presents as Cursor")
    func cursorHostWins() {
        let a = alert(agent: "claude-code", source: "cursor")
        #expect(a.displayAgent == .cursor)
        #expect(a.displayIdentity.lead == "cursor")
        #expect(a.displayIdentity.secondary == "claude-code")
    }

    // But behaviour still follows the agent: typed answers reach a Claude Code
    // terminal, and that does not change because of the window hosting it.
    @Test("presentation does not move the behaviour")
    func behaviourUnchanged() {
        #expect(alert(agent: "claude-code", source: "cursor").knownAgent == .claudeCode)
    }

    @Test("a plain Claude Code peek is unchanged")
    func plainClaude() {
        let a = alert(agent: "claude-code", source: "Claude Code")
        #expect(a.displayAgent == .claudeCode)
        #expect(a.displayIdentity.lead == "claude-code")
    }

    @Test("a host that adds nothing is not repeated")
    func noDuplicateBadge() {
        let a = alert(agent: "codex", source: "codex")
        #expect(a.displayIdentity.secondary == nil)
    }

    @Test("a terminal host stays a footnote")
    func terminalStaysSecondary() {
        let a = alert(agent: "claude-code", source: "cmux")
        #expect(a.displayIdentity.lead == "claude-code")
        #expect(a.displayIdentity.secondary == "cmux")
    }

    @Test("an alert with no agent name still says something")
    func noAgent() {
        #expect(alert(agent: nil, source: "cursor").displayIdentity.lead == "cursor")
    }
}

// MARK: - Permission requests

@Suite("Permission request parsing")
struct PermissionRequestTests {
    // The payload Claude Code sends for an Edit — the thing the peek was
    // throwing away in favour of "Claude needs your permission to use Edit".
    @Test("an edit becomes a diff you can read")
    func editBecomesDiff() {
        let req = PermissionRequest.parse(tool: "Edit", input: [
            "file_path": "/Users/x/proj/src/auth/middleware.ts",
            "old_string": "const verify = (token) =>\n  jwt.verify(token);",
            "new_string": "const verify = (token) =>\n  if (!token) throw new AuthError('missing');\n  return jwt.verify(token, secret);",
        ])
        #expect(req?.summary == "Edit auth/middleware.ts")
        #expect(req?.changeCount == "+2 −1")
        guard case .edit(_, let diff)? = req?.action else { return #expect(Bool(false)) }
        // The unchanged first line is context, not a delete-and-re-add.
        #expect(diff.first?.kind == .context)
        #expect(diff.contains { $0.kind == .removed && $0.text.contains("jwt.verify(token);") })
        #expect(diff.contains { $0.kind == .added && $0.text.contains("AuthError") })
    }

    @Test("a shell command is shown as itself")
    func bashCommand() {
        let req = PermissionRequest.parse(tool: "Bash", input: [
            "command": "npm test", "description": "Run the test suite",
        ])
        #expect(req?.summary == "npm test")
        guard case .run(_, let note)? = req?.action else { return #expect(Bool(false)) }
        #expect(note == "Run the test suite")
    }

    @Test("a new file says how big it is")
    func writeFile() {
        let req = PermissionRequest.parse(tool: "Write", input: [
            "file_path": "/a/b/src/routes/users.ts", "content": "one\ntwo\nthree",
        ])
        #expect(req?.summary == "Create routes/users.ts")
        guard case .write(_, let lines)? = req?.action else { return #expect(Bool(false)) }
        #expect(lines == 3)
    }

    // An agent asking for something we cannot draw still has to produce a peek.
    // Showing nothing is how someone waits on a prompt they never saw.
    @Test("an unknown tool still names itself")
    func unknownTool() {
        let req = PermissionRequest.parse(tool: "WebFetch", input: ["url": "https://example.com"])
        #expect(req?.tool == "WebFetch")
        #expect(req?.summary.contains("WebFetch") == true)
    }

    @Test("a nameless tool is not a request at all")
    func emptyTool() {
        #expect(PermissionRequest.parse(tool: "  ", input: [:]) == nil)
    }

    @Test("it reads the hook's JSON directly")
    func fromJSON() {
        let json = #"{"tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#
        #expect(PermissionRequest.parse(payload: Data(json.utf8))?.summary == "rm -rf build")
    }

    @Test("an ExitPlanMode request previews the proposed plan")
    func exitPlanMode() {
        let request = PermissionRequest.parse(tool: "ExitPlanMode", input: [
            "plan": "# Approach\n1. Inspect the model\n2. Make the change",
        ])
        #expect(request?.isPlan == true)
        #expect(request?.summary == "Review plan")
        #expect(request?.planPreviewLines == ["Approach", "1. Inspect the model", "2. Make the change"])
        #expect(request?.planPreview.first?.style == .heading)
    }

    // A command line is the likeliest place for a credential, and this renders
    // on an overlay above every window.
    @Test("a token in a command never reaches the peek")
    func redactsCommands() {
        let secret = "ghp_" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ012345"
        let req = PermissionRequest.parse(tool: "Bash", input: ["command": "git push https://\(secret)@github.com/o/r"])
        #expect(req?.redacted.summary.contains("ABCDEFGHIJ") == false)
    }
}

@Suite("Permission diff")
struct PermissionDiffTests {
    @Test("a pure addition has no removals")
    func pureAddition() {
        let diff = PermissionRequest.diff(old: "", new: "a\nb")
        #expect(diff.filter { $0.kind == .added }.count == 2)
        #expect(diff.contains { $0.kind == .removed } == false)
    }

    @Test("a pure deletion has no additions")
    func pureDeletion() {
        let diff = PermissionRequest.diff(old: "a\nb", new: "")
        #expect(diff.filter { $0.kind == .removed }.count == 2)
        #expect(diff.contains { $0.kind == .added } == false)
    }

    @Test("an unchanged hunk produces no change at all")
    func identical() {
        let diff = PermissionRequest.diff(old: "a\nb\nc", new: "a\nb\nc")
        #expect(diff.contains { $0.kind != .context } == false)
    }

    // Shared head and tail are context, so the change reads as a change rather
    // than as the whole hunk being replaced.
    @Test("shared lines top and bottom become context")
    func sharedContext() {
        let diff = PermissionRequest.diff(old: "head\nold\ntail", new: "head\nnew\ntail")
        #expect(diff.filter { $0.kind == .removed }.map(\.text) == ["old"])
        #expect(diff.filter { $0.kind == .added }.map(\.text) == ["new"])
        #expect(diff.filter { $0.kind == .context }.map(\.text) == ["head", "tail"])
    }

    // The peek has room for a hunk, not a file.
    @Test("context is capped so a huge file cannot flood the peek")
    func contextCapped() {
        let head = (1...50).map(String.init).joined(separator: "\n")
        let diff = PermissionRequest.diff(old: head + "\nold", new: head + "\nnew")
        #expect(diff.filter { $0.kind == .context }.count <= 2)
    }
}

@Suite("Permission decision")
struct PermissionDecisionTests {
    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchpill-decision-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("A written decision is what the hook reads back")
    func roundTrip() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        let decision = PermissionDecision(requestId: "req-1", verdict: .allow)
        try decision.write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "req-1", home: home))
        #expect(PermissionDecision.parse(data) == decision)
    }

    @Test("A denial carries its reason back to the agent")
    func denialReason() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "req-2", verdict: .deny,
                               reason: "not that file").write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "req-2", home: home))
        #expect(PermissionDecision.parse(data)?.reason == "not that file")
    }

    @Test("Plan feedback becomes a bounded denial reason")
    func planRevisionReason() {
        #expect(PermissionDecision.planRevisionReason("  split the migration first  ")
                == "Plan revision: split the migration first")
        #expect(PermissionDecision.planRevisionReason(" \n ") == nil)
        #expect(PermissionDecision.planRevisionReason(String(repeating: "x", count: 700))?.count == 615)
    }

    @Test("Two requests answered at once do not read each other's verdict")
    func separateFiles() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "a", verdict: .allow).write(home: home)
        try PermissionDecision(requestId: "b", verdict: .deny).write(home: home)

        let a = try Data(contentsOf: PermissionDecision.file(for: "a", home: home))
        let b = try Data(contentsOf: PermissionDecision.file(for: "b", home: home))
        #expect(PermissionDecision.parse(a)?.verdict == .allow)
        #expect(PermissionDecision.parse(b)?.verdict == .deny)
    }

    @Test("Answering twice replaces the earlier verdict")
    func overwrite() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try PermissionDecision(requestId: "c", verdict: .allow).write(home: home)
        try PermissionDecision(requestId: "c", verdict: .deny).write(home: home)

        let data = try Data(contentsOf: PermissionDecision.file(for: "c", home: home))
        #expect(PermissionDecision.parse(data)?.verdict == .deny)
    }

    @Test("A request id cannot escape the decisions directory")
    func traversal() {
        let home = URL(fileURLWithPath: "/tmp/home")
        let file = PermissionDecision.file(for: "../../etc/passwd", home: home)
        #expect(file.deletingLastPathComponent().path.hasSuffix(".notchpill/decisions"))
        #expect(!file.lastPathComponent.contains("/"))
    }

    @Test("An id with nothing safe in it still names a file")
    func emptyAfterSanitize() {
        #expect(PermissionDecision.sanitize("///") == "unnamed")
    }

    @Test("Unrecognised verdict text asks rather than allows")
    func unknownIsAsk() {
        #expect(PermissionDecision.Verdict("") == .ask)
        #expect(PermissionDecision.Verdict("maybe") == .ask)
        #expect(PermissionDecision.Verdict("ALLOW") == .allow)
        #expect(PermissionDecision.Verdict(" n ") == .deny)
    }

    @Test("Garbage on the channel is no decision, not a wrong one")
    func garbage() {
        #expect(PermissionDecision.parse(Data("not json".utf8)) == nil)
        #expect(PermissionDecision.parse(Data(#"{"verdict":"allow"}"#.utf8)) == nil)
        #expect(PermissionDecision.parse(Data(#"{"requestId":"x"}"#.utf8)) == nil)
    }
}

@Suite("Permission signal")
struct PermissionSignalTests {
    private let payload = #"{"tool_name":"Edit","tool_input":{"file_path":"/a/b/auth.ts","old_string":"x","new_string":"y"}}"#

    @Test("A PreToolUse signal decodes into a drawable request")
    func decodes() throws {
        let json = """
        {"id":"1","title":"repo","kind":"waiting","message":"Edit",
         "requestId":"abc","permission":\(payload.debugDescription)}
        """
        let alert = try JSONDecoder().decode(DevReadyAlert.self, from: Data(json.utf8))
        #expect(alert.requestId == "abc")
        #expect(alert.permissionRequest?.summary == "Edit b/auth.ts")
    }

    @Test("The live notification path carries the request too")
    func decodesUserInfo() {
        // There are two parsers — Codable for queued signal files, userInfo for
        // the live distributed notification. Only the file path was updated at
        // first, so a request arriving while the app ran drew as a bare "Edit".
        let alert = DevReadyAlert.parse(userInfo: [
            "title": "repo", "kind": "waiting", "message": "Edit",
            "requestId": "abc", "permission": payload,
        ])
        #expect(alert?.permissionRequest?.summary == "Edit b/auth.ts")
    }

    @Test("A payload with no request id has nowhere to answer, so shows no request")
    func requiresRequestId() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting, permissionPayload: payload)
        #expect(alert.permissionRequest == nil)
    }

    @Test("A finished alert is never a permission request")
    func requiresWaiting() {
        let alert = DevReadyAlert(title: "repo", kind: .finished,
                                  requestId: "abc", permissionPayload: payload)
        #expect(alert.permissionRequest == nil)
    }

    @Test("An ordinary waiting peek carries no request")
    func noPayload() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting, message: "Continue?")
        #expect(alert.permissionRequest == nil)
    }

    @Test("A command reaching the screen is redacted first")
    func redacts() {
        let secret = "gh" + "p_" + String(repeating: "A", count: 36)
        let raw = #"{"tool_name":"Bash","tool_input":{"command":"curl -H 'token: \#(secret)'"}}"#
        let alert = DevReadyAlert(title: "repo", kind: .waiting,
                                  requestId: "abc", permissionPayload: raw)
        #expect(alert.permissionRequest?.summary.contains(secret) == false)
    }

    @Test("An unparseable payload degrades to no request, not a crash")
    func garbage() {
        let alert = DevReadyAlert(title: "repo", kind: .waiting,
                                  requestId: "abc", permissionPayload: "{not json")
        #expect(alert.permissionRequest == nil)
    }
}

@Suite("Permission preview")
struct PermissionPreviewTests {
    private func request(_ old: String, _ new: String) -> PermissionRequest {
        PermissionRequest(action: .edit(path: "/a/b.swift",
                                        diff: PermissionRequest.diff(old: old, new: new)),
                          tool: "Edit")
    }

    @Test("A short diff is shown whole")
    func short() {
        let r = request("a", "b")
        #expect(r.previewLines.count == 2)
    }

    @Test("A long diff is capped to what the peek can draw")
    func capped() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        let new = (1...20).map { "changed \($0)" }.joined(separator: "\n")
        #expect(request(old, new).previewLines.count == PermissionRequest.previewLimit)
    }

    @Test("When the change alone overflows, context is dropped first")
    func changesBeatContext() {
        let old = "keep\n" + (1...6).map { "old \($0)" }.joined(separator: "\n") + "\ntail"
        let new = "keep\n" + (1...6).map { "new \($0)" }.joined(separator: "\n") + "\ntail"
        let lines = request(old, new).previewLines
        #expect(lines.allSatisfy { $0.kind != .context })
    }

    @Test("The count still describes the whole change, not the visible part")
    func countIsOfTheWhole() {
        let old = (1...9).map { "old \($0)" }.joined(separator: "\n")
        let new = (1...9).map { "new \($0)" }.joined(separator: "\n")
        let r = request(old, new)
        #expect(r.previewLines.count == 4)
        #expect(r.changeCount == "+9 −9")
    }

    @Test("A command has no diff lines but is set as machine text")
    func command() {
        let r = PermissionRequest(action: .run(command: "rm -rf build", note: nil), tool: "Bash")
        #expect(r.previewLines.isEmpty)
        #expect(r.isCommand)
        #expect(r.commandPreviewLineLimit == 3)
        #expect(request("a", "b").isCommand == false)
        #expect(request("a", "b").commandPreviewLineLimit == 1)
    }
}

@MainActor
@Suite("Answering a permission request")
struct PermissionAnswerabilityTests {
    private let payload = #"{"tool_name":"Bash","tool_input":{"command":"ls"}}"#

    private func alert(delivery: String?, requestId: String?) -> DevReadyAlert {
        DevReadyAlert(title: "repo", agent: "claude-code", kind: .waiting, message: "Bash",
                      createdAt: Date().timeIntervalSince1970,
                      answerSpec: "Allow:y|Deny:n", deliverySpec: delivery,
                      requestId: requestId, permissionPayload: payload)
    }

    @Test("A decision peek offers buttons with no terminal to target")
    func decisionNeedsNoTerminal() {
        #expect(alert(delivery: "decision", requestId: "r1")
            .canAnswerFromNotch(replyEnabled: true) == true)
    }

    @Test("A decision with no request id has nowhere to answer")
    func decisionNeedsRequestId() {
        let a = alert(delivery: "decision", requestId: nil)
        #expect(a.answersByDecision == false)
        #expect(a.permissionRequest == nil)
    }

    @Test("Answers off means no buttons, decision or not")
    func respectsSetting() {
        #expect(alert(delivery: "decision", requestId: "r1")
            .canAnswerFromNotch(replyEnabled: false) == false)
    }

    @Test("A stale request is not answerable — the hook gave up long ago")
    func staleness() {
        var a = alert(delivery: "decision", requestId: "r1")
        a.createdAt = Date().timeIntervalSince1970 - DevReadyProvider.waitingStaleAfter - 60
        #expect(a.canAnswerFromNotch(replyEnabled: true) == false)
    }

    @Test("Allow and Deny map onto the verdicts the hook understands")
    func buttonsMapToVerdicts() {
        let answers = alert(delivery: "decision", requestId: "r1").answers
        #expect(answers.map(\.label) == ["Allow", "Deny"])
        #expect(PermissionDecision.Verdict(answers[0].keystroke) == .allow)
        #expect(PermissionDecision.Verdict(answers[1].keystroke) == .deny)
    }
}

@Suite("Idle agents age off the card")
struct AgentSessionAgeingTests {
    private let now = Date()

    private func session(_ id: String, _ state: AgentSession.State,
                         age: TimeInterval = 0) -> AgentSession {
        AgentSession(id: id, agent: "claude-code", project: "p", state: state,
                     lastActivity: now.addingTimeInterval(-age))
    }

    @Test("A session quiet past the idle window is history")
    func idleAgesOut() {
        let stale = session("a", .idle(since: now.addingTimeInterval(-600)))
        #expect(AgentSession.current([stale], now: now).isEmpty)
    }

    @Test("A recently quiet session is still shown")
    func recentIdleStays() {
        // The idle window is 30s, so this is deliberately well inside it —
        // 60s used to qualify when the window was five minutes.
        let fresh = session("a", .idle(since: now.addingTimeInterval(-10)))
        #expect(AgentSession.current([fresh], now: now).count == 1)
    }

    @Test("A session quiet for a minute is gone under the 30s window")
    func minuteOldIdleIsGone() {
        let stale = session("a", .idle(since: now.addingTimeInterval(-60)))
        #expect(AgentSession.current([stale], now: now).isEmpty)
    }

    @Test("A long build is not idle and never ages out")
    func workingSurvives() {
        let working = session("a", .working, age: 10_000)
        #expect(AgentSession.current([working], now: now).count == 1)
    }

    @Test("An unanswered question outlives the idle window")
    func waitingSurvives() {
        // The whole reason the live window is two hours: an agent blocked on a
        // permission prompt writes nothing, and dropping it would hide the one
        // row you can act on.
        let waiting = session("a", .waiting(since: nil), age: 10_000)
        #expect(AgentSession.current([waiting], now: now).count == 1)
    }

    @Test("A card of stale agents empties rather than filling with nothing")
    func theReportedCase() {
        let sessions = (1...6).map {
            session("s\($0)", .idle(since: now.addingTimeInterval(-480)))
        } + [session("live", .working)]
        let kept = AgentSession.current(sessions, now: now)
        #expect(kept.map(\.id) == ["live"])
    }
}

@Suite("Approval gate")
struct ApprovalGateTests {
    private func scratch() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("notchpill-gate-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Off when the file is not there — the shipped default")
    func defaultsOff() {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    @Test("Enabling creates the file, and the directory it lives in")
    func enableCreatesFile() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)

        #expect(FileManager.default.fileExists(atPath: ApprovalGate.file(home: home).path))
        #expect(ApprovalGate.isEnabled(home: home))
    }

    @Test("Disabling removes it, leaving the state the app ships with")
    func disableRemovesFile() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)
        try ApprovalGate.setEnabled(false, home: home)

        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    /// Turning something off is the escape hatch; it must not throw because the
    /// thing was already off. The toggle would flip back and look stuck.
    @Test("Disabling something already off is not an error")
    func disableIsIdempotent() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(false, home: home)
        try ApprovalGate.setEnabled(false, home: home)

        #expect(ApprovalGate.isEnabled(home: home) == false)
    }

    @Test("Enabling twice is not an error")
    func enableIsIdempotent() throws {
        let home = scratch()
        defer { try? FileManager.default.removeItem(at: home) }
        try ApprovalGate.setEnabled(true, home: home)
        try ApprovalGate.setEnabled(true, home: home)

        #expect(ApprovalGate.isEnabled(home: home))
    }

    /// The path the hook script documents. If this moves, the script's
    /// `~/.notchpill/approvals-enabled` check silently stops matching.
    @Test("The path is the one the hook watches")
    func pathMatchesHook() {
        let home = URL(fileURLWithPath: "/tmp/home")
        #expect(ApprovalGate.file(home: home).path == "/tmp/home/.notchpill/approvals-enabled")
    }
}

@Suite("Agent vendor glyph")
struct AgentVendorSymbolTests {
    private func session(agent: String, subagent: String? = nil) -> AgentSession {
        AgentSession(id: "s", agent: agent, project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("Each known vendor gets its own mark")
    func knownVendors() {
        #expect(session(agent: "claude-code").vendorSymbol == "asterisk")
        #expect(session(agent: "codex").vendorSymbol
                == "chevron.left.forwardslash.chevron.right")
        #expect(session(agent: "cursor").vendorSymbol == "cursorarrow")
    }

    @Test("No mark invented for an agent we do not know")
    func unknownVendor() {
        #expect(session(agent: "some-new-tool").vendorSymbol == nil)
        #expect(session(agent: "").vendorSymbol == nil)
    }

    /// The reason the glyph exists: a sub-agent row shows the persona, so
    /// without it the vendor appears nowhere on the row.
    @Test("A sub-agent row hides the vendor name but keeps the mark")
    func subagentStillShowsVendor() {
        let s = session(agent: "claude-code", subagent: "code-reviewer")
        #expect(s.displayName == "Code Reviewer")
        #expect(s.vendorSymbol == "asterisk")
    }

    /// Colour is state, not brand — the confusion the glyph is there to fix.
    @Test("Two vendors waiting are the same colour and differ only by mark")
    func colourIsStateNotBrand() {
        let claude = session(agent: "claude-code")
        let cursor = session(agent: "cursor")
        #expect(claude.vendorSymbol != cursor.vendorSymbol)
        #expect(claude.statusLabel == cursor.statusLabel)
    }
}

@Suite("CI supersedes")
struct CISupersedeTests {
    private func run(_ id: String, _ state: CIRun.State, minutesAgo: Double,
                     branch: String = "main", workflow: String = "Release") -> CIRun {
        let t = Date().addingTimeInterval(-minutesAgo * 60)
        return CIRun(id: id, repo: "o/r", workflow: workflow, branch: branch,
                     state: state, started: t, updated: t)
    }

    /// The bug: a failure lives six hours, a pass two minutes, so a fixed
    /// build kept reading "failed" long after the green re-run aged off.
    @Test("A passing re-run replaces the failure it fixed")
    func passSupersedesFailure() {
        let runs = [run("fail", .failed, minutesAgo: 30),
                    run("pass", .passed, minutesAgo: 29)]
        let kept = CIRun.current(runs)
        #expect(kept.map(\.id) == ["pass"] || kept.isEmpty)
        #expect(!kept.contains { $0.state == .failed })
    }

    @Test("A retry still running also replaces the failure")
    func runningSupersedesFailure() {
        let kept = CIRun.current([run("fail", .failed, minutesAgo: 10),
                                  run("retry", .running, minutesAgo: 1)])
        #expect(kept.map(\.id) == ["retry"])
    }

    @Test("An older run never replaces a newer one")
    func olderDoesNotSupersede() {
        let kept = CIRun.current([run("new", .running, minutesAgo: 1),
                                  run("old", .failed, minutesAgo: 90)])
        #expect(kept.map(\.id) == ["new"])
    }

    @Test("Different branches and workflows are separate targets")
    func targetsAreIndependent() {
        let runs = [run("a", .failed, minutesAgo: 10, branch: "main"),
                    run("b", .failed, minutesAgo: 9, branch: "dev"),
                    run("c", .failed, minutesAgo: 8, workflow: "Test")]
        #expect(CIRun.current(runs).count == 3)
    }

    @Test("A lone failure still survives, as before")
    func failureStillLives() {
        #expect(CIRun.current([run("fail", .failed, minutesAgo: 60)]).count == 1)
    }
}

@Suite("tmux pane targeting")
struct TmuxLocatorTests {
    private let listing = """
    /dev/ttys001\twork:0.0
    /dev/ttys012\twork:2.1
    /dev/ttys120\tother:0.0
    """

    @Test("Finds the pane owning the agent's TTY")
    func findsPane() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: listing) == "work:2.1")
    }

    /// `/dev/ttys1` is a prefix of `/dev/ttys120`. A loose match would drop
    /// you into an unrelated pane and read as tmux misbehaving.
    @Test("Matching is exact, never a prefix")
    func exactMatchOnly() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys1", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys12", in: listing) == nil)
    }

    @Test("No pane, no answer")
    func noMatch() {
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys999", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "", in: listing) == nil)
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: "") == nil)
    }

    @Test("Garbled lines are skipped, not fatal")
    func toleratesJunk() {
        let messy = "no-tab-here\n\n/dev/ttys012\twork:2.1\n"
        #expect(TmuxLocator.paneTarget(forTTY: "/dev/ttys012", in: messy) == "work:2.1")
    }

    /// Selecting the pane without its window leaves you on the right pane of
    /// a window you cannot see.
    @Test("Both the window and the pane are selected")
    func selectsWindowThenPane() {
        let args = TmuxLocator.selectArguments(target: "work:2.1")
        #expect(args == [["select-window", "-t", "work:2.1"],
                         ["select-pane", "-t", "work:2.1"]])
    }

    @Test("Absent tmux is not an error, just no pane jump")
    func missingTmuxIsSilent() {
        #expect(TmuxLocator.executable(fileExists: { _ in false }) == nil)
        var ran = false
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys012", tmuxPath: nil) { _, _ in
            ran = true; return nil
        }
        #expect(ok == false)
        #expect(ran == false)
    }

    /// The whole round trip against a stubbed tmux. The path is injected so
    /// this exercises the real sequence on a machine with no tmux installed —
    /// otherwise the test would quietly assert nothing here.
    @Test("Drives tmux with the arguments it expects")
    func drivesTmux() {
        var calls: [[String]] = []
        let listing = self.listing
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys012", tmuxPath: "/fake/tmux") { path, args in
            #expect(path == "/fake/tmux")
            calls.append(args)
            return args.first == "list-panes" ? Data(listing.utf8) : Data()
        }
        #expect(ok)
        #expect(calls == [TmuxLocator.listArguments] + TmuxLocator.selectArguments(target: "work:2.1"))
    }

    @Test("Declines when an exact tmux pane cannot be selected")
    func failedTmuxSelection() {
        let listing = self.listing
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys012", tmuxPath: "/fake/tmux") { _, args in
            args.first == "list-panes" ? Data(listing.utf8) : nil
        }
        #expect(!ok)
    }

    @Test("A TTY in no pane runs no select commands")
    func unmatchedTTYSelectsNothing() {
        var calls: [[String]] = []
        let listing = self.listing
        let ok = TmuxLocator.focusPane(tty: "/dev/ttys999", tmuxPath: "/fake/tmux") { _, args in
            calls.append(args)
            return Data(listing.utf8)
        }
        #expect(ok == false)
        #expect(calls == [TmuxLocator.listArguments])
    }
}

@Suite("OpenCode sessions")
struct OpenCodeAgentTests {
    private func session(subagent: String? = nil) -> AgentSession {
        AgentSession(id: "ses_1", agent: "opencode", project: "p",
                     state: .working, lastActivity: Date(), subagent: subagent)
    }

    @Test("Recognised as its own vendor, not an unknown agent")
    func recognised() {
        let s = session()
        #expect(s.knownAgent == .openCode)
        #expect(s.agentName == "OpenCode")
        #expect(s.vendorSymbol == "curlybraces")
    }

    @Test("The wire name is not shown raw")
    func doesNotLeakWireName() {
        #expect(session().displayName != "opencode")
    }

    /// A child session is OpenCode's sub-agent, and should read like every
    /// other sub-agent row rather than like a second top-level agent.
    @Test("A child session reads as a sub-agent")
    func childIsSubagent() {
        #expect(session(subagent: "subagent").displayName == "Subagent")
    }

    /// Archiving is the user putting a session away on purpose — a stronger
    /// signal than age, and it must not come back because something touched it.
    @Test("The query excludes archived sessions and is bounded")
    func queryShape() {
        let sql = AgentSessionScanner.openCodeSQL
        #expect(sql.contains("time_archived IS NULL"))
        #expect(sql.contains("time_updated > ?"))
        #expect(sql.contains("LIMIT"))
    }

    @Test("Usage query is local, bounded to active sessions, and never claims a quota")
    func usageQueryShape() {
        let sql = AgentSessionScanner.openCodeUsageSQL
        #expect(sql.contains("time_updated >= ?"))
        #expect(sql.contains("time_archived IS NULL"))
        #expect(!sql.localizedCaseInsensitiveContains("quota"))
    }

    @Test("Usage hides when OpenCode has recorded no tokens or cost")
    func usageNeedsActivity() {
        let empty = OpenCodeUsage(inputTokens: 0, outputTokens: 0, reasoningTokens: 0,
                                  cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        let active = OpenCodeUsage(inputTokens: 1_200, outputTokens: 80, reasoningTokens: 0,
                                   cacheReadTokens: 0, cacheWriteTokens: 0, cost: 0)
        #expect(!empty.hasActivity)
        #expect(active.hasActivity)
        #expect(active.tokenLabel == "1.3k tokens")
        #expect(active.costLabel == "No cost")
    }

    /// Nothing in the schema says which session is blocked — the permission
    /// table is per project. Inventing "waiting" would put a false Allow/Deny
    /// row on the card.
    @Test("Never claims to be waiting on you")
    func neverFakesWaiting() {
        let s = AgentSession.state(lastWrite: Date(), blocked: false)
        #expect(s == .working)
    }
}

@Suite("Agent model label")
struct AgentModelLabelTests {
    @Test("Vendor prefixes and build stamps are stripped")
    func prettifies() {
        #expect(AgentSession.modelLabel("claude-opus-5") == "Opus 5")
        #expect(AgentSession.modelLabel("claude-sonnet-5") == "Sonnet 5")
        #expect(AgentSession.modelLabel("claude-opus-4-8") == "Opus 4.8")
        #expect(AgentSession.modelLabel("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(AgentSession.modelLabel("claude-fable-5-1") == "Fable 5.1")
        #expect(AgentSession.modelShortLabel("claude-fable-5-1") == "Fable 5.1")
    }

    @Test("Known families shorten to what you actually choose between")
    func knownFamilies() {
        #expect(AgentSession.modelLabel("gpt-5.6-terra") == "GPT 5.6 Terra")
        #expect(AgentSession.modelLabel("gpt-5.6-soul-terra") == "GPT 5.6 Soul Terra")
        #expect(AgentSession.modelLabel("gemini-3-pro") == "Gemini 3 Pro")
    }

    /// A model we have never seen is exactly the one worth naming. Trimming it
    /// to its first segment would render `gpt-5.6-terra` as "Gpt", throwing
    /// away the only part that distinguishes it — so unknowns keep their id.
    @Test("An unfamiliar model keeps its full id")
    func unknownPassesThrough() {
        #expect(AgentSession.modelLabel("some-new-thing-7") == "some-new-thing-7")
        #expect(AgentSession.modelLabel("anthropic.mystery-2") == "mystery-2")
    }

    @Test("Nothing to say stays silent")
    func emptyStaysNil() {
        #expect(AgentSession.modelLabel(nil) == nil)
        #expect(AgentSession.modelLabel("") == nil)
        #expect(AgentSession.modelLabel("   ") == nil)
        #expect(AgentSession.modelLabel("<synthetic>") == nil)
        #expect(AgentSession.modelShortLabel(nil) == nil)
        #expect(AgentSession.modelShortLabel("<synthetic>") == nil)
    }

    /// The tile badge has room for about ten characters, so the variant goes
    /// and the family and version stay — those are what you scan for.
    @Test("The short label keeps family and version and drops the variant")
    func shortLabel() {
        #expect(AgentSession.modelShortLabel("claude-opus-5") == "Opus 5")
        #expect(AgentSession.modelShortLabel("claude-haiku-4-5-20251001") == "Haiku 4.5")
        #expect(AgentSession.modelShortLabel("gpt-5.6-terra") == "GPT 5.6")
        #expect(AgentSession.modelShortLabel("gpt-5.6-soul-terra") == "GPT 5.6")
        #expect(AgentSession.modelShortLabel("gemini-3-pro") == "Gemini 3")
    }

    /// An unknown model is the one worth naming, so it is not shortened to
    /// nothing; the tile truncates it visually instead.
    @Test("The short label passes an unfamiliar model through whole")
    func shortLabelUnknown() {
        #expect(AgentSession.modelShortLabel("some-new-thing-7") == "some-new-thing-7")
    }

    private func session(model: String?, effort: String?) -> AgentSession {
        AgentSession(id: "s", agent: "claude-code", project: "p", state: .working,
                     lastActivity: Date(), model: model, effort: effort)
    }

    @Test("Every recorded effort is shown")
    func effortSuffix() {
        #expect(session(model: "claude-opus-5", effort: "high").modelLabel == "Opus 5 · high")
        #expect(session(model: "claude-opus-5", effort: "low").modelLabel == "Opus 5 · low")
        #expect(session(model: "gpt-5.6-terra", effort: "medium").modelLabel
                == "GPT 5.6 Terra · medium")
        #expect(session(model: "claude-opus-5", effort: nil).modelLabel == "Opus 5")
        #expect(session(model: nil, effort: "high").modelLabel == nil)
    }

    @Test("Claude records the model in the message and the effort beside it")
    func parsesClaude() {
        let line = #"{"effort":"low","message":{"model":"claude-opus-5","role":"assistant"}}"#
        let got = AgentSessionScanner.claudeModel(in: line)
        #expect(got.model == "claude-opus-5")
        #expect(got.effort == "low")
    }

    /// Newest first: both can change mid-session, and a sub-agent may run on a
    /// different model than its parent.
    @Test("The newest record wins")
    func newestWins() {
        let text = [#"{"message":{"model":"claude-sonnet-5"}}"#,
                    #"{"effort":"high","message":{"model":"claude-opus-5"}}"#].joined(separator: "\n")
        #expect(AgentSessionScanner.claudeModel(in: text).model == "claude-opus-5")
    }

    @Test("Codex prefers its settled thread settings")
    func parsesCodex() {
        let line = #"{"payload":{"model":"gpt-5.6-terra","thread_settings":{"model":"gpt-5.6-terra","reasoning_effort":"high"}}}"#
        let got = AgentSessionScanner.codexModel(in: line)
        #expect(got.model == "gpt-5.6-terra")
        #expect(got.effort == "high")
    }

    /// Cursor keeps the picked model's settings as `{id, value}` pairs, so the
    /// effort has to be found by id rather than read as a field.
    @Test("Cursor's effort is picked out of its parameter list")
    func parsesCursorEffort() {
        let params = #"[{"id":"thinking","value":"true"},{"id":"context","value":"300k"},{"id":"effort","value":"high"}]"#
        #expect(AgentSessionScanner.cursorEffort(inParameters: params) == "high")
        #expect(AgentSessionScanner.cursorEffort(inParameters: #"[{"id":"thinking","value":"true"}]"#) == nil)
        #expect(AgentSessionScanner.cursorEffort(inParameters: nil) == nil)
        #expect(AgentSessionScanner.cursorEffort(inParameters: "not json") == nil)
    }

    /// The scanner asks SQLite for the two model fields by path so the
    /// ~140KB conversation record never crosses into Swift.
    @Test("Cursor's query joins the conversation record for its model")
    func cursorQueryJoinsModel() {
        #expect(AgentSessionScanner.cursorSQL.contains("$.modelConfig.modelName"))
        #expect(AgentSessionScanner.cursorSQL.contains("'composerData:' || h.composerId"))
        #expect(AgentSessionScanner.cursorSQL.contains("LEFT JOIN"))
    }

    @Test("Junk lines are skipped rather than fatal")
    func toleratesJunk() {
        let text = ["not json", "", #"{"message":{"model":"<synthetic>"}}"#,
                    #"{"message":{"model":"claude-opus-5"}}"#].joined(separator: "\n")
        #expect(AgentSessionScanner.claudeModel(in: text).model == "claude-opus-5")
    }
}

/// `~/.claude/projects` holds every Claude Code run, not every terminal
/// session. SDK-driven runs write transcripts there too, and each one that
/// lands inside the live window used to become a Live Agents row for an agent
/// nobody started — on whatever model the SDK caller picked.
@Suite("Only interactive sessions reach the card")
struct InteractiveSessionTests {
    @Test("A terminal session is interactive")
    func terminalCounts() {
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "cli"))
    }

    @Test("SDK-driven runs are not")
    func sdkRunsExcluded() {
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-py"))
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-cli"))
        // Whatever the next binding is called.
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "sdk-ts"))
        #expect(!AgentSessionScanner.claudeIsInteractive(entrypoint: "SDK-PY"))
    }

    /// Hiding a running agent is a worse failure than showing an odd one, so
    /// anything we cannot classify stays on the card.
    @Test("An unknown or missing entrypoint stays visible")
    func unknownStaysVisible() {
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: nil))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: ""))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "   "))
        #expect(AgentSessionScanner.claudeIsInteractive(entrypoint: "vscode"))
    }

    @Test("The entrypoint is read from the transcript's own records")
    func readFromTranscript() {
        let text = #"{"type":"attachment","entrypoint":"sdk-py","cwd":"/tmp"}"#
        #expect(AgentSessionScanner.firstValue(in: text, key: "entrypoint") == "sdk-py")
    }
}

/// The log records what the app did; these record what it declined to do,
/// which is where every real bug so far has lived.
/// The hot-zone shortcuts are swallowed by an event tap, so a false positive
/// does not merely trigger playback — it stops the key reaching the app you
/// are typing in.
@Suite("Typing keeps the keyboard")
struct TypingGuardTests {
    private let space: UInt16 = 49

    @Test("A space mid-sentence belongs to the sentence")
    func typingReleasesSpace() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)     // "k"
        #expect(guard0.isTyping(now: 100.1))
        // Still typing a quarter second later — this is the failing case.
        #expect(guard0.isTyping(now: 100.25))
    }

    @Test("Shortcuts alone never mark you as typing")
    func shortcutsDoNotArm() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: true, now: 100)
        #expect(!guard0.isTyping(now: 100.01))
    }

    @Test("A pause hands the keys back to the notch")
    func graceExpires() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(!guard0.isTyping(now: 100 + TypingGuard.grace))
        #expect(!guard0.isTyping(now: 105))
    }

    @Test("A fresh guard is not typing")
    func startsIdle() {
        #expect(!TypingGuard().isTyping(now: 100))
    }

    @Test("Reaching for the notch clears the sentence behind you")
    func resetOnEntry() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(guard0.isTyping(now: 100.1))
        guard0.reset()
        #expect(!guard0.isTyping(now: 100.1))
    }

    /// A backwards clock jump must not wedge the guard on and mute the
    /// shortcuts indefinitely.
    @Test("A clock going backwards does not stick")
    func backwardsClock() {
        var guard0 = TypingGuard()
        guard0.observe(isShortcut: false, now: 100)
        #expect(!guard0.isTyping(now: 50))
    }
}

/// The in-memory log cannot help with a bug on someone else's Mac, which is
/// the case that keeps costing real time. These cover the parts of the on-disk
/// copy that fail quietly if they are wrong.
/// Murmur writes a caption file that persists across restarts. Treating a file
/// as an event is the whole risk here.
/// A truncated caption defeats the feature: the sentence you switched it on to
/// read is exactly the part that gets cut. Height must follow the text, and the
/// budget must never run short — a single-alert peek pins its list to the
/// window, so unbudgeted rows draw outside it.
@Suite("Caption peeks grow with the text")
struct CaptionSizingTests {
    @Test("A short caption stays one line")
    func shortStaysOneLine() {
        #expect(NotchContentLayout.titleLines(for: "Hello there") == 1)
    }

    @Test("A spoken sentence wraps")
    func sentenceWraps() {
        let sentence = String(repeating: "word ", count: 30)   // ~150 chars
        #expect(NotchContentLayout.titleLines(for: sentence) > 1)
    }

    @Test("Growth is capped rather than unbounded")
    func cappedAtMax() {
        let essay = String(repeating: "a", count: 5000)
        #expect(NotchContentLayout.titleLines(for: essay) == NotchContentLayout.titleMaxLines)
    }

    @Test("Empty text still occupies a line")
    func emptyIsOneLine() {
        #expect(NotchContentLayout.titleLines(for: "") == 1)
    }

    /// The four-line cap still truncated ordinary speech — roughly two
    /// sentences at the peek's width. A dictated paragraph has to fit whole.
    @Test("A spoken paragraph fits without hitting the cap")
    func paragraphFits() {
        let paragraph = "Okay so I am currently speaking right now through the Murmur "
            + "app and this is speech to text, and what I want to check is that a "
            + "reasonably long thought like this one shows up in the notch without "
            + "an ellipsis cutting off the end of it."
        let lines = NotchContentLayout.titleLines(for: paragraph)
        #expect(lines > 4)                                   // the old cap was not enough
        #expect(lines < NotchContentLayout.titleMaxLines)    // and the new one is not hit
    }

    /// Shrinking is what turns "needs 8.2 lines" into smaller text rather than
    /// lost words, and it must never apply to ordinary one-line peek titles.
    /// Height was never the scarce resource — width was. At the ordinary
    /// ceiling a line holds ~47 characters, so no height budget could rescue a
    /// paragraph.
    @Test("A wrapping peek is given more width than an ordinary one")
    func wrappingPeekIsWider() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54, screenWidth: 1470)
        let ordinary = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: false)
        let wrapping = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true)
        // 720 * 0.54 — the ordinary expanded ceiling, asserted by value rather
        // than by widening the property's access just for a test.
        #expect(abs(ordinary - 388.8) < 0.01)
        #expect(wrapping > ordinary * 1.5)
        // Never wider than the display it sits on.
        #expect(wrapping < metrics.screenWidth)
    }

    @Test("An unknown screen width still widens, and never narrows")
    func unknownScreenIsSafe() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54)          // screenWidth defaults to 0
        let wrapping = NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true)
        #expect(wrapping >= 388.8)
    }

    /// The whole point of the extra width: the same sentence needs fewer lines.
    @Test("Widening the peek cuts the lines a paragraph needs")
    func widerNeedsFewerLines() {
        let paragraph = String(repeating: "word ", count: 80)   // ~400 chars
        let narrow = NotchContentLayout.titleLines(for: paragraph, width: 389)
        let wide = NotchContentLayout.titleLines(for: paragraph, width: 760)
        #expect(wide < narrow)
    }

    @Test("Only wrapping titles are allowed to shrink")
    func shrinkIsScopedToCaptions() {
        #expect(NotchContentLayout.titleMinimumScale < 1)
        #expect(NotchContentLayout.titleMinimumScale >= 0.7)  // still readable
    }

    @Test("More lines means a taller peek, and one line adds nothing")
    func heightFollowsLines() {
        func alert(lines: Int?) -> DevReadyAlert {
            DevReadyAlert(id: "a", title: "t", titleLines: lines)
        }
        #expect(NotchContentLayout.titleExtraHeight(alerts: [alert(lines: nil)]) == 0)
        #expect(NotchContentLayout.titleExtraHeight(alerts: [alert(lines: 1)]) == 0)
        let three = NotchContentLayout.titleExtraHeight(alerts: [alert(lines: 3)])
        #expect(three == 2 * NotchContentLayout.titleLineHeight)
    }

    /// The layout must actually spend the allowance, or the extra lines draw
    /// outside the window.
    @Test("The peek is taller for a wrapped caption than a one-line one")
    @MainActor
    func layoutIsTaller() {
        let metrics = NotchMetrics(notchWidth: 179, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 128,
                                   scale: 0.54)
        // Real strings, because the height now follows what the text actually
        // measures rather than a number baked into the alert. Asserting on a
        // hand-set `titleLines` would only prove the old estimate still exists.
        let short = DevReadyAlert(id: "a", title: "Hi")
        let long = DevReadyAlert(id: "a", title: String(repeating: "spoken words ", count: 40))
        let shortLayout = NotchContentLayout.devReadyLayout(
            metrics: metrics, alerts: [short], answerEnabled: false)
        let longLayout = NotchContentLayout.devReadyLayout(
            metrics: metrics, alerts: [long], answerEnabled: false)
        #expect(longLayout.size.height > shortLayout.size.height)
        let lines = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [long], answerEnabled: false).lines["a"] ?? 1
        #expect(lines > 1)
        #expect(longLayout.size.height - shortLayout.size.height
                == CGFloat(lines - 1) * NotchContentLayout.titleLineHeight)
    }

    @Test("A dictated sentence reaches the peek with room to show it")
    func captionAlertWraps() {
        let spoken = "Okay so I am currently speaking right now through the Murmur app "
            + "and this is speech to text and I want to see the whole sentence."
        let alert = NotchController.alert(for:
            DictationCaption(text: spoken, timestamp: Date()))
        #expect((alert.titleLines ?? 1) > 1)
        #expect(alert.title == spoken)
    }
}

@Suite("Dictation captions")
struct DictationCaptionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func json(_ text: String, _ millis: Double) -> Data {
        Data(#"{"text": "\#(text)", "timestamp": \#(Int(millis))}"#.utf8)
    }

    @Test("Murmur's format parses, milliseconds and all")
    func parses() {
        let caption = DictationCaption.parse(json("hello there", 1_800_000_000_000))
        #expect(caption?.text == "hello there")
        #expect(caption?.timestamp == Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test("Junk, empty text and missing timestamps are skipped, not fatal")
    func tolerant() {
        #expect(DictationCaption.parse(Data("not json".utf8)) == nil)
        #expect(DictationCaption.parse(json("   ", 1_800_000_000_000)) == nil)
        #expect(DictationCaption.parse(Data(#"{"text":"hi"}"#.utf8)) == nil)
        #expect(DictationCaption.parse(Data(#"{"timestamp":123}"#.utf8)) == nil)
    }

    /// The caption sitting on this machine was written in July. Without this
    /// rule the first launch would pop a months-old sentence as if it had just
    /// been spoken.
    @Test("A caption from months ago is not news")
    func staleIsIgnored() {
        let old = DictationCaption(text: "old", timestamp: now.addingTimeInterval(-86_400 * 30))
        #expect(!DictationCaption.shouldPresent(old, lastPresented: nil, now: now))
    }

    @Test("Something just said is shown")
    func freshIsShown() {
        let fresh = DictationCaption(text: "new", timestamp: now.addingTimeInterval(-1))
        #expect(DictationCaption.shouldPresent(fresh, lastPresented: nil, now: now))
    }

    @Test("The same caption is never shown twice")
    func noRepeats() {
        let caption = DictationCaption(text: "once", timestamp: now.addingTimeInterval(-1))
        #expect(!DictationCaption.shouldPresent(caption,
                                                lastPresented: caption.timestamp, now: now))
        let next = DictationCaption(text: "twice", timestamp: now)
        #expect(DictationCaption.shouldPresent(next,
                                               lastPresented: caption.timestamp, now: now))
    }

    /// Murmur's clock running microseconds ahead must not silently mute it.
    @Test("A caption from the near future still counts as fresh")
    func futureIsFresh() {
        let ahead = DictationCaption(text: "ahead", timestamp: now.addingTimeInterval(2))
        #expect(DictationCaption.shouldPresent(ahead, lastPresented: nil, now: now))
    }

    @Test("A spoken secret never reaches the overlay")
    func redactsSpokenSecrets() {
        let caption = DictationCaption(
            text: "the token is ghp_0123456789abcdefghijABCDEFGHIJ0123 ok",
            timestamp: now)
        let alert = NotchController.alert(for: caption)
        #expect(!alert.title.contains("ghp_0123456789abcdefghijABCDEFGHIJ0123"))
        #expect(alert.title.contains(SecretRedactor.placeholder))
    }

    /// A caption is not a question: answer buttons would type into whatever
    /// terminal happened to be focused.
    @Test("A caption peek carries no answer path")
    func notAnswerable() {
        let alert = NotchController.alert(for:
            DictationCaption(text: "hello", timestamp: now))
        #expect(alert.kind == .finished)
        #expect(alert.answerSpec == nil)
        #expect(alert.deliverySpec == "none")
        #expect(alert.source == "Murmur")
    }
}

@Suite("On-disk log")
struct LogFileTests {
    @Test("An empty file never rotates")
    func emptyDoesNotRotate() {
        #expect(!LogFile.shouldRotate(currentBytes: 0, adding: 10))
        // Not even a line larger than the cap: rotating here would throw away
        // nothing and leave an empty file behind.
        #expect(!LogFile.shouldRotate(currentBytes: 0, adding: LogFile.maxBytes * 2))
    }

    @Test("Rotation happens at the cap, not past it")
    func rotatesAtCap() {
        #expect(!LogFile.shouldRotate(currentBytes: LogFile.maxBytes - 10, adding: 10))
        #expect(LogFile.shouldRotate(currentBytes: LogFile.maxBytes - 10, adding: 11))
        #expect(LogFile.shouldRotate(currentBytes: LogFile.maxBytes, adding: 1))
    }

    /// The whole point of writing to disk is that the file gets sent to
    /// somebody. A token in it would be a worse bug than the one being chased.
    @Test("Secrets never reach the file")
    func redactsSecrets() {
        let line = "12:00:00 · [focus] token ghp_0123456789abcdefghijABCDEFGHIJ0123 used"
        let safe = SecretRedactor.redact(line)
        #expect(!safe.contains("ghp_0123456789abcdefghijABCDEFGHIJ0123"))
        #expect(safe.contains(SecretRedactor.placeholder))
        // The rest of the line survives, or the file is useless.
        #expect(safe.contains("[focus]"))
    }

    @Test("Both generations live under the private root, not the home directory")
    func staysPrivate() {
        #expect(LogFile.url.path.contains(".notchpill/log"))
        #expect(LogFile.previousURL.path.contains(".notchpill/log"))
        #expect(LogFile.url != LogFile.previousURL)
    }
}

@Suite("Scan reconciliation")
struct ScanLedgerTests {
    @Test("A clean scan states the arithmetic and nothing else")
    func allKept() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.keep(); ledger.keep()
        #expect(ledger.summary == "2 transcripts → 2 shown")
        #expect(ledger.dropped == 0)
    }

    @Test("Drops are tallied by reason")
    func tallies() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.keep()
        ledger.drop("sdk-run"); ledger.drop("sdk-run"); ledger.drop("unreadable")
        #expect(ledger.dropped == 3)
        // Commonest reason first — that is the one that explains the surprise.
        #expect(ledger.summary
                == "4 transcripts → 1 shown (3 dropped: sdk-run 2, unreadable 1)")
    }

    /// Dictionary order is not stable, and an unstable summary would make every
    /// scan look like news and flood the buffer.
    @Test("The same scan always renders the same line")
    func summaryIsStable() {
        func build() -> String {
            var l = ScanLedger(unit: "transcripts")
            for r in ["a", "b", "c", "d", "e", "f"] { l.drop(r) }
            return l.summary
        }
        #expect(build() == build())
    }

    @Test("Ties break by name so equal counts stay ordered")
    func tiesAreOrdered() {
        var ledger = ScanLedger(unit: "transcripts")
        ledger.drop("zebra"); ledger.drop("alpha")
        #expect(ledger.summary == "2 transcripts → 0 shown (2 dropped: alpha 1, zebra 1)")
    }

    /// The scan runs every three seconds; logging each one would bury the log
    /// it is meant to improve.
    @Test("An unchanged scan is not news")
    func silentWhenUnchanged() {
        var first = ScanLedger(unit: "transcripts")
        first.keep(); first.drop("sdk-run")
        var same = ScanLedger(unit: "transcripts")
        same.keep(); same.drop("sdk-run")
        var different = ScanLedger(unit: "transcripts")
        different.keep(); different.keep(); different.drop("sdk-run")

        #expect(first.differs(from: nil))
        #expect(!same.differs(from: first))
        #expect(different.differs(from: first))
    }

    @Test("An empty first scan says nothing")
    func emptyIsSilent() {
        #expect(!ScanLedger(unit: "transcripts").differs(from: nil))
    }
}

@Suite("Log filtering")
struct LogFilterTests {
    private func entry(_ category: String, _ message: String) -> LogEntry {
        LogEntry(id: 1, date: Date(), level: .info,
                 category: category, message: message)
    }

    @Test("Search matches message or category, case-insensitively")
    func searchMatches() {
        let e = entry("focus", "com.apple.Terminal is not running")
        #expect(LogView.matches(e, search: ""))
        #expect(LogView.matches(e, search: "terminal"))
        #expect(LogView.matches(e, search: "FOCUS"))
        #expect(!LogView.matches(e, search: "cursor"))
    }

    @Test("Whitespace-only search is not a filter")
    func blankSearch() {
        #expect(LogView.matches(entry("scan", "2 transcripts → 2 shown"), search: "   "))
    }
}

@Suite("Follow-up reminders")
struct FollowUpReminderTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test("Nothing is due before the delay")
    func notDueYet() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        #expect(r.due(now: t0.addingTimeInterval(299)).isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(300)).map(\.id) == ["a"])
    }

    /// The whole point: one nudge. Something that pings until you deal with it
    /// gets ignored wholesale, which costs the peeks worth reading.
    @Test("A reminder never fires twice")
    func remindsOnce() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        let later = t0.addingTimeInterval(600)
        #expect(r.due(now: later).count == 1)
        #expect(r.due(now: later.addingTimeInterval(600)).isEmpty)
        // Nor by re-recording the same id.
        r.recordUnattended(id: "a", kind: .waiting, at: later)
        #expect(r.due(now: later.addingTimeInterval(1200)).isEmpty)
    }

    /// Dismissing is attending: you looked and decided it was not for you.
    @Test("Attending to something cancels its reminder")
    func attendedCancels() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .finished, at: t0)
        r.attended(id: "a")
        #expect(r.due(now: t0.addingTimeInterval(600)).isEmpty)
        #expect(r.pending.isEmpty)
    }

    @Test("Recording the same peek twice queues one reminder")
    func noDuplicates() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        r.recordUnattended(id: "a", kind: .waiting, at: t0.addingTimeInterval(5))
        #expect(r.pending.count == 1)
    }

    /// A prompt from hours ago has almost certainly been answered in the
    /// terminal; raising it would state something false.
    @Test("Stale items expire instead of being raised")
    func expires() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "old", kind: .waiting, at: t0)
        r.expire(now: t0.addingTimeInterval(AgentSession.liveWindow + 1))
        #expect(r.pending.isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(99_999)).isEmpty)
    }

    @Test("Several unattended peeks each get their own reminder")
    func independent() {
        var r = FollowUpReminder()
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        r.recordUnattended(id: "b", kind: .finished, at: t0.addingTimeInterval(120))
        #expect(r.due(now: t0.addingTimeInterval(310)).map(\.id) == ["a"])
        #expect(r.due(now: t0.addingTimeInterval(430)).map(\.id) == ["b"])
    }

    /// An identical second copy of a peek looks like the agent asked twice.
    @Test("A reminder says that it is one")
    func titlesDiffer() {
        #expect(FollowUpReminder.title(for: .waiting) == "Still waiting on you")
        #expect(FollowUpReminder.title(for: .finished) != FollowUpReminder.title(for: .waiting))
    }
}

@Suite("Quiet scenes")
struct QuietSceneTests {
    private func session(locked: Any? = nil, onConsole: Any? = nil) -> () -> [String: Any]? {
        var d: [String: Any] = [:]
        if let locked { d["CGSSessionScreenIsLocked"] = locked }
        if let onConsole { d["kCGSSessionOnConsoleKey"] = onConsole }
        return { d }
    }

    @Test("Locked reads as locked, either spelling")
    func readsLockState() {
        #expect(QuietScene.screenIsLocked(session: session(locked: true)))
        #expect(QuietScene.screenIsLocked(session: session(locked: 1)))
        #expect(!QuietScene.screenIsLocked(session: session(locked: false)))
        #expect(!QuietScene.screenIsLocked(session: session(locked: 0)))
    }

    /// The failure that matters is going silent when we should not have, so an
    /// unreadable session errs towards speaking.
    @Test("An unreadable session speaks rather than going quiet")
    func unknownSpeaks() {
        #expect(!QuietScene.screenIsLocked(session: { nil }))
        #expect(!QuietScene.screenIsLocked(session: session()))
        #expect(QuietScene.onConsole(session: { nil }))
        #expect(!QuietScene.shouldStayQuiet(enabled: true, session: { nil }))
    }

    /// Fast user switching leaves us running behind somebody else's session,
    /// where a peek is invisible at best and over their screen at worst.
    @Test("Another user on the console also means quiet")
    func offConsoleIsQuiet() {
        #expect(QuietScene.shouldStayQuiet(enabled: true,
                                           session: session(locked: false, onConsole: false)))
        #expect(!QuietScene.shouldStayQuiet(enabled: true,
                                            session: session(locked: false, onConsole: true)))
    }

    @Test("Switched off, nothing is ever held back")
    func disabledNeverQuiet() {
        #expect(!QuietScene.shouldStayQuiet(enabled: false,
                                            session: session(locked: true, onConsole: false)))
    }

    @Test("Locked means quiet")
    func lockedIsQuiet() {
        #expect(QuietScene.shouldStayQuiet(enabled: true,
                                           session: session(locked: true, onConsole: true)))
    }
}

@Suite("Reminders do not nudge themselves")
struct FollowUpSelfReferenceTests {
    /// A reminder is presented as an ordinary peek, so when it times out it
    /// would earn a reminder of its own — and that one another, forever. The
    /// original tests could not see this: none of them re-presented a reminder.
    @Test("A reminder that times out earns nothing")
    func reminderIsNotRecorded() {
        var r = FollowUpReminder()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        r.recordUnattended(id: "a", kind: .waiting, at: t0)
        let fired = r.due(now: t0.addingTimeInterval(300))
        #expect(fired.map(\.id) == ["a"])

        // The reminder peek now times out unattended, exactly as the original did.
        r.recordUnattended(id: FollowUpReminder.reminderId(for: "a"), kind: .waiting,
                           at: t0.addingTimeInterval(320))
        #expect(r.pending.isEmpty)
        #expect(r.due(now: t0.addingTimeInterval(9_000)).isEmpty)
    }

    @Test("Reminder ids are recognisable")
    func idsAreLabelled() {
        #expect(FollowUpReminder.isReminder(id: FollowUpReminder.reminderId(for: "x")))
        #expect(!FollowUpReminder.isReminder(id: "x"))
    }
}

/// Reported by a user: a finished Codex peek had a ✕ and nothing else — there
/// was no way to say the next thing without switching back to the terminal by
/// hand. The cause was one predicate doing two jobs. `supportsTypedAnswers`
/// exists to stop us firing Claude Code's `y`/`n` keys at an agent whose
/// approval keymap is different, which is right — but the reply composer was
/// gated on it too, and a free-text paste has no keymap to get wrong.
@Suite("Replying from the notch")
struct NotchReplyCapabilityTests {
    private func alert(agent: String?, bundleId: String?,
                       kind: AlertKind = .finished) -> DevReadyAlert {
        DevReadyAlert(id: "1", title: "murmur-app", source: nil, agent: agent,
                      bundleId: bundleId, kind: kind)
    }

    @Test("a finished Codex peek in a terminal can be replied to")
    @MainActor
    func codexInTerminalCanReply() {
        let a = alert(agent: "codex", bundleId: "com.apple.Terminal")
        #expect(a.canReplyFromNotch(replyEnabled: true))
        // …but still no quick-answer capsules: those keys are Claude Code's.
        #expect(!a.canAnswerFromNotch(replyEnabled: true))
    }

    @Test("every known terminal host can receive a reply")
    @MainActor
    func terminalHostsCanReply() {
        for bundleId in DevReadyAlert.terminalHostBundleIds {
            #expect(alert(agent: "codex", bundleId: bundleId)
                .canReplyFromNotch(replyEnabled: true),
                    "expected \(bundleId) to accept a reply")
        }
    }

    // GUI agent windows now accept a reply — they have a composer like any
    // other app. The risk that kept them out, a paste landing in whatever view
    // holds focus, is handled by not submitting it: see `submitsOnDelivery`.
    @Test("GUI agent windows accept a typed reply, unsubmitted")
    @MainActor
    func guiHostsAcceptButDoNotSubmit() {
        let codex = alert(agent: "codex", bundleId: "com.openai.codex")
        let cursor = alert(agent: "cursor", bundleId: "com.todesktop.230313mzl4w4u92")
        #expect(codex.canReplyFromNotch(replyEnabled: true))
        #expect(cursor.canReplyFromNotch(replyEnabled: true))
        #expect(!codex.submitsOnDelivery)
        #expect(!cursor.submitsOnDelivery)
    }

    @Test("a reply needs somewhere to go")
    @MainActor
    func noTargetNoReply() {
        #expect(!alert(agent: "claude-code", bundleId: nil)
            .canReplyFromNotch(replyEnabled: true))
        #expect(!alert(agent: "claude-code", bundleId: "com.apple.Terminal")
            .canReplyFromNotch(replyEnabled: false))
    }

    // The row draws the ↰ beside the ✕; if the width budget does not know that,
    // the control is paid for out of the title, which truncates.
    @Test("a replyable row is budgeted the width of its reply control")
    @MainActor
    func widthCoversReplyControl() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 900, designExpandedHeight: 190,
                                   scale: 1.0, topGap: 10)
        let title = String(repeating: "n", count: 40)
        let replyable = DevReadyAlert(id: "1", title: title, agent: "codex",
                                      bundleId: "com.apple.Terminal", kind: .finished)
        // An agent that has declared it cannot be answered: the one remaining
        // case with no ↰, now that desktop agents draw one.
        let plain = DevReadyAlert(id: "2", title: title, agent: "cursor",
                                  bundleId: "com.todesktop.230313mzl4w4u92", kind: .finished,
                                  deliverySpec: "none")
        let wide = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [replyable],
                                                     answerEnabled: true)
        let narrow = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [plain],
                                                       answerEnabled: true)
        #expect(wide.size.width - narrow.size.width == NotchContentLayout.replyControlWidth)
    }
}

/// `NSRunningApplication.activate` returns `true` from a background accessory
/// app while the frontmost application never changes — measured on macOS 26
/// from an LSUIElement bundle. Two features were built on that return value and
/// both failed silently: tap-to-jump returned early and did nothing, and every
/// reply aborted with `.focusTimeout` after waiting for a handoff that was
/// never going to happen.
@Suite("Bringing another app forward")
struct AppActivatorTests {
    @Test("addresses the app by bundle id, not by name")
    func scriptUsesBundleId() {
        let script = AppActivator.activateScript(bundleId: "com.apple.Terminal")
        #expect(script == "tell application id \"com.apple.Terminal\" to activate")
        // A localised or duplicated app *name* resolves to the wrong app; an id
        // cannot.
        #expect(script?.contains("\"Terminal\" to activate") != true)
    }

    // Bundle ids arrive in hook payloads, so they are untrusted, and they end up
    // inside an AppleScript string literal. Escaping quotes is not enough — a
    // raw newline cannot live in an AppleScript string at all — so anything that
    // is not a bundle identifier is refused outright rather than repaired.
    @Test("a malformed bundle id is refused, not escaped")
    func scriptRefusesInjection() {
        #expect(AppActivator.activateScript(
            bundleId: "com.evil\" to quit\ntell application \"Finder") == nil)
        #expect(AppActivator.activateScript(bundleId: "com.evil\" to quit") == nil)
        #expect(AppActivator.activateScript(bundleId: "with space") == nil)
        #expect(AppActivator.activateScript(bundleId: "") == nil)
        // Real ids still pass.
        for id in ["com.apple.Terminal", "dev.warp.Warp-Stable", "com.local.notchpill"] {
            #expect(AppActivator.isValidBundleId(id), "expected \(id) to be accepted")
        }
    }

    @Test("an empty bundle id is refused rather than guessed at")
    @MainActor
    func emptyIsRefused() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "", frontmost: { "com.other" }) { c.resume(returning: $0) }
        }
        #expect(result == false)
    }

    @Test("an app already in front needs no activation at all")
    @MainActor
    func alreadyFrontIsInstant() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "com.apple.Terminal",
                                  frontmost: { "com.apple.Terminal" }) { c.resume(returning: $0) }
        }
        #expect(result)
    }

    // The whole point: focus is decided by observing `frontmostApplication`,
    // never by a return value. An app that never comes forward must report
    // failure so the caller can escalate or tell the user — silently believing
    // it worked is what shipped the two broken features.
    @Test("an app that never comes forward reports failure")
    @MainActor
    func neverFrontmostFails() async {
        let result = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            AppActivator.activate(bundleId: "com.local.definitely-not-installed",
                                  frontmost: { "com.cmuxterm.app" }) { c.resume(returning: $0) }
        }
        #expect(result == false)
    }

    @Test("every strategy is tried before giving up")
    func escalationOrder() {
        // Cheapest first: the Apple Event costs a round trip and can raise a
        // one-time Automation prompt, so it is not tried until the free call
        // has been shown not to work.
        #expect(AppActivator.Strategy.allCases.map(\.rawValue)
                == ["direct", "appleScript", "launchServices"])
    }
}

/// Reported: Codex was running and the notch listed only Cursor.
///
/// A Codex row is named from `cwd` in the transcript's first record, and the
/// scanner used to `guard let project = … else { return nil }` — so when that
/// lookup failed the whole session was discarded. Desktop Codex writes its base
/// instructions into that first record, large enough to push `cwd` past the
/// read window, which made the agent most likely to hit it also the one that
/// vanished.
@Suite("Naming a session never hides it")
struct SessionNamingTests {
    @Test("an unnamed session still says which agent it is")
    func fallbackNamesTheAgent() {
        #expect(AgentSessionScanner.fallbackProjectName(isCodex: true) == "Codex")
        #expect(AgentSessionScanner.fallbackProjectName(isCodex: false) == "Claude Code")
    }

    // The regression itself: cwd sitting beyond the old 32KB window.
    @Test("cwd is found past the old read window")
    func cwdSurvivesHugeFirstRecord() {
        let filler = String(repeating: "x", count: 120_000)
        let head = #"{"payload":{"instructions":"\#(filler)"}}"#
        let second = #"{"payload":{"cwd":"/Users/me/murmur-app"}}"#
        let text = head + "\n" + second
        #expect(text.utf8.count > 32_768)
        #expect(text.utf8.count < AgentSessionScanner.metadataReadWindow)
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/murmur-app")
    }

    @Test("the read window grew past desktop Codex's first record")
    func windowIsLargeEnough() {
        #expect(AgentSessionScanner.metadataReadWindow >= 262_144)
    }

    @Test("cwd is still recovered from a record cut off mid-field")
    func partialRecordStillYieldsCwd() {
        // A truncated first record: valid JSON never closes, so structured
        // decoding fails and only the textual recovery can find cwd.
        let text = #"{"payload":{"cwd":"/Users/me/proj","instructions":"blah blah"#
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/proj")
    }
}

/// Codex subscription usage read from OpenAI with the token Codex already
/// stored at login. Fixtures are the real response shape, captured from a live
/// call on this machine (identifiers replaced).
