import Foundation

/// Peeks when an agent finishes a turn, with **no hooks installed** — by
/// watching the transcripts Claude Code and Codex already write to disk.
///
/// The point is that NotchPill should do something useful the moment you
/// install it. Hooks remain worth installing, but they are now an upgrade
/// rather than a prerequisite:
///
/// | | watching | hook |
/// |---|---|---|
/// | "finished" peek | yes | yes |
/// | "waiting for approval" peek | **no** | yes |
/// | tap to focus the right terminal | **no** | yes |
///
/// The two gaps are not oversights. A pending permission prompt is not written
/// to the transcript until it has been answered, so a blocked agent is
/// invisible here — which is exactly why the `Notification`/`PermissionRequest`
/// hooks exist. And a transcript records no terminal, so there is no bundle id
/// to focus or type into.
///
/// When hooks *are* installed both paths fire for the same turn. They are made
/// to collide on purpose: this emits the same title, subtitle and sessionId the
/// hooks do, so `DevReadyDedup` suppresses whichever arrives second. The hook
/// wins in practice because it fires immediately while this waits for quiet.
@MainActor
final class AgentTranscriptProvider {
    var onDevReady: ((DevReadyAlert) -> Void)?

    /// How long a transcript must stop growing before the turn counts as over.
    /// Long enough to not fire between two tool calls, short enough to still
    /// feel like a notification.
    private let quietPeriod: TimeInterval = 2.5
    private let pollInterval: TimeInterval = 1.5

    private struct FileState {
        var size: Int64
        var lastChange: Date
        var pinged: Bool
    }

    private var states: [String: FileState] = [:]
    private var timer: Timer?
    private var primed = false
    /// Cached result of walking the transcript trees; see `transcripts()`.
    private var activeFiles: [URL]?
    private var lastDiscovery = Date.distantPast
    private let rediscoverInterval: TimeInterval = 15

    private var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".codex/sessions")]
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        states.removeAll()
        primed = false
    }

    private func scan() {
        guard AppSettings.shared.showDevReadyPings,
              AppSettings.shared.watchAgentTranscripts else { return }

        let now = Date()
        for url in transcripts() {
            guard let size = fileSize(url) else { continue }
            let key = url.path

            guard var state = states[key] else {
                // First sighting. Never ping for it: at launch every existing
                // transcript looks "recently finished", which would dump a peek
                // per session you have ever run.
                states[key] = FileState(size: size, lastChange: now, pinged: true)
                continue
            }

            if size != state.size {
                state.size = size
                state.lastChange = now
                state.pinged = false
                states[key] = state
                continue
            }

            guard !state.pinged, now.timeIntervalSince(state.lastChange) >= quietPeriod else {
                continue
            }
            state.pinged = true
            states[key] = state
            // Quiet is not the same as finished. A transcript also stops growing
            // while the agent waits on *you*, and every line you type appends to
            // it — so without this the notch peeks "finished" at the person who
            // just pressed Return.
            guard primed, endsWithAgentTurn(url) else { continue }
            if let alert = alert(for: url) {
                onDevReady?(alert)
            }
        }
        // One full pass to learn the world before anything is allowed to fire.
        primed = true
    }

    /// Live transcripts, cached.
    ///
    /// Walking both trees costs hundreds of `stat` calls — several hundred
    /// transcripts accumulate quickly — and almost none of them are live. So the
    /// walk runs every `rediscoverInterval`, and the polls in between only look
    /// at the handful it found. A session that starts mid-interval is noticed
    /// within a few seconds, which is well inside how long a turn takes.
    private func transcripts() -> [URL] {
        if let cached = activeFiles, Date().timeIntervalSince(lastDiscovery) < rediscoverInterval {
            return cached
        }
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                // Anything untouched for an hour is history, not a live session.
                if let m = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate, Date().timeIntervalSince(m) < 3600 {
                    found.append(url)
                }
            }
        }
        activeFiles = found
        lastDiscovery = Date()
        // Forget files that dropped out, so `states` doesn't grow all session.
        let live = Set(found.map(\.path))
        states = states.filter { live.contains($0.key) }
        return found
    }

    /// Whether the transcript's last substantive record is the agent speaking.
    ///
    /// Claude Code tags records `{"type":"assistant"|"user"}`; Codex nests a
    /// `payload` and marks assistant output with a role or an `agent_message`
    /// type. Bookkeeping records (attachments, file-history snapshots, token
    /// counts) are skipped — they trail a turn and would otherwise mask it.
    private func endsWithAgentTurn(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 262_144
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(),
              let text = String(data: data, encoding: .utf8) else { return false }
        return Self.turnEnded(inTail: text)
    }

    /// The decision itself, separated from reading the file so it can be tested
    /// against real transcript shapes. Both bugs shipped in 1.8.x lived here.
    nonisolated static func turnEnded(inTail text: String) -> Bool {
        let ignored: Set<String> = ["attachment", "file-history-snapshot", "summary",
                                    "system", "token_count", "event", "turn_context"]
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let payload = obj["payload"] as? [String: Any]
            let kind = ((payload?["type"] ?? obj["type"]) as? String)?.lowercased() ?? ""
            if kind.isEmpty || ignored.contains(kind) { continue }
            let role = ((payload?["role"] ?? (obj["message"] as? [String: Any])?["role"]) as? String)?
                .lowercased()
            if kind.contains("user") || role == "user" { return false }
            if kind.contains("assistant") || kind.contains("agent") || role == "assistant" {
                return true
            }
            // An unrecognised record type is not evidence of a finished turn.
            return false
        }
        return false
    }

    /// Recovers the working directory from a Claude Code project folder name.
    ///
    /// Claude Code writes the cwd with every slash turned into a dash, which is
    /// lossy: `-Users-me-bid-no-bid` could be `/Users/me/bid/no/bid` or
    /// `/Users/me/bid-no-bid`. The only way to tell is to ask the filesystem, so
    /// this walks down from `/` taking the longest run of segments that actually
    /// exists at each level. `exists` is injected so the decision can be tested
    /// against a fixed tree rather than this machine's.
    nonisolated static func claudePath(
        fromDirectory dir: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let parts = dir.split(separator: "-").map(String.init)
        guard !parts.isEmpty else { return nil }
        var path = ""
        var i = 0
        while i < parts.count {
            // Longest first: prefer the real `bid-no-bid` over a `bid` that
            // happens to also exist.
            var taken = 0
            for end in stride(from: parts.count, to: i, by: -1) {
                let candidate = path + "/" + parts[i..<end].joined(separator: "-")
                if exists(candidate) { path = candidate; taken = end - i; break }
            }
            if taken == 0 {
                // Nothing below here exists any more — the directory was renamed
                // or deleted. Keep the rest verbatim rather than losing it.
                return path + "/" + parts[i...].joined(separator: "-")
            }
            i += taken
        }
        return path.isEmpty ? nil : path
    }

    /// The label shown on the peek.
    nonisolated static func claudeProjectName(
        fromDirectory dir: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        guard let path = claudePath(fromDirectory: dir, exists: exists) else { return nil }
        // A session started in the home directory would otherwise peek as your
        // account name, which reads like a project that doesn't exist.
        return displayName(forPath: path, home: home)
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    /// The same bounded window the session scanner reads for Codex's newest
    /// request. A notification title must never require loading an entire
    /// multi-megabyte transcript on the main actor.
    private func tailText(of url: URL, limit: UInt64 = 262_144) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Builds a peek matching what the hooks emit, so the two dedup against
    /// each other rather than double-peeking.
    private func alert(for url: URL) -> DevReadyAlert? {
        let isCodex = url.path.contains("/.codex/")
        // Codex's filename is `rollout-<timestamp>-<id>`; the hooks send the bare
        // id, and these two must match or the peeks won't dedup against each
        // other. Claude Code's filename *is* the session id.
        let sessionId = (isCodex ? firstValue(in: url, key: "id") : nil)
            ?? url.deletingPathExtension().lastPathComponent
        guard let project = projectName(for: url, isCodex: isCodex) else { return nil }
        let branch = gitBranch(for: url, isCodex: isCodex)
        return DevReadyAlert(
            title: isCodex ? Self.codexFinishedTitle(
                project: project,
                task: tailText(of: url).flatMap(AgentSessionScanner.codexLastPrompt(in:))
            ) : project,
            subtitle: "finished" + (branch.map { " · \($0)" } ?? ""),
            source: isCodex ? "Codex" : "Claude Code",
            agent: isCodex ? "codex" : "claude-code",
            // Deliberately no bundleId: nothing here says which terminal the
            // session runs in, and guessing would focus the wrong window.
            bundleId: nil,
            kind: .finished,
            createdAt: Date().timeIntervalSince1970,
            sessionId: sessionId,
            agentMessage: tailText(of: url).flatMap {
                AgentSessionScanner.lastAgentMessage(in: $0, isCodex: isCodex)
            }
        )
    }

    /// Keep the no-hook path in lockstep with `codex-notify.sh`. Codex often
    /// runs inside a generated workspace called `w`; it is a valid directory,
    /// but a one-letter completion title gives no useful information. A real
    /// user request wins, then a meaningful project name, then a truthful
    /// generic fallback.
    nonisolated static func codexFinishedTitle(project: String, task: String?) -> String {
        let cleanedTask = task?
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cleanedTask, cleanedTask.count >= 12, cleanedTask.contains(" ") {
            return String(cleanedTask.prefix(140))
        }

        let cleanedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let unhelpfulProjects = ["w", "tmp", "work"]
        if cleanedProject.count >= 3,
           !unhelpfulProjects.contains(cleanedProject.lowercased()) {
            return cleanedProject
        }
        return "Codex finished"
    }

    /// Claude Code encodes the working directory in the *directory* name with
    /// slashes turned into dashes (`-Users-me-Projects-NotchPill`). Codex keeps
    /// the cwd inside the transcript instead.
    private func projectName(for url: URL, isCodex: Bool) -> String? {
        if !isCodex {
            return Self.claudeProjectName(fromDirectory: url.deletingLastPathComponent().lastPathComponent)
        }
        guard let cwd = firstValue(in: url, key: "cwd") else { return nil }
        return Self.displayName(forPath: cwd)
    }

    /// Same home-directory rule as the Claude side; Codex records a real path so
    /// it needs no un-mangling, only the label.
    nonisolated static func displayName(
        forPath path: String,
        home: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        if path == home { return "Home" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }

    private func gitBranch(for url: URL, isCodex: Bool) -> String? {
        let cwd: String?
        if isCodex {
            cwd = firstValue(in: url, key: "cwd")
        } else {
            cwd = Self.claudePath(fromDirectory: url.deletingLastPathComponent().lastPathComponent)
        }
        guard let cwd, FileManager.default.fileExists(atPath: cwd) else { return nil }
        let head = URL(fileURLWithPath: cwd).appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        guard let ref = text.split(separator: "/").last else { return nil }
        return ref.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Reads the first occurrence of a top-level string key. Only the head of
    /// the file is scanned — session metadata is written up front, and these
    /// transcripts run to megabytes.
    private func firstValue(in url: URL, key: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let value = obj[key] as? String, !value.isEmpty { return value }
            // Codex wraps each record: {"timestamp":…,"type":…,"payload":{"cwd":…}}
            if let payload = obj["payload"] as? [String: Any],
               let value = payload[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }
}
