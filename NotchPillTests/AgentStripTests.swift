import Foundation
import Testing
@testable import NotchPill

@Suite("Agent strip")
struct AgentStripTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ agent: String, _ state: AgentSession.State, ago: TimeInterval = 0,
                         alive: Bool? = nil) -> AgentSession {
        var s = AgentSession(id: UUID().uuidString, agent: agent, project: "p", state: state,
                             lastActivity: now.addingTimeInterval(-ago))
        s.isAlive = alive
        return s
    }

    private func claude(session: Int, week: Int, updated: TimeInterval = 0,
                        sessionResets: TimeInterval = 3600) -> ClaudeQuota {
        var q = ClaudeQuota(sessionPercent: session, weeklyPercent: week)
        q.sessionResetsAt = now.addingTimeInterval(sessionResets)
        q.weeklyResetsAt = now.addingTimeInterval(86_400)
        q.updatedAt = now.addingTimeInterval(-updated)
        return q
    }

    private func codex(_ percent: Int, weekly: Int? = nil, updated: TimeInterval = 0) -> CodexQuota {
        CodexQuota(usedPercent: percent, resetsAt: now.addingTimeInterval(3600),
                   weeklyPercent: weekly, weeklyResetsAt: now.addingTimeInterval(86_400),
                   creditBalance: nil, updatedAt: now.addingTimeInterval(-updated))
    }

    private func cursor(_ percent: Int, unlimited: Bool = false,
                        auto: Int? = nil, api: Int? = nil) -> CursorQuota {
        CursorQuota(used: percent, limit: 100, included: nil, bonus: nil, percentUsed: percent,
                    autoPercentUsed: auto, apiPercentUsed: api,
                    cycleEnd: now.addingTimeInterval(86_400), membership: nil,
                    isUnlimited: unlimited, onDemandEnabled: false, updatedAt: now)
    }

    private func resolve(_ sessions: [AgentSession], claude: ClaudeQuota? = nil,
                         codex: CodexQuota? = nil, cursor: CursorQuota? = nil,
                         reading: AgentStrip.ReadingKind = .tightestLimit) -> AgentStrip? {
        AgentStrip.resolve(sessions: sessions, claude: claude, codex: codex, cursor: cursor,
                           readingKind: reading, now: now)
    }

    @Test("no strip while every agent is idle, finished, or dead")
    func hiddenWhenNothingIsActive() {
        #expect(resolve([]) == nil)
        #expect(resolve([session("codex", .idle(since: now)),
                         session("claude-code", .completed(since: now)),
                         session("cursor", .working, alive: false)]) == nil)
    }

    @Test("a waiting agent wins over a more recent working one")
    func waitingWins() {
        let strip = resolve([session("codex", .working, ago: 0),
                             session("claude-code", .waiting(since: nil), ago: 120)])
        #expect(strip?.agent == .claudeCode)
        #expect(strip?.isWaiting == true)
        #expect(strip?.activeCount == 2)
    }

    @Test("among working agents the most recent wins")
    func mostRecentWorking() {
        let strip = resolve([session("codex", .working, ago: 60),
                             session("cursor", .working, ago: 5)])
        #expect(strip?.agent == .cursor)
        #expect(strip?.isWaiting == false)
    }

    @Test("tightest limit looks across every agent")
    func tightestAcrossAgents() {
        let strip = resolve([session("claude-code", .working)],
                            claude: claude(session: 20, week: 41),
                            codex: codex(12, weekly: 77),
                            cursor: cursor(30))
        #expect(strip?.reading == .limit(.init(agent: .codex, percent: 77, isStale: false)))
    }

    @Test("this agent's limit ignores the others")
    func agentLimitOnly() {
        let strip = resolve([session("claude-code", .working)],
                            claude: claude(session: 20, week: 41),
                            codex: codex(90), reading: .agentLimit)
        #expect(strip?.reading == .limit(.init(agent: .claudeCode, percent: 41, isStale: false)))
        // OpenCode has no plan to read, so the wing stays empty.
        #expect(resolve([session("opencode", .working)], codex: codex(90),
                        reading: .agentLimit)?.reading == nil)
    }

    @Test("a fresh reading beats a higher stale one, and stale shows only as a fallback")
    func freshBeatsStale() {
        let stale = UsageFreshness.staleAfter + 60
        let mixed = resolve([session("codex", .working)],
                            claude: claude(session: 95, week: 10, updated: stale),
                            codex: codex(40))
        #expect(mixed?.reading == .limit(.init(agent: .codex, percent: 40, isStale: false)))
        let onlyStale = resolve([session("codex", .working)],
                                claude: claude(session: 95, week: 10, updated: stale))
        #expect(onlyStale?.reading == .limit(.init(agent: .claudeCode, percent: 95, isStale: true)))
    }

    @Test("a window whose reset has passed is not shown")
    func resetWindowDropped() {
        let strip = resolve([session("claude-code", .working)],
                            claude: claude(session: 93, week: 12, sessionResets: -60))
        #expect(strip?.reading == .limit(.init(agent: .claudeCode, percent: 12, isStale: false)))
    }

    @Test("an unlimited Cursor plan has no limit to show")
    func unlimitedCursorSkipped() {
        #expect(AgentStrip.usageWindows(claude: nil, codex: nil, cursor: cursor(80, unlimited: true),
                                        now: now).isEmpty)
    }

    @Test("Cursor's auto and API pools count on their own")
    func cursorPools() {
        let strip = resolve([session("cursor", .working)], codex: codex(60),
                            cursor: cursor(30, auto: 12, api: 95))
        #expect(strip?.reading == .limit(.init(agent: .cursor, percent: 95, isStale: false)))
        let own = resolve([session("cursor", .working)], codex: codex(60),
                          cursor: cursor(30, auto: 12, api: 95), reading: .agentLimit)
        #expect(own?.reading == .limit(.init(agent: .cursor, percent: 95, isStale: false)))
    }

    @Test("the same quota reads differently once time passes its reset or freshness")
    func readingAgesWithTime() {
        let sessions = [session("claude-code", .working)]
        let quota = claude(session: 80, week: 10)
        let later = now.addingTimeInterval(3600 + 60)
        let aged = AgentStrip.resolve(sessions: sessions, claude: quota, codex: nil, cursor: nil,
                                      readingKind: .tightestLimit, now: later)
        // The session window reset at +1h; only the stale weekly reading remains.
        #expect(aged?.reading == .limit(.init(agent: .claudeCode, percent: 10, isStale: true)))
    }

    @Test("on a tie the agent being shown wins")
    func tiePrefersShownAgent() {
        let strip = resolve([session("cursor", .working)], codex: codex(50), cursor: cursor(50))
        #expect(strip?.reading == .limit(.init(agent: .cursor, percent: 50, isStale: false)))
    }

    @Test("count and nothing readings")
    func otherReadings() {
        let sessions = [session("codex", .working), session("cursor", .waiting(since: nil))]
        #expect(resolve(sessions, reading: .activeCount)?.reading == .count(2))
        #expect(resolve(sessions, codex: codex(80), reading: .none)?.reading == nil)
    }

    @Test("wings widen the closed pill just past notch height, chips keep their own height")
    func layout() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 1.0)
        let wing = NotchContentLayout.agentStripWingWidth
        let alone = NotchContentLayout.collapsedLayout(metrics: m, chips: [], showsAgentStrip: true)
        #expect(alone.size == CGSize(width: 180 + 2 * wing, height: 32 + NotchContentLayout.agentStripExtraHeight))
        let off = NotchContentLayout.collapsedLayout(metrics: m, chips: [], showsAgentStrip: false)
        #expect(off.size == m.collapsedSize)
        let chipsOnly = NotchContentLayout.collapsedLayout(metrics: m, chips: [.clock])
        let both = NotchContentLayout.collapsedLayout(metrics: m, chips: [.clock], showsAgentStrip: true)
        #expect(both.size.height == chipsOnly.size.height)
        #expect(both.size.width == max(chipsOnly.size.width, 180 + 2 * wing))
        #expect(both.readability == chipsOnly.readability)
    }

    @Test("every known agent's logo lookup shares one table")
    func logoTable() {
        #expect(AgentSession(id: "a", agent: "cursor", project: "", state: .working,
                             lastActivity: now).iconBundleIds
                == DevReadyAlert.KnownAgent.cursor.iconBundleIds)
        #expect(DevReadyAlert.KnownAgent.openCode.iconBundleIds.isEmpty)
        #expect(DevReadyAlert.KnownAgent.claudeCode.bundledMark == "ClaudeMark")
        #expect(DevReadyAlert.KnownAgent.codex.bundledMark == nil)
    }
}
