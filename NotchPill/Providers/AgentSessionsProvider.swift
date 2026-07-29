import Foundation

/// Lists the agent conversations that are alive right now, across Claude Code,
/// Codex and Cursor.
///
/// This reuses the same on-disk evidence the peek watchers use, but asks a
/// different question. `AgentTranscriptProvider` waits for a transcript to go
/// *quiet* and fires once; this one reports continuously on what exists. They
/// deliberately stay separate: a peek is an event with dedup and an auto-dismiss
/// timer, while this is a list that is simply true or not.
///
/// Discovery is cached the same way, because walking both trees costs hundreds
/// of `stat` calls and almost none of the files are live.
@MainActor
final class AgentSessionsProvider {
    var onUpdate: (([AgentSession]) -> Void)?

    private let pollInterval: TimeInterval = 3
    private var timer: Timer?
    private var lastPublished: [AgentSession] = []
    private var lastLabels: [String] = []
    private let scanner = AgentSessionScanner()
    private var scanning = false
    /// Invalidates results from scans started before the last stop.
    private var generation = 0


    /// Sessions the hooks told us are blocked, by session id. A pending prompt
    /// is not written to a transcript until it is answered, so for the terminal
    /// agents this is the only way to know.
    private var blockedSessions: [String: Date] = [:]


    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        scan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastPublished = []
        blockedSessions.removeAll()
        lastLabels = []
        // A scan already in flight would publish after this, putting the card
        // back on screen moments after it was told to go away. Bump the
        // generation so its result is discarded.
        generation &+= 1
        scanning = false
        Task { await scanner.reset() }
        // Publish the empty list, or the card keeps showing whatever was on
        // screen when we stopped, forever.
        onUpdate?([])
    }

    /// Called when a peek says a session is blocked (or has stopped being).
    func noteWaiting(sessionId: String?, waiting: Bool) {
        guard let id = sessionId, !id.isEmpty else { return }
        if waiting { blockedSessions[id] = Date() } else { blockedSessions[id] = nil }
    }

    private func scan() {
        guard AppSettings.shared.showExpandedAgents else {
            if !lastPublished.isEmpty { lastPublished = []; onUpdate?([]) }
            return
        }
        // One scan at a time. A slow disk must not queue up overlapping walks
        // that all publish the same answer.
        guard !scanning else { return }
        scanning = true
        let now = Date()
        // A blocked flag that nothing has refreshed is stale — the prompt was
        // answered in the terminal and we never heard about it.
        blockedSessions = blockedSessions.filter { now.timeIntervalSince($0.value) < 600 }
        let blocked = blockedSessions
        let issued = generation
        Task { [weak self] in
            guard let self else { return }
            let sessions = await scanner.sessions(now: now, blocked: blocked)
            await MainActor.run { self.publish(sessions, from: issued) }
        }
    }

    private static let logging = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_AGENTS"] == "1"

    /// Appends each published list to `~/.notchpill/agents.log`.
    ///
    /// The card is only visible while the notch is hovered, so "it shows
    /// nothing" and "it was never given anything" look identical from outside.
    /// This tells the two apart. Off by default: the lines carry project names
    /// and task text.
    private static func log(_ sessions: [AgentSession]) {
        guard logging else { return }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".notchpill")
        let url = dir.appendingPathComponent("agents.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        var line = "\(stamp) published \(sessions.count)\n"
        for s in sessions {
            line += "    \(s.displayName) | \(s.project) | \(s.statusLabel)"
                + " | \(s.task ?? "-") | locator=\(s.locatorId ?? "-")\n"
        }
        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            if (try? handle.seekToEnd()) ?? 0 > 512_000 {
                try? handle.close()
                try? FileManager.default.removeItem(at: url)
                try? data.write(to: url)
                return
            }
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private func publish(_ ordered: [AgentSession], from issued: Int) {
        guard issued == generation else { return }   // stopped mid-scan
        scanning = false
        // An idle row is value-identical between polls, so suppressing the
        // publish froze its age on screen: "idle 4m" while ten minutes passed.
        // Compare the rendered labels too, so a row republishes exactly when
        // what it says would change.
        let labels = ordered.map(\.statusLabel)
        guard ordered != lastPublished || labels != lastLabels else { return }
        lastLabels = labels
        lastPublished = ordered
        Self.log(ordered)
        onUpdate?(ordered)
    }
}
