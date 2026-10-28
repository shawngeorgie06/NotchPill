import Testing
import Foundation
@testable import NotchPill

@Suite("Usage pace, freshness and agent colour")
struct UsageReadingTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func paceIsHowFarThroughTheWindow() throws {
        // Two of five hours left: three fifths through.
        let elapsed = try #require(UsagePace.elapsed(resetsAt: now.addingTimeInterval(2 * 3600),
                                                     length: UsagePace.claudeSession, now: now))
        #expect(abs(elapsed - 0.6) < 0.0001)
    }

    @Test func paceIsUnknownOutsideTheWindow() {
        // Already renewed, further off than the window lasts, or no length.
        #expect(UsagePace.elapsed(resetsAt: now.addingTimeInterval(-1), length: 3600, now: now) == nil)
        #expect(UsagePace.elapsed(resetsAt: now.addingTimeInterval(7200), length: 3600, now: now) == nil)
        #expect(UsagePace.elapsed(resetsAt: now.addingTimeInterval(60), length: nil, now: now) == nil)
        #expect(UsagePace.elapsed(resetsAt: nil, length: 3600, now: now) == nil)
    }

    @Test func billingCyclePace() throws {
        let start = now.addingTimeInterval(-10 * 86_400)
        let end = now.addingTimeInterval(20 * 86_400)
        let elapsed = try #require(UsagePace.elapsed(start: start, end: end, now: now))
        #expect(abs(elapsed - 1.0 / 3) < 0.0001)
        #expect(UsagePace.elapsed(start: end, end: start, now: now) == nil)
    }

    @Test func aheadOnlyPastARoundingPoint() {
        #expect(UsagePace.isAhead(percent: 70, elapsed: 0.5))
        #expect(!UsagePace.isAhead(percent: 50, elapsed: 0.5))
        #expect(!UsagePace.isAhead(percent: 51, elapsed: 0.5))
        #expect(!UsagePace.isAhead(percent: 30, elapsed: 0.5))
    }

    @Test func staleAfterTenMinutes() {
        #expect(!UsageFreshness.isStale(now.addingTimeInterval(-60), now: now))
        #expect(UsageFreshness.isStale(now.addingTimeInterval(-11 * 60), now: now))
        // No timestamp is not evidence of age.
        #expect(!UsageFreshness.isStale(nil, now: now))
    }

    @Test func meterKeepsAgentColourUntilLow() {
        #expect(AgentTint.meter(percent: 40, agent: AgentTint.codex) == AgentTint.codex.opacity(0.85))
        #expect(AgentTint.meter(percent: 75, agent: AgentTint.codex)
                == NotchDesign.devReadyAmber.opacity(0.75))
        #expect(AgentTint.meter(percent: 95, agent: AgentTint.claude)
                == NotchDesign.devReadyAmber.opacity(0.95))
    }

    @Test func eachAgentHasItsColour() {
        #expect(AgentTint.color(for: .claudeCode) == AgentTint.claude)
        #expect(AgentTint.color(for: .codex) == AgentTint.codex)
        #expect(AgentTint.color(for: nil) == nil)
        #expect(AgentTint.color(forTool: TokenUsageSummary.codex) == AgentTint.codex)
        #expect(AgentTint.color(forTool: TokenUsageSummary.claude) == AgentTint.claude)
    }
}

@Suite("Usage window lengths and cycle starts")
struct UsageWindowParsingTests {
    @Test func transcriptWindowsCarryTheirLength() throws {
        let transcript = #"{"timestamp":"2026-10-28T02:34:30.115Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"window_minutes":300,"resets_at":1800000000},"secondary":{"used_percent":40.0,"window_minutes":10080,"resets_at":1800300000}}}}"#
        let quota = try #require(AgentSessionScanner.codexQuota(in: transcript))
        #expect(quota.sessionWindow == TimeInterval(18_000))
        #expect(quota.weeklyWindow == TimeInterval(604_800))
        // Millisecond stamps used to be rejected, leaving the reading ageless.
        #expect(quota.updatedAt == CodexUsageFetcher.parseTimestamp("2026-10-28T02:34:30.115Z"))
        #expect(quota.updatedAt != nil)
    }

    @Test func apiWindowsCarryTheirLength() throws {
        let payload = #"{"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1800300000}}}"#
        let quota = try #require(CodexUsageFetcher.quota(in: Data(payload.utf8)))
        #expect(quota.sessionWindow == TimeInterval(18_000))
        #expect(quota.weeklyWindow == TimeInterval(604_800))
    }

    @Test func missingOrZeroLengthIsUnknown() {
        #expect(CodexUsageFetcher.window(in: ["used_percent": 10.0])?.length == nil)
        #expect(CodexUsageFetcher.window(in: ["used_percent": 10.0, "window_minutes": 0])?.length == nil)
    }

    @Test func cursorCycleStartIsParsedAndRestored() throws {
        let payload = #"{"billingCycleStart":"2026-07-16T20:05:08.000Z","billingCycleEnd":"2026-08-16T20:05:08.000Z","membershipType":"pro","isUnlimited":false,"individualUsage":{"plan":{"enabled":true,"used":100,"limit":2000,"totalPercentUsed":5}}}"#
        let quota = try #require(CursorUsageFetcher.quota(in: Data(payload.utf8)))
        let start = try #require(CursorUsageFetcher.parseTimestamp("2026-07-16T20:05:08.000Z"))
        #expect(quota.cycleStart == start)

        let suite = "notchpill.tests.cursor-cycle-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        store.set(["used": 100, "limit": 2000, "percent": 5, "at": 1_800_000_000.0,
                   "cycleStart": start.timeIntervalSince1970],
                  forKey: CursorUsageService.cacheKey)
        #expect(CursorUsageService.restore(from: store)?.cycleStart == start)
    }
}

@Suite("Turn length for finished peeks")
struct TurnStartTests {
    private func lines(_ records: [String]) -> String { records.joined(separator: "\n") }

    @Test func claudeTurnStartsAtTheLastRealPrompt() {
        let transcript = lines([
            #"{"type":"user","timestamp":"2026-10-28T02:50:00.000Z","message":{"role":"user","content":"earlier prompt"}}"#,
            #"{"type":"user","timestamp":"2026-10-28T02:57:05.676Z","message":{"role":"user","content":[{"type":"text","text":"work on 2-6"}]}}"#,
            #"{"type":"assistant","timestamp":"2026-10-28T02:57:10.000Z","message":{"content":[{"type":"tool_use","id":"t1"}]}}"#,
            // A tool result is written as a user record, but nobody typed it.
            #"{"type":"user","timestamp":"2026-10-28T02:58:00.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1"}]}}"#,
            // Nor did anybody type harness-injected context.
            #"{"type":"user","isMeta":true,"timestamp":"2026-10-28T02:58:30.000Z","message":{"role":"user","content":"caveat"}}"#,
            #"{"type":"assistant","timestamp":"2026-10-28T03:04:00.000Z","message":{"content":[{"type":"text","text":"done"}]}}"#,
        ])
        #expect(AgentSessionScanner.turnStart(in: transcript, isCodex: false)
                == CodexUsageFetcher.parseTimestamp("2026-10-28T02:57:05.676Z"))
    }

    @Test func codexTurnStartsAtTaskStarted() {
        let transcript = lines([
            #"{"timestamp":"2026-10-28T02:30:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-28T02:34:30.115Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            #"{"timestamp":"2026-10-28T02:34:30.200Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"go"}]}}"#,
            #"{"timestamp":"2026-10-28T02:40:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"ok"}]}}"#,
        ])
        // The user message right after task_started is the same turn; either
        // is within a fraction of a second of the other.
        let start = AgentSessionScanner.turnStart(in: transcript, isCodex: true)
        #expect(start == CodexUsageFetcher.parseTimestamp("2026-10-28T02:34:30.200Z"))
    }

    @Test func codexFallsBackToTheUserMessage() {
        let transcript = #"{"timestamp":"2026-10-28T02:34:30Z","type":"response_item","payload":{"type":"message","role":"user","content":[]}}"#
        #expect(AgentSessionScanner.turnStart(in: transcript, isCodex: true)
                == CodexUsageFetcher.parseTimestamp("2026-10-28T02:34:30Z"))
    }

    @Test func noPromptMeansNoStart() {
        let transcript = #"{"type":"assistant","timestamp":"2026-10-28T03:04:00.000Z","message":{"content":[]}}"#
        #expect(AgentSessionScanner.turnStart(in: transcript, isCodex: false) == nil)
        #expect(AgentSessionScanner.turnStart(in: "not json", isCodex: true) == nil)
    }

    @Test func quickTurnsAreOnlyThoseKnownToBeShort() {
        let end = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(NotchController.isQuickTurn(startedAt: end.addingTimeInterval(-10),
                                            finishedAt: end, minimum: 60))
        #expect(!NotchController.isQuickTurn(startedAt: end.addingTimeInterval(-90),
                                             finishedAt: end, minimum: 60))
        // Unknown start, filter off, or a clock that runs backwards: show it.
        #expect(!NotchController.isQuickTurn(startedAt: nil, finishedAt: end, minimum: 60))
        #expect(!NotchController.isQuickTurn(startedAt: end.addingTimeInterval(-10),
                                             finishedAt: end, minimum: 0))
        #expect(!NotchController.isQuickTurn(startedAt: end.addingTimeInterval(10),
                                             finishedAt: end, minimum: 60))
    }
}

@Suite("Usage history")
struct UsageHistoryTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 1
        return c
    }

    /// Wednesday 28 October 2026, midday UTC.
    private let now = Date(timeIntervalSince1970: 1_793_188_800)

    @Test func lastDaysEndToday() {
        let days = UsageHistory(daily: [:]).lastDays(14, now: now, calendar: calendar)
        #expect(days.count == 14)
        #expect(days.last == calendar.startOfDay(for: now))
        #expect(days.first == calendar.date(byAdding: .day, value: -13, to: calendar.startOfDay(for: now)))
    }

    @Test func gridEndsWithThisWeekAndHidesTheFuture() throws {
        let grid = UsageHistory(daily: [:]).grid(now: now, calendar: calendar)
        #expect(grid.count == UsageHistory.weeks)
        #expect(grid.allSatisfy { $0.count == 7 })
        let first = try #require(grid.first?.first ?? nil)
        #expect(first == UsageHistory.firstDay(now: now, calendar: calendar))
        #expect(calendar.component(.weekday, from: first) == 1)
        // Sunday 25th to Wednesday 28th shown, Thursday on is not.
        let thisWeek = try #require(grid.last)
        #expect(thisWeek.compactMap { $0 }.count == 4)
        #expect(thisWeek[3] == calendar.startOfDay(for: now))
        #expect(thisWeek[4] == nil)
    }

    @Test func shadingSplitsUsedDaysIntoQuartiles() {
        let values = [0, 10, 20, 30, 40, 1_000_000]
        #expect(UsageHistory.level(0, among: values) == 0)
        #expect(UsageHistory.level(10, among: values) == 1)
        #expect(UsageHistory.level(1_000_000, among: values) == 4)
        // One enormous day does not flatten the rest to the faintest shade.
        #expect(UsageHistory.level(30, among: values) == 2)
        #expect(UsageHistory.level(40, among: values) == 3)
        #expect(UsageHistory.level(5, among: []) == 0)
    }

    @Test func emptyHistoryShowsNoCard() {
        #expect(UsageHistory(daily: [:]).isEmpty)
        #expect(UsageHistory(daily: ["2026-10-28": [TokenUsageSummary.claude: 0]]).isEmpty)
        let history = UsageHistory(daily: ["2026-10-28": [TokenUsageSummary.claude: 5]])
        #expect(!history.isEmpty)

        func kinds(_ history: UsageHistory?, agents: Bool) -> [String] {
            ExpandedActivityBuilder.activities(
                nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
                systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
                usageHistory: history,
                showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
                showCalendar: false, showTimer: false, showSystemStats: false,
                showBattery: false, showShelf: false, showAgents: agents).map(\.kind)
        }
        #expect(kinds(history, agents: true).contains("usageHistory"))
        #expect(!kinds(history, agents: false).contains("usageHistory"))
        #expect(!kinds(UsageHistory(daily: [:]), agents: true).contains("usageHistory"))
        #expect(ExpandedActivity.allKinds.contains { $0.kind == "usageHistory" })
        #expect(ExpandedActivity.usageHistory(history).kindLabel == "Usage history")
    }
}

@Suite("Review fixes: Codex day split and filtered dedup")
struct AgentUsageReviewFixTests {
    /// A resumed Codex session reports one running total. Yesterday's work
    /// must stay on yesterday, and today gets only what today added.
    @Test func codexTotalsSplitAcrossDays() throws {
        let yesterday = "2026-08-23T12:00:00.000Z"
        let today = "2026-08-24T12:00:00.000Z"
        let text = """
        {"timestamp":"\(yesterday)","payload":{"type":"session_meta","model":"gpt-6.1-sol"}}
        {"timestamp":"\(yesterday)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":900,"output_tokens":100}}}}
        {"timestamp":"\(today)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":905,"output_tokens":105}}}}
        """
        let buckets = TokenLedger.codexBuckets(in: text)
        let dayA = try #require(TokenLedger.day(from: yesterday))
        let dayB = try #require(TokenLedger.day(from: today))
        #expect(buckets[dayA]?["gpt-6.1-sol"]?.total == 1_000)
        #expect(buckets[dayB]?["gpt-6.1-sol"]?.total == 10)
    }

    private static func record(_ day: String, _ input: Int) -> String {
        "{\"timestamp\":\"\(day)T12:00:00.000Z\",\"payload\":{\"type\":\"token_count\","
            + "\"info\":{\"total_token_usage\":{\"input_tokens\":\(input)}}}}"
    }

    /// Every record counts, middle days included, and reading a transcript in
    /// two pieces gives the same answer as reading it whole.
    @Test func codexReadsContinueAcrossChunks() throws {
        let first = [Self.record("2026-08-22", 300)].joined(separator: "\n")
        let rest = [Self.record("2026-08-23", 500), Self.record("2026-08-23", 700),
                    Self.record("2026-08-24", 1_000)].joined(separator: "\n")
        let whole = TokenLedger.codexBuckets(in: first + "\n" + rest)
        let (a, progress) = TokenLedger.codexBuckets(in: first, continuing: .init())
        let (b, _) = TokenLedger.codexBuckets(in: rest, continuing: progress)
        #expect(TokenLedger.merge(a, b) == whole)
        let days = ["2026-08-22", "2026-08-23", "2026-08-24"]
            .map { TokenLedger.day(from: "\($0)T12:00:00.000Z") }
        #expect(days.map { whole[$0 ?? ""]?["codex"]?.input } == [300, 400, 300])
    }

    /// A total that restarts partway through a day keeps the work done
    /// before the restart.
    @Test func aRestartWithinADayKeepsEarlierWork() throws {
        let text = [Self.record("2026-08-23", 1_000), Self.record("2026-08-24", 1_200),
                    Self.record("2026-08-24", 50)].joined(separator: "\n")
        let today = try #require(TokenLedger.day(from: "2026-08-24T12:00:00.000Z"))
        #expect(TokenLedger.codexBuckets(in: text)[today]?["codex"]?.input == 250)
    }

    @Test func aRestartedTotalCountsAsFreshWork() {
        let earlier = TokenTally(input: 500, output: 50)
        let restarted = TokenTally(input: 20, output: 60)
        let grown = restarted.growth(since: earlier)
        #expect(grown.input == 20)
        #expect(grown.output == 10)
    }

    /// Checking a peek against dedup before the turn filter has decided must
    /// not record it: a dropped Claude turn would otherwise silence the host
    /// app's own peek for the same turn.
    @Test func probingDedupRecordsNothing() {
        var dedup = DevReadyDedup()
        let claude = DevReadyAlert(title: "bid-no-bid", subtitle: "finished · main",
                                   source: "Cursor", agent: "claude-code",
                                   bundleId: "com.todesktop.230313mzl4w4u92",
                                   sessionId: "1573ad8b")
        let cursor = DevReadyAlert(title: "Question for you", subtitle: "regenerate the memo?",
                                   source: "Cursor", agent: "cursor",
                                   bundleId: "com.todesktop.230313mzl4w4u92")
        #expect(dedup.wouldSuppress(claude) == false)
        #expect(dedup.shouldSuppress(cursor) == false)
        #expect(dedup.shouldSuppress(claude) == true)
    }
}
