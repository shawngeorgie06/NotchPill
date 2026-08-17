import Foundation
import Security

/// Keeps a current Claude quota, fetched from Anthropic and cached.
///
/// Mirrors `CodexUsageService`, with one difference that shapes the whole
/// design: the token lives in the **login Keychain**, not a file. Reading it
/// raises a macOS consent prompt the first time, so nothing here runs unless
/// the user has switched the card on. An app that asks for Keychain access for
/// a card you never requested has earned the suspicion that gets it.
actor ClaudeUsageService {
    /// Five minutes, not one.
    ///
    /// A minute was measured earning a sustained 429 from Anthropic: the app
    /// asked, was refused, backed off, asked again, and the card stayed blank
    /// because a fresh launch has no cached number to fall back on. Usage
    /// percentages do not move fast enough to be worth a per-minute request.
    static let refreshInterval: TimeInterval = 300
    static let staleAfter: TimeInterval = 3600

    private var cached: ClaudeQuota?
    /// The fetch currently running, so concurrent callers share it rather than
    /// each starting their own.
    private var inFlight: Task<ClaudeQuota?, Never>?
    private var lastFetch = Date.distantPast
    /// Where the last good answer is kept between launches.
    ///
    /// Without this, a launch that opens into a rate limit has nothing to show
    /// and the card simply is not there — which is exactly how it looked when
    /// Anthropic started refusing: the feature appeared to have been removed.
    /// A number from twenty minutes ago is far better than no card at all,
    /// provided it is not passed off as current.
    static let cacheKey = "claudeUsageCache"
    /// Set once the Keychain has refused or the token cannot read usage.
    /// Retrying either on a timer would re-prompt, or hammer a 403 that only a
    /// re-login can fix.
    private var givenUp: ClaudeUsageFetcher.FetchError?
    /// Nothing is asked before this. A 429 answered every 60s for as long as
    /// the app is open is not a retry, it is the reason for the 429.
    private var retryNoEarlierThan = Date.distantPast
    /// Doubles per consecutive failure, so a service that is down is asked
    /// about less and less rather than at a fixed drumbeat.
    private var consecutiveFailures = 0
    static let maxBackoff: TimeInterval = 1800

    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let readKeychain: () -> Data?

    init(transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         },
         readKeychain: @escaping () -> Data? = ClaudeUsageService.keychainBlob,
         store: UserDefaults? = .standard) {
        self.transport = transport
        self.readKeychain = readKeychain
        self.store = store
        self.cached = Self.restore(from: store)
    }

    private let store: UserDefaults?

    /// Percentages and the time they were taken. Nothing identifying, and no
    /// token: this is the same handful of numbers already on screen.
    static func restore(from store: UserDefaults?) -> ClaudeQuota? {
        guard let raw = store?.dictionary(forKey: cacheKey),
              let session = raw["session"] as? Int,
              let weekly = raw["weekly"] as? Int,
              let stamp = raw["at"] as? Double else { return nil }
        return ClaudeQuota(sessionPercent: session, weeklyPercent: weekly,
                           updatedAt: Date(timeIntervalSince1970: stamp))
    }

    private func persist(_ quota: ClaudeQuota) {
        store?.set(["session": quota.sessionPercent,
                    "weekly": quota.weeklyPercent,
                    "at": (quota.updatedAt ?? Date()).timeIntervalSince1970],
                   forKey: Self.cacheKey)
    }

    /// Reads the credential Claude Code stored. Returns nil when the item is
    /// missing or access was declined — both are "no usage card", neither is an
    /// error worth surfacing twice.
    nonisolated static func keychainBlob() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ClaudeUsageFetcher.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                LogStore.log("claude", "keychain read refused (OSStatus \(status))")
            }
            return nil
        }
        return item as? Data
    }

    /// One request at a time, whoever asks.
    ///
    /// The log showed four rate-limit hits and a success inside nine
    /// milliseconds, which is several requests racing each other — and being
    /// 429'd for it. `retryNoEarlierThan` cannot prevent that: every caller
    /// reads it before any of them has written, so the guard passes for all of
    /// them. An actor serialises the *state*, not a network call it awaits.
    ///
    /// So callers now share one computation. A second caller arriving mid
    /// flight waits for the first answer instead of spending another request
    /// on the same question, which also stops the duplicate log lines that
    /// made a single failure look like four.
    func quota(now: Date = Date()) async -> ClaudeQuota? {
        if let inFlight { return await inFlight.value }
        let task = Task<ClaudeQuota?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.computeQuota(now: now)
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    private func computeQuota(now: Date) async -> ClaudeQuota? {
        // A refusal is permanent until the app restarts: re-asking re-prompts.
        if let givenUp {
            _ = givenUp
            return nil
        }
        if now < retryNoEarlierThan { return servedCache(now: now) }
        if now.timeIntervalSince(lastFetch) < Self.refreshInterval { return cached }
        lastFetch = now
        do {
            let fresh = try await fetch(now: now)
            let recovered = consecutiveFailures > 0
            consecutiveFailures = 0
            retryNoEarlierThan = .distantPast
            // Logged on the first success, and on the first success after any
            // failure. Gating on `cached == nil` alone stopped working the
            // moment the last reading began surviving launches: a restored
            // value meant a real recovery logged nothing, and silence reads
            // exactly like a dead fetch. That cost an hour of chasing a rate
            // limit that had already cleared.
            if cached == nil || recovered {
                LogStore.log("claude", "usage \(fresh.sessionPercent)% session, "
                             + "\(fresh.weeklyPercent)% week"
                             + (recovered ? " (recovered)" : ""))
            }
            cached = fresh
            persist(fresh)
            return fresh
        } catch let error as ClaudeUsageFetcher.FetchError {
            switch error {
            case .noCredentials, .missingScope:
                // Nothing a retry fixes, and retrying `noCredentials` would
                // prompt for the Keychain again on every scan.
                givenUp = error
                LogStore.log("claude", error == .missingScope
                    ? "token cannot read usage (needs \(ClaudeUsageFetcher.requiredScope))"
                    : "not signed in to Claude Code")
                cached = nil
                return nil
            case .unauthorized:
                LogStore.log("claude", "token rejected — sign in to Claude Code again")
            case .rateLimited(let retryAfter):
                let wait = backoff(suggested: retryAfter, now: now)
                LogStore.log("claude", "rate limited — next try in \(Int(wait))s")
            case .http(let code):
                let wait = backoff(suggested: nil, now: now)
                LogStore.log("claude", "usage fetch failed: HTTP \(code)"
                             + " — next try in \(Int(wait))s")
            case .malformedResponse:
                LogStore.log("claude", "usage fetch failed: unrecognised response")
            }
            return servedCache(now: now)
        } catch {
            // Never interpolate the error itself: a URLError carries the URL of
            // a request whose headers hold a bearer token.
            LogStore.log("claude", "usage fetch failed: "
                         + "\((error as NSError).domain) \((error as NSError).code)")
            return servedCache(now: now)
        }
    }

    /// Sets the next allowed attempt and returns how long that is away.
    @discardableResult
    private func backoff(suggested: TimeInterval?, now: Date) -> TimeInterval {
        consecutiveFailures += 1
        // The server's own number wins when it sends one.
        let wait = suggested ?? min(Self.maxBackoff,
                                    Self.refreshInterval * pow(2, Double(consecutiveFailures)))
        retryNoEarlierThan = now.addingTimeInterval(wait)
        return wait
    }

    /// Serve the last good answer until it is too old to mean anything. Wi-Fi
    /// dropping should blank the card no sooner than the number going unknown.
    private func servedCache(now: Date) -> ClaudeQuota? {
        if let cached, let updated = cached.updatedAt,
           now.timeIntervalSince(updated) < Self.staleAfter {
            return cached
        }
        cached = nil
        return nil
    }

    private func fetch(now: Date) async throws -> ClaudeQuota {
        guard let blob = readKeychain(),
              let creds = ClaudeUsageFetcher.credentials(in: blob) else {
            throw ClaudeUsageFetcher.FetchError.noCredentials
        }
        // Checked before spending a request: a CLI token can hold only
        // `user:inference`, which talks to the model but cannot read the
        // account, and returns 403 every time.
        guard creds.hasUsageScope else { throw ClaudeUsageFetcher.FetchError.missingScope }

        let (data, response) = try await transport(ClaudeUsageFetcher.usageRequest(creds))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // No refresh is attempted. Claude Code owns this token and rotates it
        // itself; racing it would be the auth.json mistake with a Keychain
        // prompt attached. An expired token means "use Claude Code once".
        guard status != 401 else { throw ClaudeUsageFetcher.FetchError.unauthorized }
        guard status != 403 else { throw ClaudeUsageFetcher.FetchError.missingScope }
        guard status != 429 else {
            throw ClaudeUsageFetcher.FetchError.rateLimited(
                retryAfter: ClaudeUsageFetcher.retryAfter(in: response as? HTTPURLResponse))
        }
        guard (200..<300).contains(status) else {
            throw ClaudeUsageFetcher.FetchError.http(status)
        }
        guard let quota = ClaudeUsageFetcher.quota(in: data, now: now) else {
            throw ClaudeUsageFetcher.FetchError.malformedResponse
        }
        return quota
    }
}
