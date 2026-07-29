import Foundation

/// Watches GitHub Actions for the repos you are actually working in.
///
/// The repo list is not configured anywhere — it comes from the live agent
/// sessions, which already know their working directories. So the card follows
/// you: start an agent in a repo and its CI appears. Repos are remembered for
/// an hour after the session that introduced them ends, because a release is
/// usually tagged and then walked away from, and tying the card to the session
/// made CI vanish at the moment it became worth watching.
///
/// Everything here shells out to `gh`, which is slow and must never touch the
/// main thread, hence the actor. If `gh` is missing or not logged in there is
/// simply no card — the feature is off rather than broken.
actor CIStatusProvider {
    /// CI takes minutes, not seconds. Polling faster would spend `gh`
    /// invocations — each one a network round trip — to learn nothing.
    private let pollInterval: TimeInterval = 45
    private var lastFetch = Date.distantPast
    private var cached: [CIRun] = []
    /// Repo slug by working directory, so `git remote` is not re-read for a
    /// path already resolved.
    private var slugByDirectory: [String: String?] = [:]
    /// Repos seen recently, and when. A release is usually tagged and then
    /// walked away from — the agent session that introduced the repo ends long
    /// before the build does, and tying the card's life to that session made CI
    /// disappear at exactly the moment it became worth watching.
    private var recentRepos: [String: Date] = [:]
    private let repoMemory: TimeInterval = 3600

    private lazy var ghPath: String? = Self.findGH()

    /// Runs for the given working directories, at most one `gh` call per repo
    /// per interval.
    func runs(forDirectories directories: [String], now: Date = Date()) -> [CIRun] {
        guard ghPath != nil else { return [] }
        // Note: no early return on an empty directory list — the remembered
        // repos below are the whole point.
        guard now.timeIntervalSince(lastFetch) >= pollInterval || cached.isEmpty else {
            return cached
        }
        lastFetch = now

        var slugs: [String] = []
        for dir in directories {
            if let known = slugByDirectory[dir] {
                if let known { slugs.append(known) }
                continue
            }
            let slug = remoteSlug(in: dir)
            slugByDirectory[dir] = slug
            if let slug { slugs.append(slug) }
        }
        // Two repos is already four seconds of `gh`. Beyond that the card
        // cannot show them anyway.
        for slug in slugs { recentRepos[slug] = now }
        recentRepos = recentRepos.filter { now.timeIntervalSince($0.value) < repoMemory }
        // Newest first, so a repo you just opened outranks one you left an hour
        // ago when the two-repo budget is spent.
        let remembered = recentRepos.sorted { $0.value > $1.value }.map(\.key)
        var seen = Set<String>()
        let unique = (slugs + remembered).filter { seen.insert($0).inserted }.prefix(2)

        var found: [CIRun] = []
        for slug in unique { found.append(contentsOf: fetchRuns(repo: slug)) }
        cached = CIRun.ordered(found)
        return cached
    }

    /// Testing seams for the memory, which is the part with a real rule in it.
    func remember(_ slug: String, at date: Date) {
        recentRepos[slug] = date
    }

    func repos(at now: Date) -> [String] {
        recentRepos
            .filter { now.timeIntervalSince($0.value) < repoMemory }
            .sorted { $0.value > $1.value }
            .map(\.key)
    }

    func reset() {
        cached = []
        lastFetch = .distantPast
        slugByDirectory.removeAll()
        recentRepos.removeAll()
    }

    // MARK: - Shell

    private static func findGH() -> String? {
        // A GUI app inherits a minimal PATH, so `gh` is looked for where it
        // actually lives rather than trusted to be on it.
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh",
                          FileManager.default.homeDirectoryForCurrentUser
                              .appendingPathComponent(".local/bin/gh").path]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func remoteSlug(in directory: String) -> String? {
        guard let out = run("/usr/bin/git",
                            ["-C", directory, "remote", "get-url", "origin"]) else { return nil }
        return CIRun.repoSlug(fromRemote: out)
    }

    private func fetchRuns(repo: String) -> [CIRun] {
        guard let ghPath,
              let out = run(ghPath, ["run", "list", "-R", repo, "--limit", "3", "--json",
                                     "workflowName,status,conclusion,createdAt,url,headBranch"]),
              let data = out.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        let iso = ISO8601DateFormatter()
        return items.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            let created = (item["createdAt"] as? String).flatMap { iso.date(from: $0) } ?? Date()
            return CIRun(
                id: url,
                repo: repo,
                workflow: item["workflowName"] as? String ?? "workflow",
                branch: item["headBranch"] as? String ?? "",
                state: CIRun.state(status: item["status"] as? String ?? "",
                                   conclusion: item["conclusion"] as? String ?? ""),
                started: created)
        }
    }

    /// A hung `gh` must not wedge the card forever, so the process is given a
    /// deadline and killed past it.
    private func run(_ path: String, _ args: [String], timeout: TimeInterval = 8) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline { usleep(50_000) }
        if process.isRunning { process.terminate(); return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
