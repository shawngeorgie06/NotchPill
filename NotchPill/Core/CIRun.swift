import Foundation

/// One GitHub Actions run, as the notch shows it.
struct CIRun: Equatable, Identifiable {
    enum State: Equatable {
        case running
        case passed
        case failed
        /// Queued, or finished in a way that is neither a pass nor a failure —
        /// cancelled, skipped, timed out. Worth showing, not worth alarming
        /// about.
        case other(String)
    }

    var id: String          // the run URL, unique per run
    var repo: String        // "owner/name"
    var workflow: String
    var branch: String
    var state: State
    var started: Date
    /// When the run last changed — its finish time once completed. Ageing a
    /// finished run from `started` is wrong: a release build takes minutes, so
    /// a short lifetime measured from the start would expire the run before it
    /// ever finished, and it would never appear at all.
    var updated: Date?

    /// The moment a finished run stopped being in progress.
    var finished: Date { updated ?? started }

    /// Just the repository, without the owner — "notchpill", not
    /// "shawngeorgie06/notchpill". The owner is the same for every row you are
    /// likely to see at once, and the card has no width to spare.
    var repoName: String {
        repo.split(separator: "/").last.map(String.init) ?? repo
    }

    /// `gh` reports an in-flight run as `queued`/`in_progress` with no
    /// conclusion, and a finished one as `completed` plus a conclusion. Reading
    /// only the conclusion would call every running build a failure, since its
    /// conclusion is empty.
    static func state(status: String, conclusion: String) -> State {
        guard status.lowercased() == "completed" else { return .running }
        switch conclusion.lowercased() {
        case "success": return .passed
        case "failure", "startup_failure": return .failed
        case let other where other.isEmpty: return .running
        case let other: return .other(other)
        }
    }

    var statusLabel: String {
        switch state {
        case .running: return "running " + CIRun.shortAge(since: started)
        case .passed: return "passed"
        case .failed: return "failed"
        case .other(let what): return what
        }
    }

    static func shortAge(since: Date, now: Date = Date()) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    /// How long a finished run stays on the card.
    ///
    /// `gh run list` has no notion of age — it hands back the three most recent
    /// runs whether they finished a minute or a fortnight ago. So a repo you
    /// built once kept showing the same three green rows every time you opened
    /// an agent in it, which is not status, it is wallpaper.
    ///
    /// A pass is worth knowing about for as long as you might still be watching
    /// for it, and then it is over. A failure is worth keeping much longer:
    /// it is the one you have not dealt with yet.
    static let passedLifetime: TimeInterval = 120
    static let failedLifetime: TimeInterval = 21600

    /// Drops finished runs that have stopped being news. Anything still
    /// running stays regardless of age — a build that has been going for two
    /// hours is exactly the one you want to see.
    static func current(_ runs: [CIRun], now: Date = Date()) -> [CIRun] {
        runs.filter { run in
            // From when it finished, not when it started.
            let age = now.timeIntervalSince(run.finished)
            switch run.state {
            case .running: return true
            case .failed: return age < failedLifetime
            case .passed, .other: return age < passedLifetime
            }
        }
    }

    /// A failure is the only state worth interrupting for, so failures come
    /// first, then anything still running, then the rest newest-first.
    static func ordered(_ runs: [CIRun]) -> [CIRun] {
        runs.sorted { a, b in
            func rank(_ r: CIRun) -> Int {
                switch r.state {
                case .failed: return 0
                case .running: return 1
                default: return 2
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.started > b.started
        }
    }

    /// `git remote get-url origin` → `owner/name`.
    ///
    /// Handles both forms git hands back, with or without the `.git` suffix:
    ///   https://github.com/owner/name.git
    ///   git@github.com:owner/name.git
    /// Anything that is not GitHub returns nil — there is no run list to fetch.
    static func repoSlug(fromRemote url: String) -> String? {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.contains("github.com") else { return nil }
        if s.hasSuffix(".git") { s = String(s.dropLast(4)) }
        guard let range = s.range(of: "github.com") else { return nil }
        var tail = String(s[range.upperBound...])
        if tail.hasPrefix(":") || tail.hasPrefix("/") { tail = String(tail.dropFirst()) }
        let parts = tail.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0])/\(parts[1])"
    }
}
