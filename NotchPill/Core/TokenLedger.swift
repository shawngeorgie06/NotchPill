import Foundation

/// Tokens a model actually worked on: prompt in, generation out.
///
/// Cache reads are deliberately absent. They are re-counted on every request
/// and billed at a fraction, and in a real transcript they outnumber the rest
/// roughly thirty to one — a "total" including them reads in the billions and
/// says nothing about how much work was done.
struct TokenTally: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0

    var total: Int { input + output }

    static func + (lhs: TokenTally, rhs: TokenTally) -> TokenTally {
        TokenTally(input: lhs.input + rhs.input, output: lhs.output + rhs.output)
    }
}

/// Reads token usage out of agent transcripts, bucketed by day and model.
///
/// Day buckets rather than a single total because the period is the user's
/// choice — today, the last week, everything — and re-reading 850MB of
/// transcripts to answer a different question is not an option. Any period is
/// a sum over the buckets already on disk.
enum TokenLedger {
    /// `yyyy-MM-dd` → model → tally.
    typealias Buckets = [String: [String: TokenTally]]

    static func merge(_ lhs: Buckets, _ rhs: Buckets) -> Buckets {
        var out = lhs
        for (day, models) in rhs {
            for (model, tally) in models {
                out[day, default: [:]][model, default: TokenTally()] =
                    (out[day]?[model] ?? TokenTally()) + tally
            }
        }
        return out
    }

    /// Claude Code writes one record per message, each carrying its own usage
    /// delta, so these sum.
    static func claudeBuckets(in text: String) -> Buckets {
        var buckets: Buckets = [:]
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let message = object["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any],
                  let model = message["model"] as? String,
                  // Synthetic records carry no real work and no real model.
                  model != "<synthetic>", !model.isEmpty,
                  let day = day(from: object["timestamp"]) else { continue }
            let tally = TokenTally(input: int(usage["input_tokens"]),
                                   output: int(usage["output_tokens"]))
            guard tally.total > 0 else { continue }
            buckets[day, default: [:]][model, default: TokenTally()] =
                (buckets[day]?[model] ?? TokenTally()) + tally
        }
        return buckets
    }

    /// Codex reports a *running total* for the session rather than per-turn
    /// deltas, so the newest `token_count` is the whole session and summing
    /// them would multiply it by the number of turns.
    ///
    /// The model is named in a session record, not in the token record, so it
    /// is carried across from wherever it appears.
    static func codexBuckets(in text: String) -> Buckets {
        var model: String?
        var newest: (day: String, tally: TokenTally)?

        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any],
                  let payload = object["payload"] as? [String: Any] else { continue }
            if model == nil, let named = payload["model"] as? String, !named.isEmpty {
                model = named
            }
            guard payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let totals = info["total_token_usage"] as? [String: Any],
                  let day = day(from: object["timestamp"]) else { continue }
            let tally = TokenTally(input: int(totals["input_tokens"]),
                                   output: int(totals["output_tokens"]))
            if tally.total > 0 { newest = (day, tally) }
        }

        guard let newest else { return [:] }
        // A session running past midnight lands entirely on the day it last
        // reported. Splitting it would mean trusting deltas Codex does not give.
        return [newest.day: [model ?? "codex": newest.tally]]
    }

    /// Sums the buckets falling inside a period.
    static func total(_ buckets: Buckets, since cutoff: Date?,
                      now: Date = Date()) -> [String: TokenTally] {
        var out: [String: TokenTally] = [:]
        let earliest = cutoff.map(day(from:))
        for (day, models) in buckets {
            if let earliest, day < earliest { continue }
            for (model, tally) in models {
                out[model, default: TokenTally()] = (out[model] ?? TokenTally()) + tally
            }
        }
        return out
    }

    // MARK: - Helpers

    /// `yyyy-MM-dd` in the local calendar, from an ISO8601 timestamp.
    ///
    /// String keys rather than `Date` so the buckets survive a round trip
    /// through JSON unchanged, and so a period test is a string comparison
    /// rather than calendar arithmetic on every bucket.
    static func day(from raw: Any?) -> String? {
        guard let text = raw as? String, text.count >= 10 else { return nil }
        guard let date = isoParser.date(from: text) ?? isoParserNoFraction.date(from: text) else {
            return nil
        }
        return day(from: date)
    }

    /// Builds a local date for tests and period cutoffs without pulling
    /// `Calendar` arithmetic into every call site.
    static func dayComponents(year: Int, month: Int, day: Int) -> Date? {
        var c = DateComponents()
        c.year = year; c.month = month; c.day = day
        return Calendar.current.date(from: c)
    }

    static func day(from date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func int(_ value: Any?) -> Int {
        switch value {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s) ?? 0
        default: return 0
        }
    }

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
