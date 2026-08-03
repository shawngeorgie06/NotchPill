import Foundation

/// What Anthropic reports about a Claude subscription's limits.
///
/// Two windows, because Claude enforces two: a rolling session limit that
/// resets several times a day, and a weekly one. Showing only the first would
/// hide the limit people actually run into on a heavy week, and showing only
/// the second hides the one that stops you mid-afternoon.
struct ClaudeQuota: Equatable {
    /// Rolling session window ("five_hour"), 0–100.
    var sessionPercent: Int
    var sessionResetsAt: Date?
    /// Weekly window across all models, 0–100.
    var weeklyPercent: Int
    var weeklyResetsAt: Date?
    /// Pay-as-you-go spend past the subscription, when enabled.
    var extraSpentMinor: Int?
    var extraLimitMinor: Int?
    var extraCurrency: String?
    var updatedAt: Date?

    /// The window closest to its limit — the one worth a glance.
    var headlinePercent: Int { max(sessionPercent, weeklyPercent) }

    var sessionLabel: String { "\(sessionPercent)% session" }
    var weeklyLabel: String { "\(weeklyPercent)% week" }

    /// Money is stored in minor units and rendered from them, so nothing is
    /// ever rounded through a Double on the way to the screen.
    var extraSpendLabel: String? {
        guard let extraSpentMinor, let extraLimitMinor, extraLimitMinor > 0 else { return nil }
        let symbol = extraCurrency == "USD" ? "$" : ((extraCurrency.map { $0 + " " }) ?? "")
        func money(_ minor: Int) -> String {
            let whole = minor / 100, cents = abs(minor % 100)
            return cents == 0 ? "\(symbol)\(whole)" : "\(symbol)\(whole).\(String(format: "%02d", cents))"
        }
        return "\(money(extraSpentMinor)) of \(money(extraLimitMinor))"
    }

    static func resetLabel(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds < 3600 { return "resets in \(max(1, seconds / 60))m" }
        if seconds < 86_400 { return "resets in \(seconds / 3600)h" }
        return "resets in \(seconds / 86_400)d"
    }
}

/// Reads Claude subscription usage from Anthropic, using the OAuth token Claude
/// Code already stored when you signed in.
///
/// As with Codex, there is no login flow and no credential of ours. The
/// difference is where the token lives: Claude Code keeps it in the **login
/// Keychain** (`Claude Code-credentials`) rather than a file, so reading it
/// raises a one-time macOS consent prompt. That is why this is behind a setting
/// that starts off — an app that asks for Keychain access unprompted, for a
/// card you never asked for, has earned the suspicion it gets.
enum ClaudeUsageFetcher {
    static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// The service name Claude Code stores its credentials under.
    static let keychainService = "Claude Code-credentials"
    /// Required to call the usage endpoint. A token holding only
    /// `user:inference` can talk to the model but cannot read the account, and
    /// returns 403 here — worth telling apart from "signed out".
    static let requiredScope = "user:profile"

    struct Credentials: Equatable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
        var subscriptionType: String?

        var hasUsageScope: Bool { scopes.contains(ClaudeUsageFetcher.requiredScope) }
        func isExpired(now: Date = Date()) -> Bool {
            guard let expiresAt else { return false }
            return now >= expiresAt
        }
    }

    enum FetchError: Error, Equatable {
        case noCredentials
        /// Signed in, but this token cannot read the account.
        case missingScope
        case unauthorized
        case http(Int)
        case malformedResponse
    }

    // MARK: - Credentials

    /// Parses the Keychain blob. Times are epoch **milliseconds**, which is why
    /// they are divided rather than fed straight to `timeIntervalSince1970` —
    /// treating them as seconds dates the token to 1970 and makes every token
    /// look expired.
    static func credentials(in data: Data) -> Credentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Claude Code 2.1.x can store only `mcpOAuth` here, with no
        // `claudeAiOauth` at all. That is a signed-out-for-our-purposes state,
        // not a parse failure, and must not be reported as a broken Keychain.
        guard let oauth = root["claudeAiOauth"] as? [String: Any],
              let access = oauth["accessToken"] as? String, !access.isEmpty
        else { return nil }
        func date(_ key: String) -> Date? {
            guard let ms = (oauth[key] as? Double) ?? (oauth[key] as? NSNumber)?.doubleValue
            else { return nil }
            return Date(timeIntervalSince1970: ms / 1000)
        }
        return Credentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: date("expiresAt"),
            scopes: (oauth["scopes"] as? [String]) ?? [],
            subscriptionType: oauth["subscriptionType"] as? String)
    }

    // MARK: - Response

    static func quota(in data: Data, now: Date = Date()) -> ClaudeQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func window(_ key: String) -> (percent: Int, resets: Date?)? {
            guard let object = root[key] as? [String: Any] else { return nil }
            let raw = (object["utilization"] as? Double)
                ?? (object["utilization"] as? NSNumber)?.doubleValue
            guard let raw else { return nil }
            let resets = (object["resets_at"] as? String).flatMap(parseTimestamp)
            return (min(100, max(0, Int(raw.rounded()))), resets)
        }
        // A response with neither window is not a usage response.
        let session = window("five_hour")
        let weekly = window("seven_day")
        guard session != nil || weekly != nil else { return nil }

        var spent: Int?, limit: Int?, currency: String?
        if let spend = root["spend"] as? [String: Any],
           (spend["enabled"] as? Bool) == true {
            if let used = spend["used"] as? [String: Any] {
                spent = (used["amount_minor"] as? Int)
                    ?? (used["amount_minor"] as? NSNumber)?.intValue
                currency = used["currency"] as? String
            }
            if let cap = spend["limit"] as? [String: Any] {
                limit = (cap["amount_minor"] as? Int)
                    ?? (cap["amount_minor"] as? NSNumber)?.intValue
            }
        }

        return ClaudeQuota(
            sessionPercent: session?.percent ?? 0,
            sessionResetsAt: session?.resets,
            weeklyPercent: weekly?.percent ?? 0,
            weeklyResetsAt: weekly?.resets,
            extraSpentMinor: spent,
            extraLimitMinor: limit,
            extraCurrency: currency,
            updatedAt: now)
    }

    /// `resets_at` carries fractional seconds and an offset; the plain ISO8601
    /// formatter rejects the fraction, so both spellings are accepted.
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - Request

    static func usageRequest(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        return request
    }
}
