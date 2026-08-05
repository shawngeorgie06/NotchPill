import Foundation
import SQLite3

/// Keeps a current Cursor quota, fetched from cursor.com and cached.
///
/// The third of these, and the cheapest to justify: unlike Claude the token sits
/// in a file rather than the Keychain, so reading it costs no consent prompt,
/// and unlike Codex there is no refresh to attempt. Cursor's app owns the token
/// and rewrites it on sign-in; we only ever read.
actor CursorUsageService {
    static let refreshInterval: TimeInterval = 300
    static let staleAfter: TimeInterval = 3600

    private var cached: CursorQuota?
    private var lastFetch = Date.distantPast
    /// Set once the token is missing or rejected. Both need a sign-in in the
    /// Cursor app to fix, and neither improves by being retried every 5 minutes.
    private var givenUp = false
    /// Same reasoning as the Claude service: a fixed retry into a 429 is not a
    /// retry, it is the cause of the next one.
    private var retryNoEarlierThan = Date.distantPast
    private var consecutiveFailures = 0
    static let maxBackoff: TimeInterval = 3600
    /// Where the last good answer is kept between launches, for the same
    /// reason the Claude card keeps one: a launch that opens into a failure
    /// has nothing to show, and a card that is simply absent reads as a
    /// feature that was removed rather than a number that is late.
    static let cacheKey = "cursorUsageCache"

    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let readToken: () -> String?

    init(transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         },
         readToken: @escaping () -> String? = CursorUsageService.storedToken,
         store: UserDefaults? = .standard) {
        self.transport = transport
        self.readToken = readToken
        self.store = store
        self.cached = Self.restore(from: store)
    }

    private let store: UserDefaults?

    /// Counts and a timestamp. Nothing identifying, no token, and nothing that
    /// is not already on screen.
    static func restore(from store: UserDefaults?) -> CursorQuota? {
        guard let raw = store?.dictionary(forKey: cacheKey),
              let used = raw["used"] as? Int,
              let limit = raw["limit"] as? Int,
              let percent = raw["percent"] as? Int,
              let stamp = raw["at"] as? Double else { return nil }
        return CursorQuota(used: used, limit: limit, included: nil,
                           bonus: raw["bonus"] as? Int,
                           percentUsed: percent,
                           autoPercentUsed: raw["auto"] as? Int,
                           apiPercentUsed: raw["api"] as? Int,
                           cycleEnd: (raw["cycleEnd"] as? Double)
                               .map(Date.init(timeIntervalSince1970:)),
                           membership: raw["membership"] as? String,
                           isUnlimited: (raw["unlimited"] as? Bool) ?? false,
                           onDemandEnabled: (raw["onDemand"] as? Bool) ?? false,
                           updatedAt: Date(timeIntervalSince1970: stamp))
    }

    private func persist(_ quota: CursorQuota) {
        var payload: [String: Any] = [
            "used": quota.used, "limit": quota.limit, "percent": quota.percentUsed,
            "unlimited": quota.isUnlimited, "onDemand": quota.onDemandEnabled,
            "at": (quota.updatedAt ?? Date()).timeIntervalSince1970,
        ]
        if let auto = quota.autoPercentUsed { payload["auto"] = auto }
        if let api = quota.apiPercentUsed { payload["api"] = api }
        if let bonus = quota.bonus { payload["bonus"] = bonus }
        if let membership = quota.membership { payload["membership"] = membership }
        if let cycleEnd = quota.cycleEnd { payload["cycleEnd"] = cycleEnd.timeIntervalSince1970 }
        store?.set(payload, forKey: Self.cacheKey)
    }

    static var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    /// Reads the one row we need. Read-only and via a URI, so SQLite never
    /// tries to create or recover Cursor's ~650MB database out from under it.
    nonisolated static func storedToken() -> String? {
        var db: OpaquePointer?
        let uri = "file:\(databaseURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK
        else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        // SQLITE_TRANSIENT: the key outlives this call only if SQLite copies it.
        sqlite3_bind_text(stmt, 1, CursorUsageFetcher.tokenKey, -1,
                          unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let raw = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: raw)
    }

    func quota(now: Date = Date()) async -> CursorQuota? {
        if givenUp { return nil }
        if now < retryNoEarlierThan { return servedCache(now: now) }
        if now.timeIntervalSince(lastFetch) < Self.refreshInterval { return cached }
        lastFetch = now
        do {
            let fresh = try await fetch(now: now)
            let recovered = consecutiveFailures > 0
            consecutiveFailures = 0
            retryNoEarlierThan = .distantPast
            // Logged the first time only. Silence reads the same whether the
            // fetch worked or the code never ran, and that ambiguity has cost
            // real hours on this feature already.
            // Also on the first success after a failure: gating on `cached ==
            // nil` alone stops working the moment a reading survives launches,
            // and silence reads exactly like a dead card.
            if cached == nil || recovered {
                LogStore.log("cursor", "usage \(fresh.percentUsed)% of "
                             + "\(fresh.limit) (\(fresh.membership ?? "?"))"
                             + (recovered ? " (recovered)" : ""))
            }
            cached = fresh
            persist(fresh)
            return fresh
        } catch let error as CursorUsageFetcher.FetchError {
            switch error {
            case .noCredentials:
                givenUp = true
                LogStore.log("cursor", "not signed in to Cursor")
                cached = nil
                return nil
            case .unauthorized:
                givenUp = true
                LogStore.log("cursor", "token rejected — sign in to Cursor again")
            case .rateLimited(let retryAfter):
                let wait = backoff(suggested: retryAfter, now: now)
                LogStore.log("cursor", "rate limited — next try in \(Int(wait))s")
            case .http(let code):
                let wait = backoff(suggested: nil, now: now)
                LogStore.log("cursor", "usage fetch failed: HTTP \(code)"
                             + " — next try in \(Int(wait))s")
            case .malformedResponse:
                LogStore.log("cursor", "usage fetch failed: unrecognised response")
            }
            return servedCache(now: now)
        } catch {
            // Never interpolate the error: a URLError carries the URL of a
            // request whose headers hold a session token.
            LogStore.log("cursor", "usage fetch failed: "
                         + "\((error as NSError).domain) \((error as NSError).code)")
            return servedCache(now: now)
        }
    }

    @discardableResult
    private func backoff(suggested: TimeInterval?, now: Date) -> TimeInterval {
        consecutiveFailures += 1
        let wait = suggested ?? min(Self.maxBackoff,
                                    Self.refreshInterval * pow(2, Double(consecutiveFailures)))
        retryNoEarlierThan = now.addingTimeInterval(wait)
        return wait
    }

    private func servedCache(now: Date) -> CursorQuota? {
        if let cached, let updated = cached.updatedAt,
           now.timeIntervalSince(updated) < Self.staleAfter {
            return cached
        }
        cached = nil
        return nil
    }

    private func fetch(now: Date) async throws -> CursorQuota {
        guard let token = readToken(),
              let creds = CursorUsageFetcher.credentials(token: token) else {
            throw CursorUsageFetcher.FetchError.noCredentials
        }
        let (data, response) = try await transport(CursorUsageFetcher.usageRequest(creds))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status != 401, status != 403 else {
            throw CursorUsageFetcher.FetchError.unauthorized
        }
        guard status != 429 else {
            throw CursorUsageFetcher.FetchError.rateLimited(
                retryAfter: ClaudeUsageFetcher.retryAfter(in: response as? HTTPURLResponse))
        }
        guard (200..<300).contains(status) else {
            throw CursorUsageFetcher.FetchError.http(status)
        }
        guard let quota = CursorUsageFetcher.quota(in: data, now: now) else {
            throw CursorUsageFetcher.FetchError.malformedResponse
        }
        return quota
    }
}
