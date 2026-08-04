import Foundation

/// What Cursor reports about a subscription's included usage.
///
/// One window, not two: Cursor meters a single pool per billing cycle rather
/// than Claude's session/week pair, so there is a `used` out of a `limit` and a
/// date the cycle turns over.
struct CursorQuota: Equatable {
    var used: Int
    var limit: Int
    /// What Cursor calls the plan's included allowance before bonus credits.
    var included: Int?
    var bonus: Int?
    var percentUsed: Int
    var cycleEnd: Date?
    /// `pro`, `pro_student`, `business`… shown verbatim but tidied for display.
    var membership: String?
    /// True for plans Cursor reports as having no cap at all.
    var isUnlimited: Bool
    /// Pay-as-you-go past the included pool, when the user has enabled it.
    var onDemandEnabled: Bool
    var updatedAt: Date?

    var remaining: Int { max(0, limit - used) }

    /// "pro_student" → "Pro Student". Cursor sends the raw plan key.
    var membershipLabel: String? {
        guard let membership, !membership.isEmpty else { return nil }
        return membership.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// The headline. Deliberately "used of limit" rather than "remaining":
    /// at 2000/2000 the remaining figure reads as a plausible zero-usage state,
    /// while "2000 of 2000" cannot be misread.
    var usageLabel: String {
        if isUnlimited { return "unlimited" }
        return "\(used) of \(limit)"
    }

    static func cycleLabel(for date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return "renewing" }
        if seconds < 86_400 { return "renews in \(max(1, seconds / 3600))h" }
        return "renews in \(seconds / 86_400)d"
    }
}

/// Reads Cursor's included-usage figure using the session token the Cursor app
/// already stored when you signed in.
///
/// The endpoint choice matters. Cursor's `/api/usage` still answers, but it
/// reports retired per-model gpt-4 request counters that read as all-zero on a
/// current plan — a gauge that always says "0" is worse than no gauge, and it
/// is what made me report that Cursor exposed nothing at all. The dashboard
/// POSTs under `/api/dashboard/*` do carry real numbers, but reject any request
/// without a browser `Origin` header; forging one to get past a CSRF check is
/// not something to ship. `/api/usage-summary` is a plain GET, needs no forged
/// header, and returns the same figures the account page shows.
enum CursorUsageFetcher {
    static let usageEndpoint = URL(string: "https://cursor.com/api/usage-summary")!
    /// Where the Cursor app keeps its session token.
    static let tokenKey = "cursorAuth/accessToken"

    struct Credentials: Equatable {
        var accessToken: String
        /// The WorkOS user id from the token's own payload. The cookie Cursor
        /// expects is `<sub>::<token>`, and the token is the only place the
        /// `sub` can be read from without a second request.
        var subject: String
    }

    enum FetchError: Error, Equatable {
        case noCredentials
        case unauthorized
        case http(Int)
        case malformedResponse
    }

    // MARK: - Credentials

    /// Pulls the `sub` claim out of the JWT payload.
    ///
    /// No signature check: this is our own stored token, read to address the
    /// request back to the service that issued it. Nothing here is a trust
    /// decision, so there is nothing for a forged signature to buy.
    static func credentials(token: String) -> Credentials? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Base64url drops the padding the decoder requires.
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = root["sub"] as? String, !sub.isEmpty
        else { return nil }
        // Cursor writes `auth0|user_…`; the cookie wants only the trailing id.
        let subject = sub.split(separator: "|").last.map(String.init) ?? sub
        return Credentials(accessToken: token, subject: subject)
    }

    // MARK: - Response

    static func quota(in data: Data, now: Date = Date()) -> CursorQuota? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        func int(_ any: Any?) -> Int? {
            (any as? Int) ?? (any as? NSNumber)?.intValue
                ?? (any as? Double).map { Int($0.rounded()) }
        }
        let unlimited = (root["isUnlimited"] as? Bool) ?? false
        let plan = (root["individualUsage"] as? [String: Any])?["plan"] as? [String: Any]
        // Without a plan block there is nothing to draw. An unlimited account
        // is the one exception: no numbers exist to report, and that is the
        // answer rather than a failure.
        guard let plan else { return unlimited ? unlimitedQuota(root, now: now) : nil }

        guard let used = int(plan["used"]), let limit = int(plan["limit"]) else {
            return unlimited ? unlimitedQuota(root, now: now) : nil
        }
        let breakdown = plan["breakdown"] as? [String: Any]
        // Prefer the server's own percentage: at 1999/2000 a locally computed
        // 99.95 rounds to 100 and claims a limit that has not been reached.
        let percent = int(plan["totalPercentUsed"])
            ?? (limit > 0 ? Int((Double(used) / Double(limit) * 100).rounded(.down)) : 0)
        let onDemand = (root["individualUsage"] as? [String: Any])?["onDemand"] as? [String: Any]

        return CursorQuota(
            used: used,
            limit: limit,
            included: int(breakdown?["included"]),
            bonus: int(breakdown?["bonus"]),
            percentUsed: min(100, max(0, percent)),
            cycleEnd: (root["billingCycleEnd"] as? String).flatMap(parseTimestamp),
            membership: root["membershipType"] as? String,
            isUnlimited: unlimited,
            onDemandEnabled: (onDemand?["enabled"] as? Bool) ?? false,
            updatedAt: now)
    }

    private static func unlimitedQuota(_ root: [String: Any], now: Date) -> CursorQuota {
        CursorQuota(
            used: 0, limit: 0, included: nil, bonus: nil, percentUsed: 0,
            cycleEnd: (root["billingCycleEnd"] as? String).flatMap(parseTimestamp),
            membership: root["membershipType"] as? String,
            isUnlimited: true, onDemandEnabled: false, updatedAt: now)
    }

    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - Request

    static func usageRequest(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("WorkosCursorSessionToken=\(credentials.subject)::\(credentials.accessToken)",
                         forHTTPHeaderField: "Cookie")
        request.timeoutInterval = 15
        return request
    }
}
