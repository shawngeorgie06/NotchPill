import Foundation

/// Reads Codex subscription usage from OpenAI, using the OAuth token Codex
/// already stored when *you* logged in.
///
/// There is no login flow here and no credential of ours. `~/.codex/auth.json`
/// is written by Codex itself, and this calls the same endpoint the CLI calls
/// with the same headers. If Codex works, this works; if you log out of Codex,
/// this stops. (The approach is the one CodexBar documents; none of its code is
/// used.)
///
/// ## Why not keep reading the transcript
///
/// The previous source scraped `rate_limits` out of `token_count` events in the
/// newest session transcript. That is genuinely local, but it is a *cached copy
/// of a number from the last request*, and it went wrong in both directions:
///
/// - It expired. Transcripts are only consulted inside the two-hour liveness
///   window, so the card vanished overnight and came back only after you sent
///   another Codex message.
/// - It was stale while visible. Measured on this machine, the notch showed
///   `4% used · 0 credits balance` while the API reported **100% used, limit
///   reached, $298.43 balance**. The "0 credits" came from reading
///   `rate_limit_reset_credits.available_count` as a balance.
///
/// A quota card that says 4% when you are rate-limited is worse than no card,
/// so the transcript is now only a fallback for when the API cannot be reached.
enum CodexUsageFetcher {
    /// Where Codex keeps the tokens it obtained when you logged in.
    static func authFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".codex/auth.json")
    }

    static let usageEndpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let refreshEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    /// Codex's own OAuth client id. Public — it identifies the app, not the user.
    static let clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Codex refreshes on this interval; matching it keeps us from forcing a
    /// refresh Codex would not have done.
    static let refreshInterval: TimeInterval = 8 * 24 * 3600

    struct Credentials: Equatable {
        var accessToken: String
        var refreshToken: String
        var accountId: String?
        var lastRefresh: Date?

        func needsRefresh(now: Date = Date(), interval: TimeInterval = refreshInterval) -> Bool {
            guard let lastRefresh else { return true }
            return now.timeIntervalSince(lastRefresh) > interval
        }
    }

    enum FetchError: Error, Equatable {
        case noCredentials
        /// The token was rejected. Almost always "log in to Codex again" rather
        /// than anything we can fix.
        case unauthorized
        case http(Int)
        case malformedResponse
    }

    // MARK: - Credentials

    /// Parses `auth.json`. Never logs or returns the token in any diagnostic —
    /// callers get a `Credentials` or an error, never a description of one.
    static func credentials(in data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty
        else { return nil }
        let stamp = (root["last_refresh"] as? String).flatMap(parseTimestamp)
        return Credentials(accessToken: access,
                           refreshToken: refresh,
                           accountId: tokens["account_id"] as? String,
                           lastRefresh: stamp)
    }

    /// `last_refresh` carries fractional seconds; the plain ISO8601 formatter
    /// rejects those, so both spellings are accepted rather than silently
    /// treating a valid stamp as "never refreshed".
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - Response

    /// Maps the usage payload onto the model the card already renders.
    ///
    /// `primary_window` is the plan's own window, whatever its length — 5h on
    /// some plans, 30d on others — so no duration is assumed here; `resetsAt`
    /// carries the only date that matters.
    static func quota(in data: Data, now: Date = Date()) -> CodexQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limit = root["rate_limit"] as? [String: Any],
              let primary = limit["primary_window"] as? [String: Any]
        else { return nil }

        let used = (primary["used_percent"] as? Double)
            ?? (primary["used_percent"] as? NSNumber)?.doubleValue
        guard let used else { return nil }

        let resetSeconds = (primary["reset_at"] as? Double)
            ?? (primary["reset_at"] as? NSNumber)?.doubleValue

        // `balance` is a decimal *string* ("298.4291950000"). Parsed with a
        // POSIX locale so a comma-decimal locale cannot misread it, and as
        // Decimal so money is never rounded through a Double.
        var balance: Decimal?
        if let credits = root["credits"] as? [String: Any] {
            let unlimited = credits["unlimited"] as? Bool ?? false
            if !unlimited {
                if let text = credits["balance"] as? String {
                    balance = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
                } else if let number = credits["balance"] as? NSNumber {
                    balance = Decimal(string: number.stringValue,
                                      locale: Locale(identifier: "en_US_POSIX"))
                }
            }
        }

        return CodexQuota(usedPercent: min(100, max(0, Int(used.rounded()))),
                          resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:)),
                          creditBalance: balance,
                          // Live from the provider, so "now" is honest — unlike
                          // the transcript, where this was the age of a cached
                          // number.
                          updatedAt: now)
    }

    /// The refreshed pair, or nil. Only `access_token` is required: OpenAI may
    /// return the same refresh token rather than a new one.
    static func refreshed(in data: Data, previous: Credentials, now: Date = Date()) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = root["access_token"] as? String, !access.isEmpty
        else { return nil }
        var next = previous
        next.accessToken = access
        if let refresh = root["refresh_token"] as? String, !refresh.isEmpty {
            next.refreshToken = refresh
        }
        next.lastRefresh = now
        return next
    }

    // MARK: - Requests

    static func usageRequest(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        // Codex identifies itself this way; the endpoint is not a documented
        // public API and a different agent string is a reason to be refused.
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        return request
    }

    static func refreshRequest(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: refreshEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "scope": "openid profile email",
        ])
        request.timeoutInterval = 15
        return request
    }
}
