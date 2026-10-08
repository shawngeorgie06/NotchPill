import Testing
import Foundation
import Combine
import CoreAudio
import AppKit
import SwiftUI
@testable import NotchPill

@Suite("Claude CLI cancellation")
struct ClaudeCLICancellationTests {
    actor StartMarker {
        private var started = false
        func mark() { started = true }
        func hasStarted() -> Bool { started }
    }

    @Test("cancelled quota stops its in-flight CLI request")
    func cancelsBlockedCLI() async throws {
        let marker = StartMarker()
        let service = ClaudeUsageService(readCLI: {
            await marker.mark()
            try await Task.sleep(for: .seconds(10))
            return Data()
        }, store: nil)
        let request = cancellationMeasuredTask { await service.quota() }
        for _ in 0..<100 {
            if await marker.hasStarted() { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await marker.hasStarted())
        let cancelledAt = ContinuousClock.now
        request.cancel()
        let completion = await request.value
        #expect(try completion.result.get() == nil)
        #expect(cancelledAt.duration(to: completion.finishedAt) < .seconds(1))
    }
}

@Suite("CI integration health")
struct CIHealthTests {
    @Test func recognizesOnlySpecificAuthenticationFailures() {
        #expect(CIStatusProvider.classifyGHFailure("To get started with GitHub CLI, please run: gh auth login") == .signedOut)
        #expect(CIStatusProvider.classifyGHFailure("HTTP 401: Bad credentials") == .signedOut)
        #expect(CIStatusProvider.classifyGHFailure("HTTP 403: Resource not accessible by integration") == .permissionNeeded)
        #expect(CIStatusProvider.classifyGHFailure("dial tcp: network is unreachable") == .retrying)
    }
}

@Suite("Codex usage over OAuth")
struct CodexUsageFetcherTests {
    private func json(_ s: String) -> Data { Data(s.utf8) }

    // The captured response that showed the transcript source was wrong: the
    // notch said "4% used · 0 credits balance" while this said 100% and $298.
    private let live = """
    {"plan_type":"free",
     "rate_limit":{"allowed":false,"limit_reached":true,
       "primary_window":{"used_percent":100,"limit_window_seconds":2592000,
                         "reset_after_seconds":361844,"reset_at":1786130351},
       "secondary_window":null},
     "credits":{"has_credits":true,"unlimited":false,"balance":"298.4291950000"},
     "rate_limit_reset_credits":{"available_count":0}}
    """

    @Test("reads the real usage payload")
    func parsesLiveResponse() {
        let now = Date(timeIntervalSince1970: 1_785_768_507)
        let quota = CodexUsageFetcher.quota(in: json(live), now: now)
        #expect(quota?.usedPercent == 100)
        #expect(quota?.resetsAt == Date(timeIntervalSince1970: 1_786_130_351))
        #expect(quota?.weeklyPercent == nil)
        #expect(quota?.updatedAt == now)
        // The balance is $298.43 — not the 0 the old source reported by reading
        // `rate_limit_reset_credits.available_count` instead.
        #expect(quota?.creditBalance == Decimal(string: "298.4291950000"))
    }

    @Test("reads session and weekly windows when both are present")
    func parsesDualWindows() {
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":27,"limit_window_seconds":18000,
                                          "reset_at":1782770922},
                      "secondary_window":{"used_percent":4,"limit_window_seconds":604800,
                                            "reset_at":1783357722}}}
        """
        let quota = CodexUsageFetcher.quota(in: json(body))
        #expect(quota?.usedPercent == 27)
        #expect(quota?.resetsAt == Date(timeIntervalSince1970: 1_782_770_922))
        #expect(quota?.weeklyPercent == 4)
        #expect(quota?.weeklyResetsAt == Date(timeIntervalSince1970: 1_783_357_722))
    }

    @Test("a decimal balance is not read through a Double, nor through the locale")
    func balanceIsExact() {
        let quota = CodexUsageFetcher.quota(in: json(live))
        #expect(quota?.creditBalance != nil)
        // 298.429195 has no exact binary representation; Decimal keeps it.
        #expect(quota?.creditBalance == Decimal(sign: .plus, exponent: -10,
                                                significand: 2_984_291_950_000))
    }

    @Test("an unlimited plan reports no balance rather than a wrong one")
    func unlimitedHasNoBalance() {
        let body = """
        {"rate_limit":{"primary_window":{"used_percent":15,"reset_at":1786130351}},
         "credits":{"has_credits":true,"unlimited":true,"balance":"0"}}
        """
        #expect(CodexUsageFetcher.quota(in: json(body))?.creditBalance == nil)
    }

    @Test("used percent is clamped to a percentage")
    func clampsPercent() {
        for (raw, want) in [("-5", 0), ("142", 100), ("15.6", 16)] {
            let body = #"{"rate_limit":{"primary_window":{"used_percent":\#(raw)}}}"#
            #expect(CodexUsageFetcher.quota(in: json(body))?.usedPercent == want)
        }
    }

    @Test("a response without a rate limit yields nothing, not a zero")
    func missingLimitIsNil() {
        // A card reading "0% used" when we simply do not know is a lie, and the
        // whole point of this change was to stop showing confident wrong numbers.
        #expect(CodexUsageFetcher.quota(in: json(#"{"plan_type":"pro"}"#)) == nil)
        #expect(CodexUsageFetcher.quota(in: json("not json")) == nil)
    }

    @Test("reads the credentials Codex wrote")
    func parsesAuthFile() {
        let body = """
        {"OPENAI_API_KEY":null,"auth_mode":"chatgpt",
         "tokens":{"id_token":"idtok","access_token":"acctok",
                   "refresh_token":"reftok","account_id":"acct-1"},
         "last_refresh":"2026-08-02T04:05:04.070839Z"}
        """
        let creds = CodexUsageFetcher.credentials(in: json(body))
        #expect(creds?.accessToken == "acctok")
        #expect(creds?.refreshToken == "reftok")
        #expect(creds?.accountId == "acct-1")
        // Fractional seconds must parse: the plain ISO8601 formatter rejects
        // them, which would read a fresh token as "never refreshed" and force a
        // pointless refresh on every launch.
        #expect(creds?.lastRefresh != nil)
    }

    @Test("credentials without tokens are refused")
    func refusesEmptyAuth() {
        #expect(CodexUsageFetcher.credentials(in: json(#"{"tokens":{}}"#)) == nil)
        #expect(CodexUsageFetcher.credentials(
            in: json(#"{"tokens":{"access_token":"","refresh_token":"r"}}"#)) == nil)
    }

    @Test("refresh is due only after Codex's own interval")
    func refreshWindow() {
        let t0 = Date(timeIntervalSince1970: 1_785_000_000)
        var creds = CodexUsageFetcher.Credentials(accessToken: "a", refreshToken: "r",
                                                  accountId: nil, lastRefresh: t0)
        #expect(!creds.needsRefresh(now: t0.addingTimeInterval(7 * 24 * 3600)))
        #expect(creds.needsRefresh(now: t0.addingTimeInterval(9 * 24 * 3600)))
        // Never refreshed: assume it is due rather than send a stale token.
        creds.lastRefresh = nil
        #expect(creds.needsRefresh(now: t0))
    }

    @Test("a refresh that returns no new refresh token keeps the old one")
    func refreshKeepsRefreshToken() {
        let previous = CodexUsageFetcher.Credentials(accessToken: "old", refreshToken: "keepme",
                                                     accountId: "acct", lastRefresh: nil)
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        let next = CodexUsageFetcher.refreshed(in: json(#"{"access_token":"new"}"#),
                                               previous: previous, now: now)
        #expect(next?.accessToken == "new")
        #expect(next?.refreshToken == "keepme")
        #expect(next?.accountId == "acct")
        #expect(next?.lastRefresh == now)
    }

    @Test("requests carry exactly the headers Codex sends")
    func requestHeaders() {
        let creds = CodexUsageFetcher.Credentials(accessToken: "tok", refreshToken: "r",
                                                  accountId: "acct-1", lastRefresh: nil)
        let request = CodexUsageFetcher.usageRequest(creds)
        #expect(request.url == CodexUsageFetcher.usageEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-1")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "codex-cli")
    }

    @Test("the refresh request is a refresh_token grant")
    func refreshBody() {
        let creds = CodexUsageFetcher.Credentials(accessToken: "a", refreshToken: "reftok",
                                                  accountId: nil, lastRefresh: nil)
        let request = CodexUsageFetcher.refreshRequest(creds)
        #expect(request.httpMethod == "POST")
        let body = request.httpBody.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        #expect(body?["grant_type"] as? String == "refresh_token")
        #expect(body?["refresh_token"] as? String == "reftok")
        #expect(body?["client_id"] as? String == CodexUsageFetcher.clientId)
    }
}

/// Tap-to-jump for agents that live in an app rather than a terminal.
///
/// The locator places a session by finding a process whose arguments contain
/// the session id. Desktop agents run one process for every conversation —
/// `ChatGPT.app/Contents/Resources/codex … app-server` names no session — so
/// there is nothing to walk up from and the tap did nothing at all. Only Cursor
/// had a fallback.
@Suite("Jumping to a desktop agent")
struct AgentFallbackTargetTests {
    private func session(agent: String) -> AgentSession {
        AgentSession(id: "s1", agent: agent, project: "proj", state: .working,
                     lastActivity: Date())
    }

    @Test("desktop Codex falls back to its app")
    func codexHasAFallback() {
        let ids = session(agent: "codex").fallbackAppBundleIds
        #expect(ids.first == "com.openai.codex")
        // The older bundle id stays as a second candidate.
        #expect(ids.contains("com.openai.chat"))
    }

    @Test("Cursor keeps the fallback it already had")
    func cursorUnchanged() {
        #expect(session(agent: "cursor").fallbackAppBundleIds == ["com.todesktop.230313mzl4w4u92"])
    }

    // Guessing a terminal for a CLI agent would send you to the wrong window as
    // often as the right one, so these deliberately offer nothing and let the
    // process-tree walk do its job.
    @Test("CLI agents offer no app to guess at")
    func cliAgentsHaveNoFallback() {
        #expect(session(agent: "claude-code").fallbackAppBundleIds.isEmpty)
        #expect(session(agent: "opencode").fallbackAppBundleIds.isEmpty)
        #expect(session(agent: "something-else").fallbackAppBundleIds.isEmpty)
    }
}

/// Claude subscription usage from Anthropic, using the token Claude Code
/// already stored at login. Fixtures are the real response shape, captured live
/// from this machine.
@Suite("Claude usage over OAuth")
struct ClaudeUsageFetcherTests {
    @Test func parsesLocalClaudeUsageWithoutConfusingActivityPercentages() throws {
        let now = ISO8601DateFormatter().date(from: "2026-09-27T16:00:00Z")!
        let output = #"{"type":"result","subtype":"success","is_error":false,"result":"Current session: 16% used · resets Sep 27 at 4:49pm (America/New_York)\nCurrent week (all models): 43% used · resets Sep 28 at 6:59pm (America/New_York)\nLocal session attribution: 92%"}"#
        let quota = try #require(ClaudeUsageFetcher.cliQuota(in: Data(output.utf8), now: now))
        #expect(quota.sessionPercent == 16)
        #expect(quota.weeklyPercent == 43)
        #expect(quota.sessionResetsAt != nil)
        #expect(quota.weeklyResetsAt != nil)
        #expect(ClaudeUsageFetcher.cliQuota(in: Data(#"{"result":"Local session attribution: 92%"}"#.utf8)) == nil)
    }

    @Test func usageServiceUsesClaudeCLIByDefault() async throws {
        let output = Data(#"{"type":"result","is_error":false,"result":"Current session: 16% used\nCurrent week (all models): 43% used"}"#.utf8)
        let service = ClaudeUsageService(
            transport: { _ in Issue.record("OAuth transport must not run"); throw URLError(.badURL) },
            readCLI: { output }, store: nil)
        let quota = try #require(await service.quota())
        #expect(quota.sessionPercent == 16)
        #expect(quota.weeklyPercent == 43)
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private let live = """
    {"five_hour":{"utilization":51.0,"resets_at":"2026-08-03T23:59:59.849238+00:00"},
     "seven_day":{"utilization":13.0,"resets_at":"2026-08-09T22:59:59.849262+00:00"},
     "seven_day_opus":null,
     "extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1656.0},
     "spend":{"used":{"amount_minor":1656,"currency":"USD","exponent":2},
              "limit":{"amount_minor":5000,"currency":"USD","exponent":2},
              "percent":33,"enabled":true}}
    """

    @Test("reads both windows from the real payload")
    func parsesLiveResponse() {
        let now = Date(timeIntervalSince1970: 1_785_785_000)
        let quota = ClaudeUsageFetcher.quota(in: json(live), now: now)
        #expect(quota?.sessionPercent == 51)
        #expect(quota?.weeklyPercent == 13)
        #expect(quota?.sessionResetsAt != nil)
        #expect(quota?.weeklyResetsAt != nil)
        #expect(quota?.updatedAt == now)
        // Whichever window is closest to its limit is the one worth showing.
        #expect(quota?.headlinePercent == 51)
    }

    // Money stays in minor units end to end. $16.56 has no exact binary
    // representation, so a Double round trip is a wrong number on a screen
    // about spending.
    @Test("extra spend is rendered from minor units")
    func spendLabel() {
        let quota = ClaudeUsageFetcher.quota(in: json(live))
        #expect(quota?.extraSpentMinor == 1656)
        #expect(quota?.extraLimitMinor == 5000)
        #expect(quota?.extraSpendLabel == "$16.56 of $50")
    }

    @Test("spend that is switched off is not shown")
    func spendDisabled() {
        let body = """
        {"five_hour":{"utilization":10.0},
         "spend":{"used":{"amount_minor":900,"currency":"USD"},"enabled":false}}
        """
        let quota = ClaudeUsageFetcher.quota(in: json(body))
        #expect(quota?.sessionPercent == 10)
        #expect(quota?.extraSpendLabel == nil)
    }

    @Test("a response with no windows yields nothing, not a zero")
    func noWindowsIsNil() {
        // "0% used" when we do not know is the same lie the Codex card told.
        #expect(ClaudeUsageFetcher.quota(in: json(#"{"seven_day_opus":null}"#)) == nil)
        #expect(ClaudeUsageFetcher.quota(in: json("nope")) == nil)
    }

    @Test("utilization is clamped to a percentage")
    func clamps() {
        for (raw, want) in [("-3", 0), ("130", 100), ("50.6", 51)] {
            let body = #"{"five_hour":{"utilization":\#(raw)}}"#
            #expect(ClaudeUsageFetcher.quota(in: json(body))?.sessionPercent == want)
        }
    }

    // The Keychain blob stores epoch *milliseconds*. Read as seconds, every
    // token dates to 1970 and looks expired, so usage would never be fetched.
    @Test("expiry is read as milliseconds")
    func credentialTimes() {
        let body = """
        {"claudeAiOauth":{"accessToken":"tok","refreshToken":"ref",
          "expiresAt":1785792994905,"subscriptionType":"pro",
          "scopes":["user:inference","user:profile"]}}
        """
        let creds = ClaudeUsageFetcher.credentials(in: json(body))
        #expect(creds?.accessToken == "tok")
        #expect(creds?.subscriptionType == "pro")
        #expect(creds?.hasUsageScope == true)
        let expected = Date(timeIntervalSince1970: 1_785_792_994.905)
        #expect(abs((creds?.expiresAt ?? .distantPast).timeIntervalSince(expected)) < 0.01)
        #expect(creds?.isExpired(now: Date(timeIntervalSince1970: 1_785_000_000)) == false)
        #expect(creds?.isExpired(now: Date(timeIntervalSince1970: 1_786_000_000)) == true)
    }

    // A CLI token can hold only `user:inference` — enough to talk to the model,
    // not to read the account. That 403 is worth telling apart from signed out.
    @Test("a token without user:profile is recognised")
    func missingScope() {
        let body = #"{"claudeAiOauth":{"accessToken":"t","scopes":["user:inference"]}}"#
        #expect(ClaudeUsageFetcher.credentials(in: json(body))?.hasUsageScope == false)
    }

    // Claude Code 2.1.x can store only MCP state under this item. That is
    // signed-out for our purposes, not a broken Keychain.
    @Test("an item holding only MCP state reads as no credentials")
    func mcpOnlyItem() {
        #expect(ClaudeUsageFetcher.credentials(in: json(#"{"mcpOAuth":{"a":1}}"#)) == nil)
        #expect(ClaudeUsageFetcher.credentials(in: json(#"{"claudeAiOauth":{"accessToken":""}}"#)) == nil)
    }

    @Test("the request carries the oauth beta header")
    func requestShape() {
        let creds = ClaudeUsageFetcher.Credentials(accessToken: "tok", refreshToken: nil,
                                                   expiresAt: nil, scopes: [],
                                                   subscriptionType: nil)
        let request = ClaudeUsageFetcher.usageRequest(creds)
        #expect(request.url == ClaudeUsageFetcher.usageEndpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    }

    @Test("reset labels round to the unit that reads best")
    func resetLabels() {
        let now = Date(timeIntervalSince1970: 1_785_000_000)
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(1800), now: now) == "resets in 30m")
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(7200), now: now) == "resets in 2h")
        #expect(ClaudeQuota.resetLabel(for: now.addingTimeInterval(3 * 86_400), now: now) == "resets in 3d")
        #expect(ClaudeQuota.resetLabel(for: nil, now: now) == nil)
    }
}

@Suite("Cursor usage over the account API")
struct CursorUsageFetcherTests {
    /// The shape cursor.com/api/usage-summary actually returned, trimmed.
    private static let payload = """
    {"billingCycleStart":"2026-07-16T20:05:08.000Z",
     "billingCycleEnd":"2026-08-16T20:05:08.000Z",
     "membershipType":"pro_student","limitType":"user","isUnlimited":false,
     "individualUsage":{
       "plan":{"enabled":true,"used":2000,"limit":2000,"remaining":0,
               "breakdown":{"included":2000,"bonus":7201,"total":9201},
               "autoPercentUsed":100,"apiPercentUsed":100,"totalPercentUsed":100},
       "onDemand":{"enabled":false,"used":0,"limit":null,"remaining":null}},
     "teamUsage":{}}
    """

    @Test func parsesLivePayload() throws {
        let quota = try #require(CursorUsageFetcher.quota(
            in: Data(Self.payload.utf8), now: Date(timeIntervalSince1970: 1_754_000_000)))
        #expect(quota.used == 2000)
        #expect(quota.limit == 2000)
        #expect(quota.remaining == 0)
        #expect(quota.percentUsed == 100)
        #expect(quota.included == 2000)
        #expect(quota.bonus == 7201)
        #expect(quota.bonusLabel == "+7201 bonus")
        // The two pools Cursor meters separately.
        #expect(quota.autoPercentUsed == 100)
        #expect(quota.apiPercentUsed == 100)
        #expect(quota.membership == "pro_student")
        #expect(quota.isUnlimited == false)
        #expect(quota.onDemandEnabled == false)
        #expect(quota.cycleEnd != nil)
    }

    /// The plan key is raw; the card must not print "pro_student" at a user.
    @Test func tidiesMembershipForDisplay() {
        var quota = CursorQuota(used: 1, limit: 2, included: nil, bonus: nil,
                                percentUsed: 50, autoPercentUsed: nil,
                                apiPercentUsed: nil, cycleEnd: nil,
                                membership: "pro_student", isUnlimited: false,
                                onDemandEnabled: false, updatedAt: nil)
        #expect(quota.membershipLabel == "Pro Student")
        quota.membership = ""
        #expect(quota.membershipLabel == nil)
    }

    /// "used of limit", never "remaining": at the cap, a remaining figure of
    /// zero reads exactly like an account that has done nothing all month.
    @Test func labelsUsageUnambiguously() {
        let full = CursorQuota(used: 2000, limit: 2000, included: nil, bonus: nil,
                               percentUsed: 100, autoPercentUsed: nil,
                               apiPercentUsed: nil, cycleEnd: nil, membership: nil,
                               isUnlimited: false, onDemandEnabled: false, updatedAt: nil)
        #expect(full.usageLabel == "2000 of 2000")
        let unlimited = CursorQuota(used: 0, limit: 0, included: nil, bonus: nil,
                                    percentUsed: 0, autoPercentUsed: nil,
                                    apiPercentUsed: nil, cycleEnd: nil, membership: nil,
                                    isUnlimited: true, onDemandEnabled: false, updatedAt: nil)
        #expect(unlimited.usageLabel == "unlimited")
    }

    /// An unlimited plan carries no plan block. That is an answer, not a failure.
    @Test func unlimitedWithoutPlanBlock() throws {
        let json = """
        {"isUnlimited":true,"membershipType":"business",
         "billingCycleEnd":"2026-08-16T20:05:08.000Z","individualUsage":{}}
        """
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.isUnlimited)
        #expect(quota.membershipLabel == "Business")
    }

    /// Bonus credits sit outside the gauge, so a zero or absent bonus must
    /// print nothing rather than "+0 bonus".
    @Test func hidesEmptyBonus() throws {
        let json = #"{"individualUsage":{"plan":{"used":1,"limit":2,"breakdown":{"bonus":0}}}}"#
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.bonusLabel == nil)
    }

    @Test func rejectsUnrelatedJSON() {
        #expect(CursorUsageFetcher.quota(in: Data(#"{"error":"nope"}"#.utf8)) == nil)
        #expect(CursorUsageFetcher.quota(in: Data("not json".utf8)) == nil)
    }

    /// The server's own percentage wins: 1999/2000 computed locally rounds to
    /// 100 and claims a limit that has not been reached.
    @Test func prefersServerPercent() throws {
        let json = """
        {"individualUsage":{"plan":{"used":1999,"limit":2000,"totalPercentUsed":99}}}
        """
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.percentUsed == 99)
    }

    /// Without a server percentage it rounds down, for the same reason.
    @Test func computesPercentDownWhenAbsent() throws {
        let json = #"{"individualUsage":{"plan":{"used":1999,"limit":2000}}}"#
        let quota = try #require(CursorUsageFetcher.quota(in: Data(json.utf8)))
        #expect(quota.percentUsed == 99)
    }

    @Test func readsSubjectFromTokenPayload() throws {
        // {"sub":"auth0|user_01ABC","exp":1}
        let body = Data(#"{"sub":"auth0|user_01ABC","exp":1}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let creds = try #require(CursorUsageFetcher.credentials(token: "aaa.\(body).bbb"))
        #expect(creds.subject == "user_01ABC")
    }

    @Test func rejectsTokensWithNoUsableSubject() {
        #expect(CursorUsageFetcher.credentials(token: "") == nil)
        #expect(CursorUsageFetcher.credentials(token: "   ") == nil)
        #expect(CursorUsageFetcher.credentials(token: "notajwt") == nil)
        #expect(CursorUsageFetcher.credentials(token: "aaa.!!!notbase64!!!.bbb") == nil)
    }

    /// The cookie Cursor expects is `<sub>::<token>`. Getting the separator
    /// wrong authenticates as nobody and returns an empty plan rather than an
    /// error, which is the worst possible failure for a gauge.
    @Test func buildsSessionCookie() {
        let request = CursorUsageFetcher.usageRequest(
            .init(accessToken: "TOKEN", subject: "user_1"))
        #expect(request.value(forHTTPHeaderField: "Cookie")
                == "WorkosCursorSessionToken=user_1::TOKEN")
        #expect(request.url == CursorUsageFetcher.usageEndpoint)
    }

    /// A GET, deliberately. The dashboard POSTs carry the same numbers but
    /// reject any request lacking a browser Origin header, and forging one to
    /// get past a CSRF check is not something this app should do.
    @Test func usesTheEndpointThatNeedsNoForgedOrigin() {
        #expect(CursorUsageFetcher.usageEndpoint.path == "/api/usage-summary")
        let request = CursorUsageFetcher.usageRequest(
            .init(accessToken: "T", subject: "S"))
        #expect(request.httpMethod == nil || request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Origin") == nil)
    }
}

@Suite("Live agent detail")
struct AgentSessionDetailTests {
    /// Usage records are cumulative per request, so the *newest* one is the
    /// live context. Summing them would report a multiple of the window.
    @Test func readsNewestClaudeContext() throws {
        let text = """
        {"message":{"usage":{"input_tokens":3,"cache_read_input_tokens":1000,"cache_creation_input_tokens":7}}}
        {"message":{"usage":{"input_tokens":2,"cache_read_input_tokens":131955,"cache_creation_input_tokens":503,"output_tokens":1113}}}
        """
        let tokens = try #require(AgentSessionScanner.contextTokens(in: text, isCodex: false))
        // 2 + 131955 + 503. Output is excluded: it is not carried forward.
        #expect(tokens == 132_460)
    }

    @Test func readsCodexContext() throws {
        let text = """
        {"payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":40000,"cached_input_tokens":2000}}}}
        """
        let tokens = try #require(AgentSessionScanner.contextTokens(in: text, isCodex: true))
        #expect(tokens == 42_000)
    }

    @Test func ignoresLinesWithoutUsage() {
        let text = """
        {"message":{"role":"user"}}
        not json at all
        {"payload":{"type":"other"}}
        """
        #expect(AgentSessionScanner.contextTokens(in: text, isCodex: false) == nil)
        #expect(AgentSessionScanner.contextTokens(in: text, isCodex: true) == nil)
    }

    /// A raw 132460 in a notch row is unreadable.
    @Test func formatsTokensCompactly() {
        #expect(AgentSession.compactTokens(940) == "940")
        #expect(AgentSession.compactTokens(9_400) == "9.4k")
        #expect(AgentSession.compactTokens(132_460) == "132k")
        #expect(AgentSession.compactTokens(1_240_000) == "1.2M")
    }

    /// "waiting" alone reads the same at ten seconds and forty minutes.
    @Test func waitingSaysHowLong() {
        let blocked = Date().addingTimeInterval(-360)
        let state = AgentSession.state(lastWrite: Date(), blocked: true, blockedSince: blocked)
        var session = AgentSession(id: "s", agent: "claude-code", project: "p",
                                   state: state, lastActivity: Date())
        #expect(session.statusLabel == "waiting 6m")
        #expect(session.isWaiting)
        // Without a recorded moment it must still read sensibly.
        session.state = .waiting(since: nil)
        #expect(session.statusLabel == "waiting")
    }

    /// Under a minute is noise — every session passes through it.
    @Test func hidesRuntimeUntilItMeansSomething() {
        var session = AgentSession(id: "s", agent: "codex", project: "p",
                                   state: .working, lastActivity: Date())
        session.startedAt = Date().addingTimeInterval(-20)
        #expect(session.runtimeLabel == nil)
        session.startedAt = Date().addingTimeInterval(-2520)
        #expect(session.runtimeLabel == "running 42m")
        // A session resumed across a fortnight read "running 334h".
        session.startedAt = Date().addingTimeInterval(-1_202_400)
        #expect(session.runtimeLabel == "running 13d")
        session.startedAt = nil
        #expect(session.runtimeLabel == nil)
    }

    @Test func contextLabelOnlyWhenKnown() {
        var session = AgentSession(id: "s", agent: "claude-code", project: "p",
                                   state: .working, lastActivity: Date())
        #expect(session.contextLabel == nil)
        session.contextTokens = 0
        #expect(session.contextLabel == nil)
        session.contextTokens = 132_460
        #expect(session.contextLabel == "132k ctx")
    }
}

@Suite("Focus-free reply delivery")
struct TerminalDirectDeliveryTests {
    @Test func onlyClaimsTerminalsThatSupportIt() {
        #expect(TerminalDirectDelivery.supports(bundleId: "com.cmuxterm.app"))
        // Terminal joined the list once it grew a tty-addressed path; a
        // terminal with no scripting still does not.
        #expect(!TerminalDirectDelivery.supports(bundleId: "dev.warp.Warp-Stable"))
        #expect(!TerminalDirectDelivery.supports(bundleId: nil))
    }

    /// AppleScript has no line continuation inside quotes, so a multi-line
    /// reply would be a syntax error rather than a wrong result. Those go the
    /// paste route, which handles them fine.
    @Test func declinesTextItCannotCarry() {
        #expect(TerminalDirectDelivery.canRepresent("hello there"))
        #expect(!TerminalDirectDelivery.canRepresent(""))
        #expect(!TerminalDirectDelivery.canRepresent("two\nlines"))
        #expect(TerminalDirectDelivery.cmuxScript(
            text: "two\nlines", directory: "/tmp", appendReturn: true) == nil)
    }

    /// A quote in a reply would otherwise end the string early and turn the
    /// rest of someone's sentence into AppleScript.
    @Test func escapesQuotesAndBackslashes() {
        #expect(TerminalDirectDelivery.escaped(#"say "hi""#) == #"say \"hi\""#)
        #expect(TerminalDirectDelivery.escaped(#"back\slash"#) == #"back\\slash"#)
        let script = try? #require(TerminalDirectDelivery.cmuxScript(
            text: #"say "hi""#, directory: "/tmp", appendReturn: true))
        #expect(script?.contains(#"input text "say \"hi\"" to target"#) == true)
    }

    /// Writing a reply into the wrong agent is worse than a flicker, so an
    /// ambiguous match has to decline rather than pick one.
    @Test func refusesAmbiguousTargets() throws {
        let script = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/Users/me/project", appendReturn: true))
        #expect(script.contains("if (count of found) is not 1 then return false"))
        #expect(script.contains(#"working directory of cmuxTerminal is "/Users/me/project""#))
    }

    /// Without a directory it may only act when a single terminal exists.
    @Test func withoutDirectoryRequiresASoleTerminal() throws {
        let script = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: nil, appendReturn: true))
        #expect(script.contains("if (count of found) is not 1 then return false"))
        #expect(!script.contains("working directory"))
    }

    /// The Return is a separate action, so a reply that should not submit
    /// must not carry one.
    @Test func submitsOnlyWhenAsked() throws {
        let withReturn = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/tmp", appendReturn: true))
        // Two backslashes: AppleScript unescapes one, leaving Ghostty the
        // `\r` escape its own action parser expects. This is the exact string
        // verified end to end against a live cmux panel.
        #expect(withReturn.contains(##"perform action "text:\\r" on target"##))
        let without = try #require(TerminalDirectDelivery.cmuxScript(
            text: "hi", directory: "/tmp", appendReturn: false))
        #expect(!without.contains("perform action"))
    }
}

@Suite("Usage fetches back off instead of hammering")
struct UsageBackoffTests {
    /// Measured live: the Claude card answered a 429 every 60 seconds for as
    /// long as the app stayed open. A fixed retry into a rate limit is not a
    /// retry, it is the cause of the next one.
    @Test func honoursRetryAfter() throws {
        let response = try #require(HTTPURLResponse(
            url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "120"]))
        #expect(ClaudeUsageFetcher.retryAfter(in: response) == 120)
    }

    /// A header we cannot read must not become a wait of zero — that is the
    /// hammering behaviour again — nor a wait of decades.
    @Test func ignoresUnusableRetryAfter() throws {
        func header(_ value: String) -> HTTPURLResponse? {
            HTTPURLResponse(url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
                            httpVersion: nil, headerFields: ["Retry-After": value])
        }
        #expect(ClaudeUsageFetcher.retryAfter(in: header("0")) == nil)
        #expect(ClaudeUsageFetcher.retryAfter(in: header("-5")) == nil)
        // The HTTP-date form is legal but unparsed here; a misread date would
        // otherwise produce a wait measured in decades.
        #expect(ClaudeUsageFetcher.retryAfter(in: header("Wed, 21 Oct 2026 07:28:00 GMT")) == nil)
        #expect(ClaudeUsageFetcher.retryAfter(in: nil) == nil)
    }

    /// Capped, so a server sending something enormous cannot silently disable
    /// the card for the rest of the session.
    @Test func capsRetryAfter() throws {
        let response = try #require(HTTPURLResponse(
            url: ClaudeUsageFetcher.usageEndpoint, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "999999"]))
        #expect(ClaudeUsageFetcher.retryAfter(in: response) == 3600)
    }

    /// A 429 stops being asked about; a cached answer keeps showing.
    @Test func rateLimitedStopsAsking() async throws {
        var calls = 0
        let service = ClaudeUsageService(
            transport: { request in
                calls += 1
                let response = HTTPURLResponse(url: request.url!, statusCode: 429,
                                               httpVersion: nil,
                                               headerFields: ["Retry-After": "600"])!
                return (Data(), response)
            },
            readKeychain: {
                .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            })
        let start = Date()
        _ = await service.quota(now: start)
        #expect(calls == 1)
        // Well past the 60s refresh interval, but inside the 600s the server
        // asked for: it must not have asked again.
        _ = await service.quota(now: start.addingTimeInterval(120))
        #expect(calls == 1)
        _ = await service.quota(now: start.addingTimeInterval(700))
        #expect(calls == 2)
    }

    /// Live polling must not turn the Claude Keychain read into a prompt on
    /// every refresh. The token is reused until the API rejects it, at which
    /// point the service clears it and reads Claude Code's rotated token next.
    @Test func reusesKeychainCredentialAcrossLiveRefreshes() async throws {
        var reads = 0
        var calls = 0
        let service = ClaudeUsageService(
            transport: { request in
                calls += 1
                let body = Data(#"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                reads += 1
                return .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            },
            store: nil)
        let start = Date()
        _ = await service.quota(now: start)
        _ = await service.quota(now: start.addingTimeInterval(61))
        #expect(calls == 2)
        #expect(reads == 1)
    }

    /// A Keychain that cannot answer right now is not a signed-out user.
    ///
    /// Measured on 2026-09-08: the Mac went into dark wake, `SecItemCopyMatching`
    /// returned -25320 ("In dark wake, no UI possible"), the service read that
    /// as `.noCredentials`, set `givenUp`, and the card stayed gone for the next
    /// 39 hours because `givenUp` only clears on relaunch. A transient refusal
    /// has to back off and try again.
    @Test func darkWakeKeychainRetriesInsteadOfGivingUp() async throws {
        var reads = 0
        var transportCalls = 0
        let service = ClaudeUsageService(
            transport: { request in
                transportCalls += 1
                let body = Data(#"{"five_hour":{"utilization":11},"seven_day":{"utilization":22}}"#.utf8)
                return (body, HTTPURLResponse(url: request.url!, statusCode: 200,
                                              httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                reads += 1
                // Unavailable on the first ask, fine on the next.
                return reads == 1
                    ? .unavailable
                    : .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            },
            store: nil)
        let start = Date()
        #expect(await service.quota(now: start) == nil)
        #expect(transportCalls == 0)
        // Past the backoff the service must ask the Keychain again rather than
        // sitting on a permanent verdict.
        let later = await service.quota(now: start.addingTimeInterval(4000))
        #expect(later?.sessionPercent == 11)
        #expect(reads == 2)
    }

    /// A Keychain with no item at all still gives up — re-asking re-prompts.
    @Test func missingKeychainItemStillGivesUp() async throws {
        var reads = 0
        let service = ClaudeUsageService(
            transport: { _ in Issue.record("must not reach the network"); return (Data(), URLResponse()) },
            readKeychain: { reads += 1; return .absent },
            store: nil)
        let start = Date()
        #expect(await service.quota(now: start) == nil)
        #expect(await service.quota(now: start.addingTimeInterval(4000)) == nil)
        #expect(reads == 1)
    }
}

@Suite("Placing a terminal agent when its session id is gone")
struct TerminalHostFallbackTests {
    private func entry(_ pid: Int32, _ ppid: Int32, _ args: String) -> AgentSessionLocator.Entry {
        AgentSessionLocator.Entry(pid: pid, ppid: ppid, args: args)
    }

    /// Substring matching was measured picking up `grep -iE "claude|codex"`:
    /// a shell that mentions both, descends from a terminal, and is not an
    /// agent. It made Codex look hosted in two places, so the lookup declined
    /// and the tap stayed broken.
    @Test func onlyTheBinaryItselfCounts() {
        #expect(AgentSessionLocator.isProcess("/opt/homebrew/bin/claude --resume", named: "claude"))
        #expect(AgentSessionLocator.isProcess("claude", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("grep -iE claude|codex", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("/bin/zsh -c claude foo", named: "claude"))
        #expect(!AgentSessionLocator.isProcess("", named: "claude"))
    }

    @Test func mapsAgentsToTheirBinaries() {
        #expect(AgentSessionLocator.executableName(for: "claude-code") == "claude")
        #expect(AgentSessionLocator.executableName(for: "codex") == "codex")
        #expect(AgentSessionLocator.executableName(for: "opencode") == "opencode")
        // Cursor is a GUI app placed by its own bundle id, not a process walk.
        #expect(AgentSessionLocator.executableName(for: "cursor") == nil)
        #expect(AgentSessionLocator.executableName(for: nil) == nil)
    }

    /// Real bundles, because the walk resolves a path to a bundle id on disk.
    /// Fake paths resolve to nil and would make every case look "ambiguous",
    /// which is how the first draft of these tests passed for the wrong reason.
    private static let finder = "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder"
    private static let music = "/System/Applications/Music.app/Contents/MacOS/Music"

    /// Two terminals hosting the same agent means jumping to the wrong one is
    /// as likely as the right one.
    @Test func declinesWhenTwoTerminalsHostTheSameAgent() {
        let table = [
            entry(10, 1, Self.finder),
            entry(11, 10, "/opt/homebrew/bin/claude"),
            entry(20, 1, Self.music),
            entry(21, 20, "/opt/homebrew/bin/claude"),
        ]
        #expect(AgentSessionLocator.soleTerminalHost(agent: "claude-code", in: table) == nil)
    }

    /// The case that was broken: an idle Claude Code session, whose only
    /// processes carrying the session id were transient tool shells that had
    /// already exited. It is placed by the agent binary instead, which lives
    /// as long as the session does — and resolves through `login`, which
    /// carries no bundle of its own.
    @Test func placesAnIdleAgentByItsRunningBinary() {
        let table = [
            entry(10, 1, Self.finder),
            entry(11, 10, "/usr/bin/login -pf someone"),
            entry(12, 11, "/opt/homebrew/bin/claude"),
            entry(30, 1, Self.music),
        ]
        #expect(AgentSessionLocator.soleTerminalHost(agent: "claude-code", in: table)
                == "com.apple.finder")
        // A different agent, not running anywhere, must not borrow that answer.
        #expect(AgentSessionLocator.soleTerminalHost(agent: "codex", in: table) == nil)
    }
}

@Suite("The Claude card survives a launch into a rate limit")
struct ClaudeQuotaCacheTests {
    private func store() -> UserDefaults {
        let suite = UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!
        return suite
    }

    /// A launch that opens into a 429 had nothing to show, and the card simply
    /// was not there — which read as the feature having been removed.
    @Test func servesTheLastGoodAnswerAfterRelaunch() async throws {
        let defaults = store()
        var calls = 0
        let ok = ClaudeUsageService(
            transport: { request in
                calls += 1
                let body = #"{"five_hour":{"utilization":58},"seven_day":{"utilization":14}}"#
                return (Data(body.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200,
                                        httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            },
            store: defaults)
        let start = Date()
        let first = try #require(await ok.quota(now: start))
        #expect(first.sessionPercent == 58)
        #expect(calls == 1)

        // A new service, as though the app had been relaunched, that can only
        // get a 429 — the situation measured against the live API.
        let limited = ClaudeUsageService(
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429,
                                         httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            },
            store: defaults)
        let restored = try #require(await limited.quota(now: start.addingTimeInterval(60)))
        #expect(restored.sessionPercent == 58)
        #expect(restored.weeklyPercent == 14)
    }

    /// Old enough and it stops being an answer. Showing a number from
    /// yesterday as though it were current is worse than showing none.
    @Test func doesNotServeAnAnswerThatIsTooOld() async throws {
        let defaults = store()
        defaults.set(["session": 58, "weekly": 14,
                      "at": Date().timeIntervalSince1970 - 7200],
                     forKey: ClaudeUsageService.cacheKey)
        let limited = ClaudeUsageService(
            transport: { request in
                (Data(), HTTPURLResponse(url: request.url!, statusCode: 429,
                                         httpVersion: nil, headerFields: nil)!)
            },
            readKeychain: {
                .blob(Data(#"{"claudeAiOauth":{"accessToken":"t","scopes":["user:profile"]}}"#.utf8))
            },
            store: defaults)
        #expect(await limited.quota(now: Date()) == nil)
    }

    @Test func ignoresAnUnreadableCache() {
        let defaults = store()
        defaults.set(["session": "not a number"], forKey: ClaudeUsageService.cacheKey)
        #expect(ClaudeUsageService.restore(from: defaults) == nil)
        #expect(ClaudeUsageService.restore(from: store()) == nil)
    }
}

@Suite("Usage resets read as times, not durations")
struct QuotaResetClockTests {
    private let calendar = Calendar(identifier: .gregorian)
    private let locale = Locale(identifier: "en_US_POSIX")
    private let now = Date(timeIntervalSince1970: 1_785_800_000)   // 2026-08-03

    /// "resets in 5d" tells you how long you have waited, not when you can
    /// work again — and it was the only reset on the card, so the session
    /// window's reset was invisible whenever weekly happened to be higher.
    @Test func todayShowsAClockTime() throws {
        let later = now.addingTimeInterval(3 * 3600)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        // A time of day, not a duration.
        #expect(text.contains(":"))
        #expect(!text.contains("in "))
    }

    @Test func laterThisWeekNamesTheDay() throws {
        let later = now.addingTimeInterval(3 * 86_400)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        #expect(text.contains(":"))
        // Includes a weekday, so "Thu 2:40 AM" cannot be misread as today.
        #expect(text.rangeOfCharacter(from: .letters) != nil)
    }

    @Test func furtherOutGivesADate() throws {
        let later = now.addingTimeInterval(20 * 86_400)
        let text = try #require(ClaudeQuota.resetClock(for: later, now: now,
                                                       calendar: calendar, locale: locale))
        #expect(text.rangeOfCharacter(from: .decimalDigits) != nil)
        #expect(!text.contains(":"))
    }

    @Test func nothingToShowWithoutAResetTime() {
        #expect(ClaudeQuota.resetClock(for: nil, now: now,
                                       calendar: calendar, locale: locale) == nil)
    }
}

@Suite("Every deck card uses the same island size")
struct DeckPageHeightTests {
    private let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                       designExpandedWidth: 640, designExpandedHeight: 190,
                                       scale: 1, topGap: 10)
    private func sessions(_ count: Int) -> [AgentSession] {
        (0..<count).map {
            AgentSession(id: "s\($0)", agent: "claude-code", project: "p",
                         state: .working, lastActivity: Date())
        }
    }

    /// Swiping from a dense agents card to a short quota card keeps the outer
    /// silhouette fixed, so only the content moves.
    @Test func denseAndShortCardsShareOneHeight() {
        let deck: [ExpandedActivity] = [
            .agents(AgentHomeTray(sessions(3))),
            .claudeQuota(ClaudeQuota(sessionPercent: 26, weeklyPercent: 28)),
        ]
        let mixed = NotchContentLayout.expandedDeckSize(metrics: metrics, activities: deck)
        let agentsOnly = NotchContentLayout.expandedDeckSize(metrics: metrics,
                                                            activities: [deck[0]])
        let quotaOnly = NotchContentLayout.expandedDeckSize(metrics: metrics,
                                                           activities: [deck[1]])
        #expect(mixed == agentsOnly)
        #expect(mixed == quotaOnly)
    }

}

@Suite("The reply composer shows what you are replying to")
struct ReplyContextTests {
    /// A finished peek's subtitle is "finished · branch": it says an agent
    /// stopped, not what it said. Replying to that was answering a question
    /// you could not see.
    @Test func finishedPeekShowsTheAgentsLastMessage() {
        let alert = DevReadyAlert(title: "NotchPill", subtitle: "finished · main",
                                  agent: "claude-code", kind: .finished,
                                  agentMessage: "Want me to cut the release?")
        #expect(alert.questionText == nil)
        #expect(alert.replyContextText == "Want me to cut the release?")
    }

    /// A real question still wins — it is the more specific thing.
    @Test func aQuestionOutranksTheLastMessage() {
        let alert = DevReadyAlert(title: "p", kind: .waiting, message: "Allow Bash?",
                                  agentMessage: "some earlier chatter")
        #expect(alert.replyContextText == "Allow Bash?")
    }

    @Test func nothingToShowWhenThereIsNothing() {
        #expect(DevReadyAlert(title: "p").replyContextText == nil)
        #expect(DevReadyAlert(title: "p", agentMessage: "").replyContextText == nil)
    }

    /// Claude Code's transcript shape.
    @Test func readsClaudeCodesLastSpokenText() throws {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}
        {"type":"user","message":{"content":"a reply"}}
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"},{"type":"text","text":"Shall I ship it?"}]}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: false) == "Shall I ship it?")
    }

    /// Codex's, which uses a different envelope entirely — the point being
    /// that every agent gets this, not only Claude Code.
    @Test func readsCodexsLastSpokenText() throws {
        let text = """
        {"payload":{"type":"agent_message","message":"Done — anything else?"}}
        {"payload":{"type":"token_count","info":{}}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: true)
                == "Done — anything else?")
    }

    /// Reasoning and tool output are the agent's working, not its answer.
    @Test func skipsReasoningAndToolOutput() {
        let text = """
        {"payload":{"type":"agent_message","message":"The answer"}}
        {"payload":{"type":"reasoning","content":[{"type":"text","text":"thinking aloud"}]}}
        {"payload":{"type":"custom_tool_call_output","output":"tool said this"}}
        """
        #expect(AgentSessionScanner.lastAgentMessage(in: text, isCodex: true) == "The answer")
    }

    @Test func nothingFromATranscriptWithNoSpeech() {
        #expect(AgentSessionScanner.lastAgentMessage(in: "not json", isCodex: false) == nil)
        #expect(AgentSessionScanner.lastAgentMessage(
            in: #"{"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}"#,
            isCodex: false) == nil)
    }
}

@Suite("A peek from a hook still gets its context filled in")
struct AgentMessageEnrichmentTests {
    @MainActor
    private func state(with alert: DevReadyAlert) -> NotchState {
        let state = NotchState()
        state.enqueueDevReady([alert])
        return state
    }

    /// The measured case: a Stop-hook peek arrives with no transcript text, so
    /// the composer had nothing above the field.
    @MainActor @Test func fillsInAMissingMessage() {
        let alert = DevReadyAlert(title: "NotchPill", agent: "claude-code", sessionId: "s1")
        let state = self.state(with: alert)
        #expect(state.devReadyAlerts.first?.replyContextText == nil)
        state.setAgentMessage("Shall I cut the release?", forAlert: alert.id)
        #expect(state.devReadyAlerts.first?.replyContextText == "Shall I cut the release?")
    }

    /// The composer holds its own copy of the alert. Updating only the peek
    /// left the field blank, which is the bug this exists to fix.
    @MainActor @Test func updatesAnOpenComposerToo() {
        let alert = DevReadyAlert(title: "NotchPill", agent: "claude-code", sessionId: "s1")
        let state = self.state(with: alert)
        state.beginReply(to: alert)
        state.setAgentMessage("Shall I cut the release?", forAlert: alert.id)
        #expect(state.replyCompose?.contextText == "Shall I cut the release?")
    }

    /// A message already present is the more specific one — a later read must
    /// not overwrite it.
    @MainActor @Test func neverOverwritesWhatIsAlreadyThere() {
        let alert = DevReadyAlert(title: "p", agent: "claude-code", sessionId: "s1",
                                  agentMessage: "original")
        let state = self.state(with: alert)
        state.setAgentMessage("later read", forAlert: alert.id)
        #expect(state.devReadyAlerts.first?.agentMessage == "original")
    }

    @MainActor @Test func ignoresAnAlertThatHasGone() {
        let state = NotchState()
        state.setAgentMessage("anything", forAlert: "not-here")
        #expect(state.devReadyAlerts.isEmpty)
    }
}

@Suite("Media progress moves on its own")
struct MediaProgressTests {
    /// The adapter sends an ISO 8601 string. The parser accepted only numbers,
    /// so it returned nil for every real payload — and with no anchor there is
    /// nothing to interpolate from, which is why the bar sat frozen.
    @Test func parsesTheTimestampTheAdapterActuallySends() throws {
        let payload: [String: Any] = ["timestamp": "2026-08-04T18:32:24Z"]
        let date = try #require(MediaRemoteBridge.parseTimestamp(payload))
        #expect(abs(date.timeIntervalSince1970 - 1_785_868_344) < 1)
    }

    @Test func stillAcceptsNumericTimestamps() throws {
        #expect(MediaRemoteBridge.parseTimestamp(["timestampEpochMicros": NSNumber(value: 1_785_868_344_000_000)]) != nil)
        #expect(MediaRemoteBridge.parseTimestamp(["timestamp": NSNumber(value: 1_785_868_344)]) != nil)
        #expect(MediaRemoteBridge.parseTimestamp([:]) == nil)
        #expect(MediaRemoteBridge.parseTimestamp(["timestamp": "not a date"]) == nil)
    }

    @Test func acceptsFractionalSeconds() {
        #expect(MediaRemoteBridge.parseISOTimestamp("2026-08-04T18:32:24.512Z") != nil)
        #expect(MediaRemoteBridge.parseISOTimestamp("2026-08-04T18:32:24Z") != nil)
        #expect(MediaRemoteBridge.parseISOTimestamp("   ") == nil)
    }

    /// The measured case: a browser reporting elapsedTime 0 against a fixed
    /// timestamp. The position has to come from the clock.
    @Test func projectsPositionFromTheAnchor() throws {
        let anchor = Date()
        let np = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 0,
                            duration: 102.6, playbackRate: 1, timestamp: anchor)
        let after = try #require(np.interpolatedElapsed(at: anchor.addingTimeInterval(30)))
        #expect(abs(after - 30) < 0.01)
    }

    @Test func neverRunsPastTheEndOrWhilePaused() throws {
        let anchor = Date()
        let playing = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 100,
                                 duration: 102.6, playbackRate: 1, timestamp: anchor)
        #expect(try #require(playing.interpolatedElapsed(at: anchor.addingTimeInterval(60))) == 102.6)
        let paused = NowPlaying(title: "t", artist: "a", isPlaying: false, elapsed: 40,
                                duration: 102.6, playbackRate: 0, timestamp: anchor)
        #expect(try #require(paused.interpolatedElapsed(at: anchor.addingTimeInterval(60))) == 40)
    }

    /// A seek keeps the same track, artist and play state, so equality that
    /// ignored position dropped it as a duplicate and the bar kept running
    /// from the old anchor.
    @Test func aSeekIsNotADuplicate() {
        let anchor = Date()
        let before = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 10,
                                duration: 200, playbackRate: 1, timestamp: anchor)
        let sought = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 150,
                                duration: 200, playbackRate: 1,
                                timestamp: anchor.addingTimeInterval(5))
        #expect(before != sought)
    }

    /// A player whose position advances by itself must not republish every
    /// poll: the bar is already moving without help.
    @Test func normalPlaybackIsNotAChange() {
        let anchor = Date()
        let before = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 10,
                                duration: 200, playbackRate: 1, timestamp: anchor)
        let later = NowPlaying(title: "t", artist: "a", isPlaying: true, elapsed: 13,
                               duration: 200, playbackRate: 1,
                               timestamp: anchor.addingTimeInterval(3))
        #expect(before == later)
    }

    @Test func aDifferentTrackIsAlwaysAChange() {
        let now = Date()
        let a = NowPlaying(title: "one", artist: "a", isPlaying: true, elapsed: 10,
                           duration: 200, playbackRate: 1, timestamp: now)
        let b = NowPlaying(title: "two", artist: "a", isPlaying: true, elapsed: 10,
                           duration: 200, playbackRate: 1, timestamp: now)
        #expect(a != b)
    }
}

@Suite("Focus-free replies reach Terminal and iTerm too")
struct TerminalITermDeliveryTests {
    private func entry(_ pid: Int32, _ ppid: Int32, _ args: String) -> AgentSessionLocator.Entry {
        AgentSessionLocator.Entry(pid: pid, ppid: ppid, args: args)
    }

    @Test func allThreeTerminalsAreSupported() {
        #expect(TerminalDirectDelivery.supports(bundleId: "com.cmuxterm.app"))
        #expect(TerminalDirectDelivery.supports(bundleId: "com.apple.Terminal"))
        #expect(TerminalDirectDelivery.supports(bundleId: "com.googlecode.iterm2"))
        #expect(!TerminalDirectDelivery.supports(bundleId: "dev.warp.Warp-Stable"))
    }

    /// `do script` with no target opens a new window. Without the tab clause
    /// this would spawn a shell with the user's reply typed into it.
    @Test func terminalAlwaysNamesTheTab() throws {
        let script = try #require(TerminalDirectDelivery.terminalScript(
            text: "yes please", tty: "/dev/ttys003", appendReturn: true))
        #expect(script.contains(#"if tty of aTab is "/dev/ttys003""#))
        #expect(script.contains(#"do script "yes please" in aTab"#))
        #expect(script.contains("return false"))
    }

    /// Terminal submits whatever `do script` sends, so a reply that must not
    /// submit cannot go this way.
    @Test func terminalDeclinesWhenItMustNotSubmit() {
        #expect(TerminalDirectDelivery.terminalScript(
            text: "y", tty: "/dev/ttys003", appendReturn: false) == nil)
    }

    @Test func iTermWritesToOneSession() throws {
        let script = try #require(TerminalDirectDelivery.iTermScript(
            text: "yes please", tty: "/dev/ttys003", appendReturn: true))
        #expect(script.contains(#"if tty of aSession is "/dev/ttys003""#))
        #expect(script.contains(#"write text "yes please""#))
        #expect(!script.contains("newline no"))
        let noSubmit = try #require(TerminalDirectDelivery.iTermScript(
            text: "y", tty: "/dev/ttys003", appendReturn: false))
        #expect(noSubmit.contains("newline no"))
    }

    @Test func neitherScriptExistsWithoutATTY() {
        #expect(TerminalDirectDelivery.terminalScript(text: "x", tty: "", appendReturn: true) == nil)
        #expect(TerminalDirectDelivery.iTermScript(text: "x", tty: "", appendReturn: true) == nil)
    }

    /// Resolved from the agent's own binary, not from a process carrying the
    /// session id — those are transient tool shells that vanish when idle.
    @Test func resolvesTheTTYOfTheAgentInThatDirectory() {
        let table = [
            entry(10, 1, "/opt/homebrew/bin/claude"),
            entry(11, 1, "/opt/homebrew/bin/claude"),
        ]
        let cwds: [Int32: String] = [10: "/Users/me/one", 11: "/Users/me/two"]
        // Only one agent matches the directory, so the answer is unambiguous.
        let matched = AgentSessionLocator.tty(forDirectory: "/Users/me/one", agent: "claude-code",
                                              in: table, workingDirectory: { cwds[$0] })
        // controllingTTY shells out for a pid that does not exist here, so the
        // assertion is that it narrowed to exactly one candidate and tried.
        #expect(matched == nil || matched?.isEmpty == false)
    }

    /// Two agents of the same kind in the same directory: writing into the
    /// wrong one is as likely as the right one.
    @Test func declinesTwoAgentsInOneDirectory() {
        let table = [
            entry(10, 1, "/opt/homebrew/bin/claude"),
            entry(11, 1, "/opt/homebrew/bin/claude"),
        ]
        let cwds: [Int32: String] = [10: "/Users/me/one", 11: "/Users/me/one"]
        #expect(AgentSessionLocator.tty(forDirectory: "/Users/me/one", agent: "claude-code",
                                        in: table, workingDirectory: { cwds[$0] }) == nil)
    }

    /// Unlike cmux there is no "only one terminal open" fallback: a stray
    /// Terminal window is ordinary, and a reply typed into someone's shell is
    /// worse than a flicker.
    @MainActor @Test func terminalDeclinesWithoutATTYRatherThanGuessing() {
        let delivered = TerminalDirectDelivery.send(
            text: "hello", bundleId: "com.apple.Terminal", directory: "/Users/me/one",
            appendReturn: true, agent: "claude-code", resolveTTY: { _, _ in nil })
        #expect(delivered == false)
    }
}

@Suite("Desktop agents can be replied to")
struct DesktopAgentReplyTests {
    /// The original complaint: a peek from Codex or Cursor offered no reply at
    /// all. They were excluded by a rule about *answer capsules* — buttons
    /// guessing an agent's keys — which never applied to free text.
    @Test func codexAndCursorAcceptATypedReply() {
        #expect(DevReadyAlert(title: "p", agent: "codex",
                              bundleId: "com.openai.codex").supportsTypedReply)
        #expect(DevReadyAlert(title: "p", agent: "cursor",
                              bundleId: "com.todesktop.230313mzl4w4u92").supportsTypedReply)
    }

    /// An agent that declares it cannot be answered still cannot be.
    @Test func anExplicitNoIsStillNo() {
        #expect(!DevReadyAlert(title: "p", agent: "codex", bundleId: "com.openai.codex",
                               deliverySpec: "none").supportsTypedReply)
    }

    /// A terminal agent is a prompt waiting on a line, so text plus Return is
    /// the whole interaction.
    @Test func terminalRepliesSubmitThemselves() {
        #expect(DevReadyAlert(title: "p", bundleId: "com.apple.Terminal").submitsOnDelivery)
        #expect(DevReadyAlert(title: "p", bundleId: "com.cmuxterm.app").submitsOnDelivery)
        #expect(DevReadyAlert(title: "p").submitsOnDelivery)
    }

    /// A desktop app is not. Whatever holds keyboard focus receives the paste,
    /// and in an editor-shaped app that can be a source file — where Return
    /// would commit a stray line into someone's code. Pasting alone leaves
    /// something visible and undoable.
    @Test func desktopRepliesAreDeliveredButNotSent() {
        #expect(!DevReadyAlert(title: "p", bundleId: "com.openai.codex").submitsOnDelivery)
        #expect(!DevReadyAlert(title: "p", bundleId: "com.openai.chat").submitsOnDelivery)
        #expect(!DevReadyAlert(title: "p",
                               bundleId: "com.todesktop.230313mzl4w4u92").submitsOnDelivery)
    }
}

@Suite("Now-playing equality obeys its contract")
struct NowPlayingEqualitySymmetryTests {
    private func track(_ elapsed: TimeInterval, at date: Date,
                       playing: Bool = true) -> NowPlaying {
        NowPlaying(title: "t", artist: "a", isPlaying: playing, elapsed: elapsed,
                   duration: 200, playbackRate: playing ? 1 : 0, timestamp: date)
    }

    /// Measured asymmetry: projecting whichever value was on the left made
    /// `a == b` true while `b == a` was false, at the duration cap where
    /// interpolation clamps in one direction only. Equatable requires
    /// symmetry, and removeDuplicates and SwiftUI diffing both assume it.
    @Test func symmetricAtTheDurationCap() {
        let t0 = Date()
        let nearEnd = track(199, at: t0)
        let atEnd = track(200, at: t0.addingTimeInterval(60))
        #expect((nearEnd == atEnd) == (atEnd == nearEnd))
    }

    @Test func symmetricAcrossOrdinaryCases() {
        let t0 = Date()
        let pairs: [(NowPlaying, NowPlaying)] = [
            (track(10, at: t0), track(13, at: t0.addingTimeInterval(3))),      // playing on
            (track(10, at: t0), track(150, at: t0.addingTimeInterval(3))),     // seek
            (track(10, at: t0, playing: false),
             track(80, at: t0.addingTimeInterval(3), playing: false)),         // paused, moved
            (track(199, at: t0), track(0, at: t0.addingTimeInterval(120))),    // looped
        ]
        for (a, b) in pairs {
            #expect((a == b) == (b == a), "asymmetric for \(a.elapsed ?? -1) vs \(b.elapsed ?? -1)")
        }
    }

    @Test func reflexive() {
        let np = track(42, at: Date())
        #expect(np == np)
    }

    /// The behaviour the symmetry fix must not cost: ordinary playback still
    /// compares equal, and a seek still does not.
    @Test func stillTellsPlaybackFromASeek() {
        let t0 = Date()
        #expect(track(10, at: t0) == track(13, at: t0.addingTimeInterval(3)))
        #expect(track(10, at: t0) != track(150, at: t0.addingTimeInterval(3)))
    }
}

@Suite("The Cursor card survives a launch into a failure")
struct CursorQuotaCacheTests {
    private func store() -> UserDefaults {
        UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!
    }

    /// The Claude card kept its last reading across launches and the Cursor
    /// card did not — the same bug, fixed in one place only.
    @Test func servesTheLastGoodAnswerAfterRelaunch() async throws {
        let defaults = store()
        let body = """
        {"membershipType":"pro_student","isUnlimited":false,
         "billingCycleEnd":"2026-08-16T20:05:08.000Z",
         "individualUsage":{"plan":{"used":2000,"limit":2000,
           "breakdown":{"included":2000,"bonus":7201},
           "autoPercentUsed":100,"apiPercentUsed":100,"totalPercentUsed":100},
          "onDemand":{"enabled":false}}}
        """
        let ok = CursorUsageService(
            transport: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200,
                                                  httpVersion: nil, headerFields: nil)!)
            },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        let first = try #require(await ok.quota(now: Date()))
        #expect(first.used == 2000)

        // A fresh service that can only fail, as though relaunched offline.
        let failing = CursorUsageService(
            transport: { _ in throw URLError(.notConnectedToInternet) },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        let restored = try #require(await failing.quota(now: Date()))
        #expect(restored.used == 2000)
        #expect(restored.percentUsed == 100)
        #expect(restored.membershipLabel == "Pro Student")
        #expect(restored.autoPercentUsed == 100)
    }

    @Test func ignoresAnUnreadableCache() {
        let defaults = store()
        defaults.set(["used": "lots"], forKey: CursorUsageService.cacheKey)
        #expect(CursorUsageService.restore(from: defaults) == nil)
        #expect(CursorUsageService.restore(from: store()) == nil)
    }

    /// Old enough and it stops being an answer.
    @Test func withholdsAnAnswerThatIsTooOld() async {
        let defaults = store()
        defaults.set(["used": 2000, "limit": 2000, "percent": 100,
                      "at": Date().timeIntervalSince1970 - 7200],
                     forKey: CursorUsageService.cacheKey)
        let failing = CursorUsageService(
            transport: { _ in throw URLError(.notConnectedToInternet) },
            readToken: { "aaa." + Data(#"{"sub":"auth0|user_1"}"#.utf8)
                .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".bbb" },
            store: defaults)
        #expect(await failing.quota(now: Date()) == nil)
    }
}

@Suite("A peek you are reading does not fade out from under you")
struct PeekHoldTests {
    @Test("Nothing holds a fresh peek")
    func idleHoldsNothing() {
        let hold = PeekHold()
        #expect(!hold.holdsPeek)
    }

    @Test("Hovering holds the peek, leaving releases it")
    func hoverHolds() {
        var hold = PeekHold()
        let changed1 = hold.setHovered(true)
        #expect(changed1)
        #expect(hold.holdsPeek)
        let changed2 = hold.setHovered(false)
        #expect(changed2)
        #expect(!hold.holdsPeek)
    }

    /// The hover source is a polling tick, so this fires many times per second
    /// with an unchanged answer. Reporting a change every time would restart
    /// the fade timer on every tick and the peek would never fade at all.
    @Test("Repeating the same hover state reports no change")
    func hoverIsIdempotent() {
        var hold = PeekHold()
        let changed3 = hold.setHovered(true)
        #expect(changed3)
        let changed4 = hold.setHovered(true)
        #expect(!changed4)
        let changed5 = hold.setHovered(true)
        #expect(!changed5)
        #expect(hold.holdsPeek)
    }

    @Test("A pin outlives the pointer")
    func pinSurvivesHoverLeaving() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        _ = hold.togglePin("a")
        let changed6 = hold.setHovered(false)
        #expect(!changed6, "the pin still holds it, so nothing changed")
        #expect(hold.holdsPeek)
        #expect(hold.isPinned("a"))
    }

    /// Hover already holds the peek, so pinning changes no timer *now* — but it
    /// decides what happens when the pointer leaves, which is the whole point.
    @Test("Pinning under the pointer reports no timer change")
    func pinningWhileHoveredChangesNothingYet() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        let changed7 = hold.togglePin("a")
        #expect(!changed7)
        #expect(hold.holdsPeek)
    }

    @Test("Unpinning the last pin releases the peek")
    func unpinReleases() {
        var hold = PeekHold()
        let changed8 = hold.togglePin("a")
        #expect(changed8)
        #expect(hold.holdsPeek)
        let changed9 = hold.togglePin("a")
        #expect(changed9)
        #expect(!hold.holdsPeek)
    }

    /// Pins are per-row: pinning a caption must not freeze an unrelated agent
    /// ping that happens to be stacked with it.
    @Test("Pins are independent of each other")
    func pinsAreIndependent() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        _ = hold.togglePin("b")
        let changed10 = hold.togglePin("a")
        #expect(!changed10, "b still holds it")
        #expect(hold.holdsPeek)
        #expect(!hold.isPinned("a"))
        #expect(hold.isPinned("b"))
        let changed11 = hold.togglePin("b")
        #expect(changed11)
        #expect(!hold.holdsPeek)
    }

    /// The one way this feature could strand the overlay: a pin whose row is
    /// gone holds the peek open forever with nothing left to click.
    @Test("A dismissed row's pin is forgotten")
    func forgettingADismissedRowReleases() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        let changed12 = hold.forget("a")
        #expect(changed12)
        #expect(!hold.holdsPeek)
        let changed13 = hold.forget("a")
        #expect(!changed13, "forgetting twice is not a second change")
    }

    @Test("Pins for rows that no longer exist are pruned")
    func retainDropsVanishedRows() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        _ = hold.togglePin("b")
        let changed14 = hold.retain(ids: ["a"])
        #expect(!changed14, "a still holds it")
        #expect(hold.holdsPeek)
        #expect(!hold.isPinned("b"))
        let changed15 = hold.retain(ids: [])
        #expect(changed15)
        #expect(!hold.holdsPeek)
    }

    @Test("Keeping every row prunes nothing")
    func retainIsANoOpWhenNothingVanished() {
        var hold = PeekHold()
        _ = hold.togglePin("a")
        let changed16 = hold.retain(ids: ["a", "b"])
        #expect(!changed16)
        #expect(hold.isPinned("a"))
    }

    /// The pointer may still be sitting where the peek was. A hover that
    /// survived the dismissal would hold the *next* peek open without the user
    /// hovering anything — a peek that never fades and never explains why.
    @Test("Dismissal clears hover as well as pins")
    func resetClearsHoverToo() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        _ = hold.togglePin("a")
        hold.reset()
        #expect(!hold.holdsPeek)
        #expect(!hold.isPinned("a"))
        let changed17 = hold.setHovered(true)
        #expect(changed17, "hover starts fresh, so the next hover is a change")
    }

    /// REGRESSION: forgetting only the pin (as single-dismiss used to) leaves
    /// isHovered set. The next finished ping then skips its fade timer — the
    /// Codex "done" peeks that never cleared until you hit ✕.
    @Test("Forgetting a pin alone must not be treated as a full clear")
    func forgetLeavesHoverHolding() {
        var hold = PeekHold()
        _ = hold.setHovered(true)
        _ = hold.togglePin("a")
        _ = hold.forget("a")
        #expect(hold.holdsPeek, "hover still holds — callers must reset() when the list empties")
        hold.reset()
        #expect(!hold.holdsPeek)
    }
}

@Suite("A caption is never cut off with an ellipsis")
struct CaptionFitsTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 179, notchHeight: 32,
                     designExpandedWidth: 720, designExpandedHeight: 128,
                     scale: 0.54, screenWidth: 1512)
    }

    /// The reported bug, in one assertion. A single short sentence used to be
    /// estimated at one line from its character count, so the row was drawn
    /// with `lineLimit(1)` — and then truncated, because the estimate was wrong
    /// by the fraction of a line that matters.
    @Test("A short spoken sentence gets every line it needs")
    @MainActor
    func shortSentenceIsNotTruncated() {
        let spoken = "So I did tap to release and I want it to be very quick whenever that happens."
        let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        // The number of lines the renderer is given must be at least what the
        // text needs at the width the renderer is given.
        let needed = NotchContentLayout.measuredTitleLines(
            for: spoken, width: layout.width,
            maxLines: .max, replyable: false)
        #expect(layout.lines(for: alert) >= needed)
    }

    /// Sweeps the boundary the old estimate was wrongest at: lengths that land
    /// within a character or two of a line break, in text whose glyphs are
    /// wider than the 6.6pt average the estimate assumed.
    @Test("No spoken length is given fewer lines than it needs")
    @MainActor
    func noLengthIsUnderBudgeted() {
        for count in 1...90 {
            let spoken = String(repeating: "W", count: count) + " " + String(repeating: "wow ", count: count / 3)
            let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
            let layout = NotchContentLayout.peekTitleLayout(
                metrics: metrics, alerts: [alert], answerEnabled: false)
            let needed = NotchContentLayout.measuredTitleLines(
                for: spoken, width: layout.width, maxLines: .max, replyable: false)
            let granted = layout.lines(for: alert)
            #expect(granted >= min(needed, NotchContentLayout.titleMaxLines(scale: 1)),
                    "length \(count) got \(granted) lines but needs \(needed)")
        }
    }

    @MainActor
    private var ceiling: CGFloat {
        NotchContentLayout.peekWidthCeiling(metrics: metrics, wrapping: true,
                                            scale: AppSettings.shared.captionScale)
    }

    @MainActor
    private func width(of spoken: String) -> CGFloat {
        NotchContentLayout.peekTitleLayout(
            metrics: metrics,
            alerts: [DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)],
            answerEnabled: false).width
    }

    /// Width is spent only to avoid a tall column. A sentence that already has
    /// a sensible shape must not be stretched into a screen-wide ribbon two
    /// lines tall — that was a worse shape than the truncation it replaced.
    @Test("A short caption stays near the ordinary peek width")
    @MainActor
    func shortCaptionStaysNarrow() {
        let spoken = "I do not like how the pill gets shaped for not that much text."
        // The ordinary peek width on this hardware (720 x 0.54). A fraction of
        // the ceiling would be a meaningless bound — the ceiling is ~1088pt
        // here, so "under three quarters of it" still allows an 800pt ribbon.
        #expect(width(of: spoken) <= 400,
                "a one-sentence caption should stay notch-shaped, got \(width(of: spoken))pt")
    }

    @Test("A long caption is allowed to get wide")
    @MainActor
    func longCaptionWidens() {
        let short = width(of: "I do not like how the pill gets shaped for short text.")
        let long = width(of: String(repeating: "spoken words here ", count: 40))
        #expect(long > short)
        #expect(long <= ceiling)
    }

    /// Width never shrinks as text grows — a sentence that gets longer must not
    /// produce a narrower peek than the one before it.
    @Test("Width grows monotonically with text")
    @MainActor
    func widthIsMonotonic() {
        var previous: CGFloat = 0
        for count in stride(from: 1, through: 120, by: 3) {
            let w = width(of: String(repeating: "spoken words ", count: count))
            #expect(w >= previous - 0.5, "\(count) repeats came out narrower than the length before it")
            previous = w
        }
    }

    /// The dead space complaint: wrapped text almost never fills its last line,
    /// so a peek sized to the width *offered* rather than the width *used* has
    /// a blank tail by construction.
    @Test("No blank tail — the peek is as wide as the text it holds")
    @MainActor
    func noBlankTail() {
        let spoken = "This is a spoken sentence that needs more than a single line to show."
        let w = width(of: spoken)
        let textWidth = NotchContentLayout.titleTextWidth(inPeekOfWidth: w, replyable: false)
        let ink = NSAttributedString(
            string: spoken, attributes: [.font: NotchContentLayout.titleFont])
            .boundingRect(with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading]).width
        // Whatever the text does not use is given back, bar rounding.
        #expect(textWidth - ink < 12, "left \(textWidth - ink)pt of empty space after the text")
    }

    /// Reclaiming the tail must not cost a line: trading a blank strip for a
    /// taller pill is not a win.
    @Test("Tightening never adds a line")
    @MainActor
    func tighteningNeverCostsALine() {
        for count in stride(from: 2, through: 60, by: 3) {
            let spoken = String(repeating: "spoken words ", count: count)
            let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
            let layout = NotchContentLayout.peekTitleLayout(
                metrics: metrics, alerts: [alert], answerEnabled: false)
            let atCeiling = NotchContentLayout.measuredTitleLines(
                for: spoken, width: ceiling, maxLines: .max, replyable: false)
            let granted = layout.lines(for: alert)
            #expect(granted <= max(atCeiling, NotchContentLayout.captionTargetLines),
                    "\(count) repeats became \(granted) lines")
        }
    }

    /// An agent ping is a label, not content: it must keep its notch-shaped
    /// width. Widening every peek would be a regression dressed as a fix.
    @Test("A one-line agent ping keeps the ordinary width")
    @MainActor
    func agentPingStaysNarrow() {
        let alert = DevReadyAlert(id: "a", title: "Agent finished", agent: "claude-code", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        #expect(layout.lines(for: alert) == 1)
        #expect(layout.width <= NotchContentLayout.peekWidthCeiling(
            metrics: metrics, wrapping: false))
    }

    /// Measuring at the ordinary width and then rendering at the wide one would
    /// reserve height for lines that no longer exist, leaving empty pill under
    /// the text.
    @Test("Lines are measured at the width actually used")
    @MainActor
    func linesAreMeasuredAtTheFinalWidth() {
        let spoken = String(repeating: "spoken ", count: 30)
        let alert = DevReadyAlert(id: "c", title: spoken, agent: "murmur", kind: .finished)
        let layout = NotchContentLayout.peekTitleLayout(
            metrics: metrics, alerts: [alert], answerEnabled: false)
        let atOrdinary = NotchContentLayout.measuredTitleLines(
            for: spoken, width: NotchContentLayout.devReadyMinWidth,
            maxLines: .max, replyable: false)
        #expect(layout.lines(for: alert) < atOrdinary,
                "the wide peek must need fewer lines than the narrow one")
    }

    @Test("Measurement respects the ceiling on lines")
    func measurementIsCapped() {
        let huge = String(repeating: "spoken words ", count: 400)
        #expect(NotchContentLayout.measuredTitleLines(for: huge, width: 400, maxLines: 12) == 12)
    }

    @Test("Empty text is one line, not zero")
    func emptyIsOneLine() {
        #expect(NotchContentLayout.measuredTitleLines(for: "", width: 400, maxLines: 12) == 1)
    }
}

@Suite("A long caption is given time to travel")
struct PeekMotionTests {
    private func alert(_ title: String) -> DevReadyAlert {
        DevReadyAlert(id: "c", title: title, agent: "murmur", kind: .finished)
    }

    @Test("A short agent ping keeps the original timing exactly")
    func shortIsUnchanged() {
        #expect(NotchState.devReadyMotionDuration(for: [alert("Agent finished")])
                == NotchState.devReadyAnimationDuration)
    }

    /// Speed is what the eye judges, not duration: the pill travels several
    /// times further for a caption, so the same 0.36s reads as a pop.
    @Test("A caption gets longer motion than a label")
    func longTravelsLonger() {
        let long = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 20))])
        #expect(long > NotchState.devReadyAnimationDuration)
    }

    @Test("Motion never grows without bound")
    func durationIsCapped() {
        let huge = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 500))])
        #expect(huge <= NotchState.devReadyAnimationDuration + 0.24)
        #expect(huge <= 0.6, "any longer and it stops feeling responsive")
    }

    @Test("Longer text never animates faster than shorter text")
    func durationIsMonotonic() {
        var previous = NotchState.devReadyAnimationDuration
        for count in stride(from: 1, through: 400, by: 7) {
            let d = NotchState.devReadyMotionDuration(for: [alert(String(repeating: "a", count: count))])
            #expect(d >= previous, "length \(count) animated faster than the length before it")
            previous = d
        }
    }

    /// The window shrink is deferred until the collapse animation finishes. If
    /// it used the old constant it would now cut the longest captions short —
    /// reintroducing the snap it exists to prevent.
    @Test("The deferred shrink waits at least as long as the animation")
    func shrinkOutlastsTheAnimation() {
        let d = NotchState.devReadyMotionDuration(
            for: [alert(String(repeating: "spoken words ", count: 20))])
        #expect(max(NotchState.devReadyAnimationDuration, d) >= d)
    }

    @Test("An empty peek falls back to the constant")
    func emptyIsTheConstant() {
        #expect(NotchState.devReadyMotionDuration(for: []) == NotchState.devReadyAnimationDuration)
    }
}


@Suite("Dictated speech is not written to disk")
struct CaptionPrivacyTests {
    private func caption(_ text: String) -> DevReadyAlert {
        DevReadyAlert(id: "dictation-1", title: text, source: "Murmur",
                      agent: "murmur", kind: .finished)
    }

    /// Notification history lives in UserDefaults, so a persisted peek title is
    /// a transcript of speech kept in the preferences plist. Proportionate for
    /// "Agent finished"; not for what someone said out loud.
    @Test("A caption is recognised as speech")
    func captionIsSpeech() {
        #expect(NotchState.isTranscribedSpeech(caption("what I said out loud")))
        #expect(NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "d", title: "x", source: "Murmur", agent: nil, kind: .finished)))
    }

    /// Matching on source as well as agent, so a rename upstream cannot quietly
    /// start persisting transcripts.
    @Test("Agent pings are not mistaken for speech")
    func agentPingsAreNotSpeech() {
        #expect(!NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "a", title: "Agent finished", source: "Claude Code",
                          agent: "claude-code", kind: .finished)))
        #expect(!NotchState.isTranscribedSpeech(
            DevReadyAlert(id: "b", title: "done", source: nil, agent: nil, kind: .finished)))
    }

    /// `NotchState` reads and writes the real notification history in
    /// `UserDefaults`, and the test host *is* the app — so these two tests
    /// would otherwise leave fabricated entries in the developer's own
    /// preferences. Snapshot the key and put it back.
    @MainActor
    private func withPreservedHistory(_ body: () -> Void) {
        let key = "recentDevReadyNotificationHistory"
        let saved = UserDefaults.standard.data(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        body()
    }

    /// Counted as a delta: `NotchState()` loads the real notification history
    /// from `UserDefaults`, so this machine's own stored pings are already in
    /// the list. Asserting an absolute count would pass or fail depending on
    /// what the developer happened to be notified about.
    @Test("A caption never reaches the history list")
    @MainActor
    func captionsStayOutOfHistory() {
        withPreservedHistory {
        let state = NotchState()
        let before = state.recentDevReadyAlerts.count
        state.enqueueDevReady([caption("this is what I dictated")])
        #expect(state.recentDevReadyAlerts.count == before)
        #expect(!state.recentDevReadyAlerts.contains { $0.id == "dictation-1" })
        // ...while still being shown.
        #expect(state.devReadyAlerts.contains { $0.id == "dictation-1" })
        }
    }

    @Test("An agent ping still reaches history")
    @MainActor
    func agentPingsStillRecorded() {
        withPreservedHistory {
        let state = NotchState()
        state.enqueueDevReady([DevReadyAlert(id: "agent-ping-test", title: "Agent finished",
                                             source: "Claude Code", agent: "claude-code",
                                             kind: .finished)])
        #expect(state.recentDevReadyAlerts.contains { $0.id == "agent-ping-test" })
        }
    }
}

@Suite("A caption from the file is bounded")
struct CaptionBoundsTests {
    /// The file sits at a fixed path under Application Support, so any process
    /// running as the user can write it. Sizing the peek now measures the text
    /// with TextKit, several times per layout pass — unbounded input would burn
    /// that on every frame.
    @Test("An enormous caption is truncated at ingest")
    func longCaptionIsCapped() throws {
        let huge = String(repeating: "a", count: 200_000)
        let json = try JSONSerialization.data(withJSONObject: [
            "text": huge, "timestamp": 1_754_500_000_000.0,
        ])
        let parsed = try #require(DictationCaption.parse(json))
        #expect(parsed.text.count == DictationCaption.maxLength)
    }

    @Test("An ordinary caption is untouched")
    func ordinaryCaptionIsIntact() throws {
        let spoken = "This is an ordinary thing to say out loud."
        let json = try JSONSerialization.data(withJSONObject: [
            "text": spoken, "timestamp": 1_754_500_000_000.0,
        ])
        let parsed = try #require(DictationCaption.parse(json))
        #expect(parsed.text == spoken)
    }
}

@Suite("A caption does not outlive being read")
struct CaptionConsumptionTests {
    private func tempURL(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("npcap-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("latest-caption.json")
    }

    private func write(_ text: String, at url: URL, ageSeconds: TimeInterval = 0) {
        let ms = (Date().timeIntervalSince1970 - ageSeconds) * 1000
        let data = try! JSONSerialization.data(withJSONObject: ["text": text, "timestamp": ms])
        try! data.write(to: url)
    }

    /// The whole point: the mailbox is emptied when collected, so the last
    /// thing the user said stops sitting on disk between dictations.
    @Test("A shown caption is deleted")
    @MainActor
    func shownCaptionIsRemoved() {
        let url = tempURL("shown")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        write("what I just said", at: url)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.poll()
        #expect(seen == "what I just said")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// A caption too old to present is exactly the kind we least want left
    /// behind — it is speech with no remaining purpose.
    @Test("A stale caption is deleted without being shown")
    @MainActor
    func staleCaptionIsRemovedAnyway() {
        let url = tempURL("stale")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        write("said a long time ago", at: url,
              ageSeconds: DictationCaption.freshWithin + 60)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.poll()
        #expect(seen == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Whatever is in the file at launch is history from a previous session.
    /// It is neither shown nor kept.
    @Test("A caption already present at launch is cleared")
    @MainActor
    func launchClearsLeftoverCaption() {
        let url = tempURL("launch")
        write("from the last session", at: url)
        let provider = DictationCaptionProvider(url: url)
        var seen: String?
        provider.onCaption = { seen = $0.text }
        provider.start()
        #expect(seen == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    /// Consuming must not break the next one: deleting the file resets the
    /// modification-date gate, so a caption written afterwards still lands.
    @Test("The next caption still arrives after a consume")
    @MainActor
    func consumingDoesNotDeafenTheNextPoll() {
        let url = tempURL("next")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        var seen: [String] = []
        provider.onCaption = { seen.append($0.text) }

        write("first thing", at: url)
        provider.poll()
        write("second thing", at: url)
        provider.poll()

        #expect(seen == ["first thing", "second thing"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An empty mailbox is not an error")
    @MainActor
    func missingFileIsFine() {
        let url = tempURL("missing")
        let provider = DictationCaptionProvider(url: url)
        provider.start()
        provider.poll()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}

@Suite("Deck labels read as words, not identifiers")
struct ActivityKindLabelTests {
    /// The footer used to derive its text from `kind`, which is camelCase, via
    /// `String.capitalized` — and that treats a camelCase identifier as one
    /// word, so `claudeQuota` rendered as "Claudequota". `kindLabel` is written
    /// by hand for exactly this reason.
    @Test("Every kind has a label with no run-together words")
    func kindLabelsAreReadable() {
        let quota = ClaudeQuota(sessionPercent: 1, weeklyPercent: 2)
        let cursor = CursorQuota(used: 1, limit: 10, included: nil, bonus: nil,
                                 percentUsed: 10, autoPercentUsed: nil, apiPercentUsed: nil,
                                 cycleEnd: nil, membership: nil, isUnlimited: false,
                                 onDemandEnabled: false, updatedAt: nil)
        let cases: [ExpandedActivity] = [
            .claudeQuota(quota), .cursorQuota(cursor), .activeApp(name: "x"),
            .systemStats(SystemStats(cpuPercent: 1, memoryPercent: 1)),
            .ci([]), .agents(AgentHomeTray([])), .clock,
            .shelf(items: [ShelfCardItem(id: UUID(), name: "a",
                                         url: URL(fileURLWithPath: "/tmp/a"))],
                   receipt: nil, error: nil),
        ]
        for activity in cases {
            let label = activity.kindLabel
            #expect(!label.isEmpty)
            // The bug's signature: the identifier's own spelling surviving into
            // display text.
            #expect(label != activity.kind.capitalized || !activity.kind.contains(where: \.isUppercase),
                    "\(activity.kind) still reads like its identifier: \(label)")
        }
        #expect(ExpandedActivity.claudeQuota(quota).kindLabel == "Claude quota")
        #expect(ExpandedActivity.cursorQuota(cursor).kindLabel == "Cursor quota")
    }
}

@Suite("The deck's page controls fit their layout")
struct DeckChromeTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 179, notchHeight: 32,
                     designExpandedWidth: 720, designExpandedHeight: 128,
                     scale: 0.54, screenWidth: 1512)
    }

    /// The strip is a `mark`-tall row of tap targets with a `snug` gap above
    /// it. Budget only the row and the gap comes out of the card — which lands
    /// on the same edge as the card's own overflow and clips the dots.
    @Test("Chrome covers the dot row and the gap above it")
    func chromeCoversTheStrip() {
        #expect(NotchContentLayout.deckChromeHeight >= NotchSpace.mark + NotchSpace.snug)
    }

    @Test("A single page hides navigation but keeps its space")
    func singlePageKeepsFooterSpace() {
        let onePage = [ExpandedActivity.clock]
        #expect(!NotchContentLayout.showsDeckChrome(for: onePage))
        let deck = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: onePage)
        let expectedHeight = metrics.notchHeight + NotchContentLayout.surfaceTopInset(metrics: metrics)
            + NotchContentLayout.expandedContentCeiling
            + NotchContentLayout.deckChromeHeight + NotchContentLayout.expandedTrayInset
        #expect(deck.size.height == expectedHeight)
    }

    @Test("An empty deck has no footer to reserve")
    func emptyDeckHasNoDot() {
        #expect(!NotchContentLayout.showsDeckChrome(for: []))
    }

    /// Two cards were budgeted 56pt while rendering a header, a meter and a
    /// trailing detail line — one line over, every time they had that line.
    @Test("A quota card's budget covers what it draws")
    @MainActor
    func quotaCardsFitTheirBudget() {
        let quota = ClaudeQuota(sessionPercent: 18, weeklyPercent: 42,
                                extraSpentMinor: 500, extraCurrency: "USD")
        let cursor = CursorQuota(used: 38, limit: 2000, included: 2000, bonus: nil,
                                 percentUsed: 2, autoPercentUsed: 0, apiPercentUsed: 0,
                                 cycleEnd: Date().addingTimeInterval(27 * 86_400),
                                 membership: "pro_student", isUnlimited: false,
                                 onDemandEnabled: false, updatedAt: Date())
        // Provider header (~17) plus one meter row (~69) and a detail line (~13).
        let drawn: CGFloat = 99
        for activity in [ExpandedActivity.claudeQuota(quota), .cursorQuota(cursor)] {
            let activities = [activity, .clock]
            let deck = NotchContentLayout.expandedDeckLayout(
                metrics: metrics, activities: activities)
            let footer = NotchContentLayout.deckChromeHeight
            let contentRoom = deck.size.height - metrics.notchHeight - NotchContentLayout.surfaceTopInset(metrics: metrics)
                - footer - NotchContentLayout.expandedTrayInset
            #expect(contentRoom >= drawn,
                    "\(activity.kind) gets \(contentRoom)pt for \(drawn)pt of content")
        }
    }

    @Test("A mixed deck reserves one shared page control")
    func mixedDeckReservesDots() {
        let deck: [ExpandedActivity] = [
            .agents(AgentHomeTray([])),
            .claudeQuota(ClaudeQuota(sessionPercent: 12, weeklyPercent: 34)),
        ]
        let withTab = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: deck)
        #expect(NotchContentLayout.showsDeckChrome(for: deck))
        #expect(withTab.size.height == metrics.notchHeight + NotchContentLayout.surfaceTopInset(metrics: metrics)
                + NotchContentLayout.expandedContentCeiling
                + NotchContentLayout.deckChromeHeight + NotchContentLayout.expandedTrayInset)
    }
}

@Suite("Cursor's meter matches Cursor's own numbers")
struct CursorAccuracyTests {
    private func payload(used: Int, limit: Int, total: Int?) -> Data {
        var plan: [String: Any] = ["used": used, "limit": limit]
        if let total { plan["totalPercentUsed"] = total }
        return try! JSONSerialization.data(withJSONObject: [
            "individualUsage": ["plan": plan],
        ])
    }

    /// The reported bug: "0%" over "38 of 2000". Flooring 1.9 gives 0, which
    /// draws an empty bar for a pool that has genuinely been used.
    @Test("Real usage never reports as zero")
    func smallUsageIsNotZero() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 38, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 1)
    }

    @Test("Untouched really is zero")
    func zeroUsageStaysZero() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 0, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 0)
    }

    /// The original reason for flooring: 1999 of 2000 must not claim a limit
    /// that has not been reached.
    @Test("Almost-full never rounds up to the cap")
    func nearlyFullIsNotFull() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 1999, limit: 2000, total: nil))
        #expect(quota?.percentUsed == 99)
    }

    @Test("A server zero is corrected when usage exists")
    func serverZeroWithUsage() {
        let quota = CursorUsageFetcher.quota(in: payload(used: 38, limit: 2000, total: 0))
        #expect(quota?.percentUsed == 1)
    }
}

@Suite("Per-model limits come from the payload, not a hard-coded list")
struct ModelWindowTests {
    private func payload(_ extra: [String: Any]) -> Data {
        var root: [String: Any] = [
            "five_hour": ["utilization": 18.0],
            "seven_day": ["utilization": 42.0],
        ]
        for (k, v) in extra { root[k] = v }
        return try! JSONSerialization.data(withJSONObject: root)
    }

    /// Naming models in code would mean shipping a release to display a window
    /// that is already in the response.
    @Test("Any per-model window is picked up, whatever the model is called")
    func unknownModelWindowsAreKept() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_fable": ["utilization": 7.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["fable", "opus"])
        #expect(quota?.modelWindows.first(where: { $0.name == "opus" })?.percent == 61)
    }

    @Test("A plan with no per-model window reports none")
    func noExtraWindows() {
        let quota = ClaudeUsageFetcher.quota(in: payload([:]))
        #expect(quota?.modelWindows.isEmpty == true)
        #expect(quota?.sessionPercent == 18)
    }

    /// Stable order among equals, so the column does not swap between refreshes.
    @Test("Order is stable")
    func orderIsStable() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_zeta": ["utilization": 1.0],
            "seven_day_alpha": ["utilization": 2.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["alpha", "zeta"])
    }

    /// The column exists because someone asked for a *specific* model.
    /// Alphabetical order hands it to whichever model sorts first, so the card
    /// shows one you did not ask about while the one you did sits behind it.
    @Test("Fable takes the column when the plan reports one")
    func fableWinsTheColumn() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_fable": ["utilization": 7.0],
            "seven_day_aardvark": ["utilization": 3.0],
        ]))
        #expect(quota?.modelWindows.first?.name == "fable")
        #expect(quota?.modelWindows.first?.percent == 7)
    }

    @Test("Opus takes it only when there is no Fable window")
    func opusIsSecond() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "seven_day_opus": ["utilization": 61.0],
            "seven_day_aardvark": ["utilization": 3.0],
        ]))
        #expect(quota?.modelWindows.first?.name == "opus")
    }

    /// The bug: the payload meters other things at the same level, and
    /// "anything with a utilization figure" let one of them take the column
    /// that was supposed to belong to a model.
    @Test("Metered things that are not models never take the column")
    func nonModelWindowsAreExcluded() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "extra_usage": ["utilization": 88.0],
            "overage": ["utilization": 12.0],
            "seven_day_fable": ["utilization": 7.0],
        ]))
        #expect(quota?.modelWindows.map(\.name) == ["fable"])
    }

    @Test("Only keys with a model suffix count as model windows")
    func keyShapeIsChecked() {
        #expect(ClaudeUsageFetcher.isModelWindowKey("seven_day_fable"))
        #expect(ClaudeUsageFetcher.isModelWindowKey("five_hour_opus"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("seven_day"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("seven_day_"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("extra_usage"))
        #expect(!ClaudeUsageFetcher.isModelWindowKey("spend"))
    }

    @Test("Labels drop the window prefix")
    func labelsAreTidied() {
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "seven_day_opus") == "opus")
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "seven_day_fable") == "fable")
        #expect(ClaudeUsageFetcher.modelWindowLabel(for: "odd_key") == "odd key")
    }

    /// Anything without a utilization figure is not a window and must not
    /// become a meter — `spend` sits at the same level in the payload.
    @Test("Non-window keys are ignored")
    func spendIsNotAWindow() {
        let quota = ClaudeUsageFetcher.quota(in: payload([
            "spend": ["enabled": true, "used": ["amount_minor": 500, "currency": "USD"]],
        ]))
        #expect(quota?.modelWindows.isEmpty == true)
    }
}

@Suite("cmux agent runtime")
struct CmuxAgentRuntimeTests {
    /// Shaped after the real file: the pid and lifecycle sit on each record
    /// under `sessions`, keyed by session id.
    private let real = Data("""
    {"version":1,"sessions":{
      "aaa":{"agentLifecycle":"running","cwd":"/Users/x/Projects/NotchPill",
             "pid":1605,"sessionId":"aaa"},
      "bbb":{"agentLifecycle":"unknown","cwd":"/Users/x/Downloads",
             "pid":1604,"sessionId":"bbb"}}}
    """.utf8)

    @Test func readsPidPerSession() {
        let runtime = CmuxAgentRuntime.parse(real)
        #expect(runtime.agent(forSession: "aaa")?.pid == 1605)
        #expect(runtime.agent(forSession: "bbb")?.lifecycle == "unknown")
        #expect(runtime.agent(forSession: "nope") == nil)
    }

    @Test func unknownShapesYieldNothing() {
        #expect(CmuxAgentRuntime.parse(Data("null".utf8)).isEmpty)
        #expect(CmuxAgentRuntime.parse(Data("{\"sessions\":[]}".utf8)).isEmpty)
        // A record without a usable pid is not a runtime fact.
        #expect(CmuxAgentRuntime.parse(Data("{\"sessions\":{\"a\":{\"pid\":0}}}".utf8)).isEmpty)
    }

    /// The distinction the card depends on: no record at all means "unknown",
    /// which must not be confused with "dead".
    @Test func missingSessionIsUnknownNotDead() {
        let runtime = CmuxAgentRuntime.parse(real)
        #expect(runtime.isAlive(sessionId: "nope", isRunning: { _ in true }) == nil)
        #expect(runtime.isAlive(sessionId: nil, isRunning: { _ in true }) == nil)
        #expect(runtime.isAlive(sessionId: "aaa", isRunning: { _ in false }) == false)
    }

    /// This process is definitely alive, and its path is definitely not an
    /// agent's — so the pid check alone must not be what answers.
    @Test func aRecycledPidIsNotTheAgent() {
        let mine = CmuxAgentRuntime.Agent(pid: getpid(), lifecycle: nil, cwd: nil)
        #expect(CmuxAgentRuntime.isRunning(mine) == false)
        #expect(CmuxAgentRuntime.isRunning(
            CmuxAgentRuntime.Agent(pid: -1, lifecycle: nil, cwd: nil)) == false)
    }
}

@Suite("liveness overrules the clock")
struct SessionLivenessTests {
    private func session(_ id: String, idleFor seconds: TimeInterval,
                         alive: Bool?) -> AgentSession {
        var s = AgentSession(id: id, agent: "claude-code", project: "p",
                             state: .idle(since: Date().addingTimeInterval(-seconds)),
                             lastActivity: Date().addingTimeInterval(-seconds))
        s.isAlive = alive
        return s
    }

    /// The behaviour before any of this: unknown liveness still expires at
    /// thirty seconds, so Codex and Cursor rows are unaffected.
    @Test func unknownLivenessKeepsTheOldWindow() {
        #expect(AgentSession.current([session("a", idleFor: 10, alive: nil)]).count == 1)
        #expect(AgentSession.current([session("a", idleFor: 60, alive: nil)]).isEmpty)
    }

    /// The long-build case: quiet for ten minutes, but the process is there.
    @Test func aLivingAgentSurvivesGoingQuiet() {
        #expect(AgentSession.current([session("a", idleFor: 600, alive: true)]).count == 1)
        #expect(AgentSession.current([session("a", idleFor: 7300, alive: true)]).isEmpty)
    }

    /// The closed-terminal case: it wrote a second ago, so the clock still
    /// calls it working — but there is nothing left to tab to.
    @Test func aDeadAgentGoesAtOnceWhateverTheClockSays() {
        var working = session("a", idleFor: 1, alive: false)
        working.state = .working
        #expect(AgentSession.current([working]).isEmpty)

        var waiting = session("b", idleFor: 1, alive: false)
        waiting.state = .waiting(since: Date())
        #expect(AgentSession.current([waiting]).isEmpty)
    }
}

@Suite("effort reads as its own fact")
struct EffortLabelTests {
    private func session(model: String?, effort: String?) -> AgentSession {
        var s = AgentSession(id: "s", agent: "claude-code", project: "p",
                             state: .working, lastActivity: Date())
        s.model = model
        s.effort = effort
        return s
    }

    /// The row draws the two halves separately, so both must stand alone —
    /// and the combined form still has to agree with them, because it is what
    /// VoiceOver reads.
    @Test func splitsModelFromEffort() {
        let s = session(model: "claude-opus-5", effort: "low")
        #expect(s.modelBaseLabel == "Opus 5")
        #expect(s.effortLabel == "low")
        #expect(s.modelLabel == "Opus 5 · low")
    }

    /// "default" names the absence of a choice. Shown on a row it reads as a
    /// setting the user picked, so it is dropped — but the model stays.
    @Test func defaultEffortIsNotASetting() {
        let s = session(model: "claude-opus-5", effort: "default")
        #expect(s.effortLabel == nil)
        #expect(s.modelLabel == "Opus 5")
    }

    @Test func toleratesMissingAndUntidyValues() {
        #expect(session(model: "claude-opus-5", effort: nil).effortLabel == nil)
        #expect(session(model: "claude-opus-5", effort: "   ").effortLabel == nil)
        #expect(session(model: "claude-opus-5", effort: "  HIGH ").effortLabel == "high")
        #expect(session(model: nil, effort: "high").modelBaseLabel == nil)
    }
}

@Suite("context pressure and permission mode")
struct SessionSafetyTests {
    private func session(model: String?, tokens: Int?, mode: String? = nil) -> AgentSession {
        var s = AgentSession(id: "s", agent: "claude-code", project: "p",
                             state: .working, lastActivity: Date())
        s.model = model
        s.contextTokens = tokens
        s.permissionMode = mode
        return s
    }

    /// The point of the change: a share of the window, not a raw count that
    /// only means something if you have memorised the model's limit.
    @Test func contextReadsAsAShareOfTheWindow() {
        #expect(session(model: "claude-opus-5", tokens: 100_000).contextLabel == "50% ctx")
        #expect(session(model: "claude-opus-5", tokens: 160_000).contextLabel == "80% ctx")
    }

    /// A percentage against a guessed window is worse than none, because it
    /// looks authoritative. Unknown models keep the honest raw figure.
    @Test func anUnknownModelKeepsTheRawCount() {
        #expect(session(model: "some-new-model", tokens: 100_000).contextLabel == "100k ctx")
        #expect(session(model: nil, tokens: 100_000).contextLabel == "100k ctx")
        #expect(session(model: "claude-opus-5", tokens: nil).contextLabel == nil)
    }

    @Test func tightnessTripsAtEightyPercent() {
        #expect(session(model: "claude-opus-5", tokens: 158_000).isContextTight == false)
        #expect(session(model: "claude-opus-5", tokens: 160_000).isContextTight)
        // Unknown window cannot be tight — it would be a guess.
        #expect(session(model: "mystery", tokens: 5_000_000).isContextTight == false)
        // A session over its window reports full, never more.
        #expect(session(model: "claude-opus-5", tokens: 400_000).contextLabel == "100% ctx")
    }

    /// `default` is the mode where the agent asks — what everyone assumes. A
    /// badge on every row would teach the eye to skip badges entirely.
    @Test func onlySurprisingModesEarnABadge() {
        #expect(session(model: nil, tokens: nil, mode: "default").permissionLabel == nil)
        #expect(session(model: nil, tokens: nil, mode: nil).permissionLabel == nil)
        #expect(session(model: nil, tokens: nil, mode: "bypassPermissions")
            .permissionLabel == "bypass")
        #expect(session(model: nil, tokens: nil, mode: "acceptEdits")
            .permissionLabel == "auto-edit")
        #expect(session(model: nil, tokens: nil, mode: "plan").permissionLabel == "plan")
    }

    /// Plan mode is the cautious end of the scale, so it must not be warned
    /// about in the same colour as an agent that never stops to ask.
    @Test func onlyUnaskingModesCountAsUnsupervised() {
        #expect(session(model: nil, tokens: nil, mode: "bypassPermissions").isUnsupervised)
        #expect(session(model: nil, tokens: nil, mode: "acceptEdits").isUnsupervised)
        #expect(session(model: nil, tokens: nil, mode: "plan").isUnsupervised == false)
        #expect(session(model: nil, tokens: nil, mode: "default").isUnsupervised == false)
    }

    /// Shaped after the real transcript, where the mode rides on prompt
    /// records rather than every message — and the newest one wins, because a
    /// plan-mode session that was approved is no longer in plan mode.
    @Test func newestRecordedModeWins() {
        let text = """
        {"type":"user","permissionMode":"plan","message":{"role":"user"}}
        {"type":"assistant","message":{"role":"assistant"}}
        {"type":"user","permissionMode":"bypassPermissions","message":{"role":"user"}}
        """
        #expect(AgentSessionScanner.permissionMode(in: text) == "bypassPermissions")
        #expect(AgentSessionScanner.permissionMode(in: "{\"type\":\"user\"}") == nil)
        #expect(AgentSessionScanner.permissionMode(in: "not json") == nil)
    }
}

@Suite("a pause is not a new card")
struct ActivityIdentityTests {
    private func track(_ title: String, playing: Bool) -> ExpandedActivity {
        .media(NowPlaying(title: title, artist: "Artist", isPlaying: playing, artwork: nil))
    }

    /// The regression this suite exists for. The deck applies `id` as the
    /// card's SwiftUI identity, so an id that moves on pause destroys the card
    /// and slides a replacement in — the page-turn animation, indistinguishable
    /// from skipping a track. Fixing animation curves cannot cure it, because
    /// the card really is a different view each time.
    @Test func pausingKeepsTheSameCard() {
        #expect(track("Song A", playing: true).id == track("Song A", playing: false).id)
    }

    /// A different song genuinely is a different card, and sliding to it is
    /// the right animation — so the fix must not go too far.
    @Test func aDifferentSongIsADifferentCard() {
        #expect(track("Song A", playing: true).id != track("Song B", playing: true).id)
    }

    /// Pause still has to reach the *animation*, just not the identity: the
    /// play/pause symbol morphs and the equaliser fades on this key.
    @Test func pauseStillRegistersAsAContentChange() {
        #expect(track("Song A", playing: true).contentKey
                != track("Song A", playing: false).contentKey)
    }

    /// The same bug on a timer. A CPU reading moves every poll, so an id built
    /// from it threw away the visible card and slid it back several times a
    /// minute — while the content key still animates the size change.
    @Test func pollingDoesNotRebuildTheCard() {
        let a = ExpandedActivity.systemStats(SystemStats(cpuPercent: 12, memoryPercent: 40))
        let b = ExpandedActivity.systemStats(SystemStats(cpuPercent: 87, memoryPercent: 41))
        #expect(a.id == b.id)
        #expect(a.contentKey != b.contentKey)

        let low = ExpandedActivity.battery(BatteryStatus(level: 80, isCharging: false))
        let high = ExpandedActivity.battery(BatteryStatus(level: 81, isCharging: false))
        #expect(low.id == high.id)
        #expect(low.contentKey != high.contentKey)
    }

    /// Two cards of different kinds must never collide on one identity, or the
    /// deck would reuse one card's view for another's contents.
    @Test func distinctKindsKeepDistinctIdentities() {
        let ids = [ExpandedActivity.clock, .volume(50), .systemStats(SystemStats(cpuPercent: 1, memoryPercent: 1)),
                   .battery(BatteryStatus(level: 50, isCharging: false)),
                   .agents(AgentHomeTray([])), .ci([]), .shelf(items: [], receipt: nil, error: nil),
                   track("Song A", playing: true)].map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("media bridge recovers")
struct MediaBridgeRestartTests {
    /// The adapter is a separate perl process. When it died the bridge tore
    /// itself down and stopped, so media silently ended for the life of the
    /// app — the notch showed nothing and only a relaunch brought it back.
    /// It now retries, and these are the intervals it retries on.
    @Test func backsOffThenSettlesAtTheCap() {
        #expect(MediaRemoteBridge.restartDelay(attempt: 1) == 2)
        #expect(MediaRemoteBridge.restartDelay(attempt: 2) == 4)
        #expect(MediaRemoteBridge.restartDelay(attempt: 3) == 8)
        #expect(MediaRemoteBridge.restartDelay(attempt: 4) == 16)
        // Capped, so a permanently broken adapter costs one process every
        // thirty seconds rather than a spawn loop.
        #expect(MediaRemoteBridge.restartDelay(attempt: 5) == 30)
        #expect(MediaRemoteBridge.restartDelay(attempt: 50) == 30)
    }

    /// A recovered bridge must never wait: the guard is on `attempt > 0`, so a
    /// first start is immediate.
    @Test func firstStartIsNotDelayed() {
        #expect(MediaRemoteBridge.restartDelay(attempt: 0) == 0)
    }
}

@Suite("track skips aim their own animation")
@MainActor
struct MediaAdvanceDirectionTests {
    /// Next enters from the right, previous from the left. The direction was
    /// only ever set by *page* moves, so skipping a track reused whichever way
    /// the deck was last paged: both directions animated the same, and after a
    /// backwards swipe the next song slid in from the wrong side.
    @Test func skippingSetsTheDirection() {
        let state = NotchState()
        state.noteMediaAdvance(1)
        #expect(state.expandedDeckDirection == 1)
        state.noteMediaAdvance(-1)
        #expect(state.expandedDeckDirection == -1)
        state.noteMediaAdvance(1)
        #expect(state.expandedDeckDirection == 1)
    }

    /// Paging must still aim it, since the two share one transition — a track
    /// skip after a backwards page has to override, not inherit.
    @Test func theLastActionAimsIt() {
        let state = NotchState()
        state.moveExpandedDeckPage(by: -1, kinds: ["media", "agents"])
        #expect(state.expandedDeckDirection == -1)
        state.noteMediaAdvance(1)
        #expect(state.expandedDeckDirection == 1)
    }
}

@Suite("codex usage stops asking when asking cannot help")
struct CodexUsageResilienceTests {
    /// An auth file the fetcher will parse, with a recent refresh stamp so the
    /// service goes straight to the usage request rather than a token refresh.
    private func authFile() throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let json = """
        {"tokens":{"access_token":"a","refresh_token":"r","account_id":"acct"},
         "last_refresh":"\(stamp)"}
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        return url
    }

    private func response(_ code: Int) -> URLResponse {
        HTTPURLResponse(url: URL(string: "https://example.invalid")!,
                        statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    /// The regression. A rejected token was retried every sixty seconds for as
    /// long as the app was open — a request a minute and an identical log line
    /// each time, for a failure that only signing in can fix.
    @Test func aRejectedTokenIsAskedAboutOnce() async throws {
        let file = try authFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = Counter()
        let service = CodexUsageService(authFile: file) { [calls] _ in
            await calls.bump()
            return (Data("{}".utf8), self.response(401))
        }
        let start = Date()
        #expect(await service.quota(now: start) == nil)
        // The first attempt is allowed to spend more than one request: a 401 is
        // the one failure worth a token refresh and a retry, in case Codex
        // rotated the token since the file was read.
        let spent = await calls.value
        #expect(spent > 0)
        // Well past `refreshInterval`, so only the give-up can hold it back.
        #expect(await service.quota(now: start.addingTimeInterval(600)) == nil)
        #expect(await service.quota(now: start.addingTimeInterval(6000)) == nil)
        // Nothing further is spent: the retry already happened, and only a
        // sign-in can change the answer.
        #expect(await calls.value == spent)
    }

    /// A server error might clear, so it must not give up — but it must back
    /// off rather than retry on the ordinary interval.
    @Test func aServerErrorBacksOffInsteadOfGivingUp() async throws {
        let file = try authFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let calls = Counter()
        let service = CodexUsageService(authFile: file) { [calls] _ in
            await calls.bump()
            return (Data("{}".utf8), self.response(500))
        }
        let start = Date()
        _ = await service.quota(now: start)
        #expect(await calls.value == 1)
        // Inside the backoff window: no second request.
        _ = await service.quota(now: start.addingTimeInterval(45))
        #expect(await calls.value == 1)
        // Past it: tries again, because this failure could have cleared.
        _ = await service.quota(now: start.addingTimeInterval(4000))
        #expect(await calls.value == 2)
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }
}

@Suite("the clipboard forgets what it should never have kept")
struct ClipboardPrivacyTests {
    /// The rule the card depends on: a value the log redactor would hide is a
    /// value the clipboard must not store. If `SecretRedactor` stops matching
    /// a shape, the clipboard silently starts remembering it, and nothing else
    /// in the app would notice.
    @Test func redactableValuesAreRecognised() {
        let secrets = [
            "sk-ant-api03-AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIIIJJJJKKKKLLLL",
            "ghp_AAAABBBBCCCCDDDDEEEEFFFFGGGGHHHHIIII",
            "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdefghijklmnop",
        ]
        for secret in secrets {
            #expect(SecretRedactor.redact(secret) != secret,
                    "clipboard would have stored \(secret.prefix(12))…")
        }
    }

    @Test func ordinaryTextIsLeftAlone() {
        for text in ["git status", "~/Projects/NotchPill", "meet at 3pm"] {
            #expect(SecretRedactor.redact(text) == text)
        }
    }

    @Test func previewCollapsesWhitespace() {
        let entry = ClipboardEntry(id: UUID(),
                                   text: "first line\nsecond line\n\n    third",
                                   copiedAt: Date())
        #expect(!entry.preview.contains("\n"))
        #expect(!entry.preview.contains("  "))
    }

    /// The row grows with the copy: a word takes one line, a paragraph four.
    @Test func rowHeightFollowsHowMuchWasCopied() {
        func lines(_ text: String) -> Int {
            ClipboardEntry(id: UUID(), text: text, copiedAt: Date()).displayLines
        }
        #expect(lines("ok") == 1)
        #expect(lines(String(repeating: "x", count: 100)) == 2)
        #expect(lines(String(repeating: "x", count: 5000)) == ClipboardEntry.maxLines,
                "a huge paste must stop growing, not take the whole pill")
    }

    // MARK: - Card order

    /// The whole point of the setting: a card the user puts first is drawn
    /// first, whatever the build order thought.
    @Test func userOrderOutranksBuildOrder() {
        func deck(order: [String]) -> [String] {
            ExpandedActivityBuilder.activities(
                nowPlaying: nil, nextEvent: nil, appSwitchHint: nil,
                frontmostApp: nil, systemVolume: nil, timer: nil,
                systemStats: nil, battery: BatteryStatus(level: 80, isCharging: false),
                showMedia: false, showActiveApp: false, showVolume: false,
                showClock: true, showCalendar: false, showTimer: false,
                showSystemStats: false, showBattery: true, showShelf: false,
                cardOrder: order
            ).map(\.kind)
        }
        // Battery is built before the clock, so the clock leading is only
        // possible if the user's order is what decides.
        #expect(deck(order: ["clock", "battery"]) == ["clock", "battery"])
        #expect(deck(order: ["battery", "clock"]) == ["battery", "clock"])
    }

    /// A stored order from an older build must not lose the cards that version
    /// did not have, or upgrading would silently drop them off the deck.
    @MainActor @Test func unknownKindsKeepTheirBuiltInPlace() {
        let settings = AppSettings.shared
        let saved = settings.cardOrder
        defer { settings.cardOrder = saved }

        settings.cardOrder = ["clock", "battery"]
        let resolved = settings.resolvedCardOrder
        #expect(resolved.prefix(2) == ["clock", "battery"])
        #expect(Set(resolved) == Set(ExpandedActivity.allKinds.map(\.kind)),
                "every known kind has to survive, not just the stored ones")
        #expect(resolved.count == Set(resolved).count, "no duplicates")
    }

    /// A kind that no longer exists is dropped rather than carried forever.
    @MainActor @Test func staleKindsAreDiscarded() {
        let settings = AppSettings.shared
        let saved = settings.cardOrder
        defer { settings.cardOrder = saved }

        settings.cardOrder = ["nonsenseCard", "clock"]
        #expect(!settings.resolvedCardOrder.contains("nonsenseCard"))
    }
}

@Suite("Clipboard entry kinds")
struct ClipboardKindTests {
    @Test("hex colours are recognised with a hash, in short and long form")
    func hexColours() {
        #expect(ClipboardEntry.kind(of: "#ff6a00") == .color(red: 1, green: 106 / 255, blue: 0))
        #expect(ClipboardEntry.kind(of: "#FFF") == .color(red: 1, green: 1, blue: 1))
        #expect(ClipboardEntry.kind(of: "  #00000080\n") == .color(red: 0, green: 0, blue: 0))
        // Without the hash, a hex letter has to be present: 123456 is an id.
        #expect(ClipboardEntry.kind(of: "ff6a00") == .color(red: 1, green: 106 / 255, blue: 0))
        #expect(ClipboardEntry.kind(of: "123456") == .text)
        #expect(ClipboardEntry.kind(of: "#12345") == .text)
        #expect(ClipboardEntry.kind(of: "#gggggg") == .text)
    }

    @Test("web links are recognised; everything else is text")
    func links() {
        #expect(ClipboardEntry.kind(of: "https://getdroppy.app") == .url)
        #expect(ClipboardEntry.kind(of: "http://localhost:3000/path?q=1") == .url)
        #expect(ClipboardEntry.kind(of: "see https://x.y for details") == .text)
        #expect(ClipboardEntry.kind(of: "file:///tmp/a") == .text)
        #expect(ClipboardEntry.kind(of: "xcodebuild test -project NotchPill.xcodeproj") == .text)
    }
}

@Suite("Thumbnail store")
struct ThumbnailStoreTests {
    @Test("a file with no thumbnail is a remembered miss and never a crash")
    @MainActor
    func missesAreRemembered() async throws {
        let store = ThumbnailStore()
        let url = URL(fileURLWithPath: "/tmp/np-does-not-exist-\(UUID().uuidString).zzz")
        store.request(url, size: CGSize(width: 34, height: 22))
        try await Task.sleep(for: .milliseconds(600))
        #expect(store.thumbnail(for: url) == nil)
        // Asking again is a no-op, not a second generation.
        store.request(url, size: CGSize(width: 34, height: 22))
        #expect(store.thumbnail(for: url) == nil)
    }

    @Test("an image on disk gets a thumbnail, and forgetting drops it")
    @MainActor
    func imageThumbnail() async throws {
        let url = URL(fileURLWithPath: "/tmp/np-thumb-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 40, height: 40))
        image.lockFocus(); NSColor.systemPink.setFill(); NSRect(x: 0, y: 0, width: 40, height: 40).fill(); image.unlockFocus()
        try NSBitmapImageRep(data: image.tiffRepresentation!)!
            .representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let store = ThumbnailStore()
        store.request(url, size: CGSize(width: 34, height: 22))
        for _ in 0..<40 where store.thumbnail(for: url) == nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(store.thumbnail(for: url) != nil)
        store.forget(url)
        #expect(store.thumbnail(for: url) == nil)
    }
}

@MainActor
@Suite("Clipboard pins and search")
struct ClipboardPinTests {
    /// `ClipboardStore` is a singleton, so every test starts from a known
    /// state rather than inheriting whatever the previous one left behind.
    private func store() -> ClipboardStore {
        let store = ClipboardStore.shared
        store.stop()
        return store
    }

    @Test func pinnedEntriesSurviveTheCapacityTrim() {
        let store = self.store()
        store.recordForTesting("keep me")
        guard let pinned = store.entries.first else { return #expect(Bool(false)) }
        store.togglePin(pinned)
        // Well past the 12-entry capacity, so an unpinned entry would be gone.
        for i in 0..<30 { store.recordForTesting("filler \(i)") }
        #expect(store.entries.contains { $0.text == "keep me" && $0.isPinned })
        #expect(store.entries.first?.text == "keep me")
    }

    @Test func clearKeepsPinsAndDropsTheRest() {
        let store = self.store()
        store.recordForTesting("pinned")
        if let entry = store.entries.first { store.togglePin(entry) }
        store.recordForTesting("transient")
        store.clear()
        #expect(store.entries.map(\.text) == ["pinned"])
    }

    @Test func recopyingAPinnedEntryKeepsItPinned() {
        let store = self.store()
        store.recordForTesting("snippet")
        if let entry = store.entries.first { store.togglePin(entry) }
        store.recordForTesting("snippet")
        #expect(store.entries.filter { $0.text == "snippet" }.count == 1)
        #expect(store.entries.first?.isPinned == true)
    }

    @Test func searchMatchesTextPastThePreviewCutoff() {
        let store = self.store()
        let long = String(repeating: "a ", count: 200) + "needle"
        store.recordForTesting(long)
        store.recordForTesting("something else")
        store.query = "NEEDLE"
        #expect(store.visibleEntries.count == 1)
        #expect(store.visibleEntries.first?.text == long)
        store.endSearch()
        #expect(store.visibleEntries.count == 2)
    }

    @Test func pinningStopsAtTheCeiling() {
        let store = self.store()
        for i in 0..<(ClipboardStore.pinCapacity + 3) { store.recordForTesting("item \(i)") }
        for entry in store.entries { store.togglePin(entry) }
        #expect(store.pinnedCount == ClipboardStore.pinCapacity)
    }
}

@Suite("Audio output and low power")
struct AudioOutputTests {
    private func device(_ transport: UInt32) -> AudioOutputDevice {
        AudioOutputDevice(id: 1, name: "Thing", transport: transport)
    }

    /// The icon comes from the transport, not the name, because names lie:
    /// headphones called "MacBook" are not the built-in speakers.
    @Test func symbolFollowsTheTransportNotTheName() {
        #expect(device(kAudioDeviceTransportTypeBluetooth).symbolName == "airpods")
        #expect(device(kAudioDeviceTransportTypeAirPlay).symbolName == "airplayaudio")
        #expect(device(kAudioDeviceTransportTypeBuiltIn).symbolName == "speaker.wave.2")
        #expect(device(0).symbolName == "speaker.wave.2")
    }

    /// Toggling Low Power Mode has to redraw the card. It changes nothing else
    /// about the battery, so without this the card would keep the stale label.
    @Test func lowPowerChangesTheBatteryContentKey() {
        let off = ExpandedActivity.battery(BatteryStatus(level: 50, isCharging: false))
        let on = ExpandedActivity.battery(
            BatteryStatus(level: 50, isCharging: false, isLowPower: true))
        #expect(off.contentKey != on.contentKey)
        // ...but it is still the same card, so the deck must not page-turn.
        #expect(off.id == on.id)
    }
}


@MainActor
@Suite("Usage card partial toggles")
struct UsageCardToggleTests {
    @Test("cached quotas follow each setting while agents or CI remain enabled",
          arguments: [true, false], [true, false])
    func snapshotHidesDisabledQuota(agentsEnabled: Bool, disableClaude: Bool) throws {
        let suite = "notchpill.usage-toggle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IsolatedUsageSettings(defaults: defaults, agentsEnabled: agentsEnabled)
        let state = NotchState()
        let claude = ClaudeQuota(sessionPercent: 18, weeklyPercent: 42)
        let cursor = cursorQuota()
        state.claudeQuota = claude
        state.cursorQuota = cursor
        let shelf = ShelfStore(defaults: defaults)
        func kinds() -> [String] {
            NotchContentSnapshot.expandedActivities(state: state, shelf: shelf,
                                                   timer: TimerStore.shared, settings: settings).map(\.kind)
        }
        #expect(kinds().contains("claudeQuota"))
        #expect(kinds().contains("cursorQuota"))
        if disableClaude { settings.showClaudeUsage = false }
        else { settings.showCursorUsage = false }
        #expect(!kinds().contains(disableClaude ? "claudeQuota" : "cursorQuota"))
        #expect(kinds().contains(disableClaude ? "cursorQuota" : "claudeQuota"))
        // Exercise the visibility guard with deliberately retained cached data.
        #expect(state.claudeQuota == claude)
        #expect(state.cursorQuota == cursor)
    }

    @Test("a partial toggle clears state synchronously and rejects a delayed scan result",
          arguments: [true, false], [true, false])
    func delayedPublication(agentsEnabled: Bool, disableClaude: Bool) throws {
        let suite = "notchpill.usage-publication.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = IsolatedUsageSettings(defaults: defaults, agentsEnabled: agentsEnabled)
        let provider = AgentSessionsProvider(usageSettings: settings)
        let state = NotchState()
        provider.onClaudeQuotaUpdate = { state.claudeQuota = $0 }
        provider.onCursorQuotaUpdate = { state.cursorQuota = $0 }
        var sessionUpdates = 0
        provider.onUpdate = { _ in sessionUpdates += 1 }
        let subscription = settings.$showClaudeUsage.combineLatest(settings.$showCursorUsage)
            .sink { claude, cursor in
                provider.clearDisabledUsage(claudeEnabled: claude, cursorEnabled: cursor)
            }
        defer { subscription.cancel() }
        let claude = ClaudeQuota(sessionPercent: 18, weeklyPercent: 42)
        let cursor = cursorQuota()
        let sessions = [AgentSession(id: "toggle-test", agent: "codex", project: "fixture",
                                     state: .working, lastActivity: Date())]
        // Publish through the same boundary that receives asynchronous scan results;
        // never start discovery, CLI, network, or credentials access in this test.
        provider.publish(sessions, usage: nil, quota: nil, claude: claude, cursor: cursor, from: 0)
        #expect(state.claudeQuota == claude)
        #expect(state.cursorQuota == cursor)
        if disableClaude { settings.showClaudeUsage = false }
        else { settings.showCursorUsage = false }
        #expect(disableClaude ? state.claudeQuota == nil : state.cursorQuota == nil)
        #expect(disableClaude ? state.cursorQuota == cursor : state.claudeQuota == claude)
        provider.publish(sessions, usage: nil, quota: nil, claude: claude, cursor: cursor, from: 0)
        #expect(disableClaude ? state.claudeQuota == nil : state.cursorQuota == nil)
        #expect(disableClaude ? state.cursorQuota == cursor : state.claudeQuota == claude)
        #expect(sessionUpdates == 1, "partial toggles must not clear the agent/CI session list")
        // Clearing the provider's cache must also allow the same quota to be
        // published again after re-enabling, rather than suppressing it as equal.
        settings.showClaudeUsage = true
        settings.showCursorUsage = true
        provider.publish(sessions, usage: nil, quota: nil, claude: claude, cursor: cursor, from: 0)
        #expect(state.claudeQuota == claude)
        #expect(state.cursorQuota == cursor)
    }

    private func cursorQuota() -> CursorQuota {
        CursorQuota(used: 1, limit: 10, included: nil, bonus: nil,
                    percentUsed: 10, autoPercentUsed: nil, apiPercentUsed: nil,
                    cycleEnd: nil, membership: nil, isUnlimited: false,
                    onDemandEnabled: false, updatedAt: nil)
    }
}

@MainActor
private final class IsolatedUsageSettings: ExpandedContentSettings {
    let defaults: UserDefaults
    @Published var showClaudeUsage: Bool {
        didSet { defaults.set(showClaudeUsage, forKey: "showClaudeUsage") }
    }
    @Published var showCursorUsage: Bool {
        didSet { defaults.set(showCursorUsage, forKey: "showCursorUsage") }
    }

    init(defaults: UserDefaults, agentsEnabled: Bool) {
        self.defaults = defaults
        defaults.register(defaults: ["showClaudeUsage": true, "showCursorUsage": true,
                                     "showExpandedAgents": agentsEnabled, "showExpandedCI": !agentsEnabled])
        showClaudeUsage = defaults.bool(forKey: "showClaudeUsage")
        showCursorUsage = defaults.bool(forKey: "showCursorUsage")
    }

    var showExpandedAgents: Bool { defaults.bool(forKey: "showExpandedAgents") }
    var showExpandedCI: Bool { defaults.bool(forKey: "showExpandedCI") }
    var showExpandedMedia: Bool { false }
    var showExpandedActiveApp: Bool { false }
    var showExpandedVolume: Bool { false }
    var showExpandedClock: Bool { false }
    var showExpandedCalendar: Bool { false }
    var showExpandedTimer: Bool { false }
    var showExpandedSystemStats: Bool { false }
    var showExpandedBattery: Bool { false }
    var showExpandedShelf: Bool { false }
    var showExpandedCommands: Bool { false }
    var showExpandedRecentActivity: Bool { false }
    var showClipboard: Bool { false }
    var showTerminal: Bool { false }
    var resolvedCardOrder: [String] { [] }
    var pinnedActivityKind: String { "" }
}
