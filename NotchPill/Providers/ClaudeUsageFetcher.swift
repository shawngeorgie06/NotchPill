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
    /// Extra per-model weekly windows the API reports alongside the two
    /// account-wide ones.
    ///
    /// Keyed rather than hard-coded because the set is not ours to fix:
    /// Anthropic already reports `seven_day_opus`, and any newer model with its
    /// own allowance arrives as another key. Naming a specific model here would
    /// mean shipping a release to show a window that is already in the payload.
    var modelWindows: [ModelWindow] = []
    var updatedAt: Date?

    struct ModelWindow: Equatable {
        /// Display label derived from the key: `seven_day_opus` → `opus`.
        var name: String
        var percent: Int
        var resetsAt: Date?
    }

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

    /// The actual clock time a window reopens.
    ///
    /// "resets in 5d" was on the card first, and it answers the wrong question:
    /// a duration tells you how long you have been waiting, not when you can
    /// work again. It also hid the session reset entirely, because the card
    /// showed only whichever window was nearer its limit — and weekly beat
    /// session by three points while session was the one about to bite.
    ///
    /// Today gives a time, this week a weekday and time, beyond that a date.
    static func resetClock(for date: Date?, now: Date = Date(),
                           calendar: Calendar = .current,
                           locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            formatter.setLocalizedDateFormatFromTemplate("jmm")
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            formatter.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
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
        /// Asked too often. Carries the server's own `Retry-After` when it
        /// sends one, because guessing an interval is how you get rate-limited
        /// a second time.
        case rateLimited(retryAfter: TimeInterval?)
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

        // Per-model allowances only.
        //
        // "Anything with a utilization figure" was too loose: the payload
        // carries other metered things at the same level, and the first one
        // alphabetically took the column that was supposed to show a model.
        // A per-model window is a *window key with a model suffix* —
        // `seven_day_opus`, `seven_day_fable` — so that is what this matches,
        // and nothing else can wander in.
        let models = root.keys
            .filter { Self.isModelWindowKey($0) }
            .compactMap { key -> ClaudeQuota.ModelWindow? in
                guard let w = window(key) else { return nil }
                return ClaudeQuota.ModelWindow(name: Self.modelWindowLabel(for: key),
                                               percent: w.percent, resetsAt: w.resets)
            }
            .sorted(by: Self.modelWindowOrder)
        // Names only — never a utilization figure — so the log says which
        // windows this account actually has without recording usage.
        //
        // Only keys that parse as a window: the payload carries plan flags and
        // promotional entries at the same level, and listing those made the log
        // look like a menu of meters that mostly do not exist.
        let metered = root.keys.filter { window($0) != nil }.sorted()
        if !metered.isEmpty {
            LogStore.log("claude", "metered windows: " + metered.joined(separator: ", "))
        }
        // Field *names* of the per-model entries, never their values. A key can
        // exist without carrying a figure, and the two look identical from
        // outside — this is what distinguishes "your plan has no such limit"
        // from "the number is there under a name we do not read".
        for key in root.keys.sorted() where Self.isModelWindowKey(key) {
            let fields = (root[key] as? [String: Any])?.keys.sorted() ?? []
            LogStore.log("claude", "\(key) fields: "
                         + (fields.isEmpty ? "(not an object)" : fields.joined(separator: ", ")))
        }

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
            modelWindows: models,
            updatedAt: now)
    }

    /// Window keys that name a model, and only those.
    ///
    /// The prefixes are the two window lengths the API meters in; anything
    /// after one of them is the model the allowance belongs to. A bare
    /// `five_hour`/`seven_day` is the account-wide window, already shown, and
    /// a key that starts with neither is not a window at all — which is how
    /// something that was not a model ended up in the model column.
    nonisolated static func isModelWindowKey(_ key: String) -> Bool {
        for prefix in ["seven_day_", "five_hour_"] where key.hasPrefix(prefix) {
            return key.count > prefix.count
        }
        return false
    }

    /// Which model gets the one extra column.
    ///
    /// Not alphabetical. The column exists because someone asked to see a
    /// specific model's limit, and alphabetical order hands it to whichever
    /// model happens to sort first — so the card shows a model you did not ask
    /// about while the one you did sits behind it. Fable first, then Opus,
    /// then anything else by name for a stable order.
    nonisolated static func modelWindowRank(_ name: String) -> Int {
        let lowered = name.lowercased()
        if lowered.contains("fable") { return 0 }
        if lowered.contains("opus") { return 1 }
        return 2
    }

    nonisolated static func modelWindowOrder(_ a: ClaudeQuota.ModelWindow,
                                             _ b: ClaudeQuota.ModelWindow) -> Bool {
        let (ra, rb) = (modelWindowRank(a.name), modelWindowRank(b.name))
        return ra == rb ? a.name < b.name : ra < rb
    }

    /// `seven_day_opus` → `opus`. Unknown shapes keep their key, which is
    /// better than a blank label and says exactly what the API called it.
    nonisolated static func modelWindowLabel(for key: String) -> String {
        let trimmed = key
            .replacingOccurrences(of: "seven_day_", with: "")
            .replacingOccurrences(of: "five_hour_", with: "")
            .replacingOccurrences(of: "_", with: " ")
        return trimmed.isEmpty ? key : trimmed
    }

    /// `resets_at` carries fractional seconds and an offset; the plain ISO8601
    /// formatter rejects the fraction, so both spellings are accepted.
    static func parseTimestamp(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    // MARK: - Request

    /// Seconds to wait, from a `Retry-After` header. Accepts the delta-seconds
    /// form only; the HTTP-date form is legal but nobody sends it here, and a
    /// misparsed date would produce a wait of decades.
    static func retryAfter(in response: HTTPURLResponse?) -> TimeInterval? {
        guard let raw = response?.value(forHTTPHeaderField: "Retry-After"),
              let seconds = TimeInterval(raw.trimmingCharacters(in: .whitespaces)),
              seconds > 0 else { return nil }
        return min(seconds, 3600)
    }

    static func usageRequest(_ credentials: Credentials) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15
        return request
    }
}
