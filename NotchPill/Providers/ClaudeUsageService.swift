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
    static let refreshInterval: TimeInterval = 60
    static let staleAfter: TimeInterval = 3600

    private var cached: ClaudeQuota?
    private var lastFetch = Date.distantPast
    /// Set once the Keychain has refused or the token cannot read usage.
    /// Retrying either on a timer would re-prompt, or hammer a 403 that only a
    /// re-login can fix.
    private var givenUp: ClaudeUsageFetcher.FetchError?

    private let transport: (URLRequest) async throws -> (Data, URLResponse)
    private let readKeychain: () -> Data?

    init(transport: @escaping (URLRequest) async throws -> (Data, URLResponse) = {
             try await URLSession.shared.data(for: $0)
         },
         readKeychain: @escaping () -> Data? = ClaudeUsageService.keychainBlob) {
        self.transport = transport
        self.readKeychain = readKeychain
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

    func quota(now: Date = Date()) async -> ClaudeQuota? {
        // A refusal is permanent until the app restarts: re-asking re-prompts.
        if let givenUp {
            _ = givenUp
            return nil
        }
        if now.timeIntervalSince(lastFetch) < Self.refreshInterval { return cached }
        lastFetch = now
        do {
            let fresh = try await fetch(now: now)
            // Logged on success as well as failure. Silence is ambiguous — it
            // reads the same whether the fetch worked or the code never ran —
            // and that ambiguity has cost hours already today.
            if cached == nil {
                LogStore.log("claude", "usage \(fresh.sessionPercent)% session, "
                             + "\(fresh.weeklyPercent)% week")
            }
            cached = fresh
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
            case .http(let code):
                LogStore.log("claude", "usage fetch failed: HTTP \(code)")
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
        guard (200..<300).contains(status) else {
            throw ClaudeUsageFetcher.FetchError.http(status)
        }
        guard let quota = ClaudeUsageFetcher.quota(in: data, now: now) else {
            throw ClaudeUsageFetcher.FetchError.malformedResponse
        }
        return quota
    }
}
