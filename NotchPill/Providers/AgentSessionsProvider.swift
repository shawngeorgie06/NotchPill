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
    var onOpenCodeUsageUpdate: ((OpenCodeUsage?) -> Void)?
    var onCodexQuotaUpdate: ((CodexQuota?) -> Void)?
    var onClaudeQuotaUpdate: ((ClaudeQuota?) -> Void)?
    var onCursorQuotaUpdate: ((CursorQuota?) -> Void)?

    private let pollInterval: TimeInterval = 3
    private var timer: Timer?
    private var lastPublished: [AgentSession] = []
    private var lastLabels: [String] = []
    private var lastOpenCodeUsage: OpenCodeUsage?
    private var lastCodexQuota: CodexQuota?
    private var lastClaudeQuota: ClaudeQuota?
    private var lastCursorQuota: CursorQuota?
    private let scanner = AgentSessionScanner()
    /// Rate-limits itself to one request a minute, so this is safe to consult
    /// on every scan.
    private let codexUsage = CodexUsageService()
    /// Only ever consulted when the setting is on: the first read raises a
    /// Keychain consent prompt.
    private let claudeUsage = ClaudeUsageService()
    /// Reads a token from a file rather than the Keychain, so this costs no
    /// prompt — but it is still only consulted when asked for.
    private let cursorUsage = CursorUsageService()
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
        lastOpenCodeUsage = nil
        lastCodexQuota = nil
        lastClaudeQuota = nil
        lastCursorQuota = nil
        // A scan already in flight would publish after this, putting the card
        // back on screen moments after it was told to go away. Bump the
        // generation so its result is discarded.
        generation &+= 1
        scanning = false
        Task { await scanner.reset() }
        // Publish the empty list, or the card keeps showing whatever was on
        // screen when we stopped, forever.
        onUpdate?([])
        onOpenCodeUsageUpdate?(nil)
        onCodexQuotaUpdate?(nil)
        onClaudeQuotaUpdate?(nil)
        onCursorQuotaUpdate?(nil)
    }

    /// Called when a peek says a session is blocked (or has stopped being).
    func noteWaiting(sessionId: String?, waiting: Bool) {
        guard let id = sessionId, !id.isEmpty else { return }
        if waiting { blockedSessions[id] = Date() } else { blockedSessions[id] = nil }
    }

    private func scan() {
        // The Claude card has its own switch, so turning the live-agents card
        // off must not silently take it down too — the setting that is still
        // ticked would then describe a card that never appears.
        guard AppSettings.shared.showExpandedAgents
            || AppSettings.shared.showClaudeUsage
            || AppSettings.shared.showCursorUsage else {
            if !lastPublished.isEmpty { lastPublished = []; onUpdate?([]) }
            if lastOpenCodeUsage != nil { lastOpenCodeUsage = nil; onOpenCodeUsageUpdate?(nil) }
            if lastCodexQuota != nil { lastCodexQuota = nil; onCodexQuotaUpdate?(nil) }
            if lastClaudeQuota != nil { lastClaudeQuota = nil; onClaudeQuotaUpdate?(nil) }
            if lastCursorQuota != nil { lastCursorQuota = nil; onCursorQuotaUpdate?(nil) }
            return
        }
        let wantsAgents = AppSettings.shared.showExpandedAgents
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
        let wantsClaude = AppSettings.shared.showClaudeUsage
        let wantsCursor = AppSettings.shared.showCursorUsage
        Task { [weak self] in
            guard let self else { return }
            let sessions = wantsAgents
                ? await scanner.sessions(now: now, blocked: blocked) : []
            let usage = wantsAgents
                ? await scanner.openCodeUsage(since: Calendar.current.startOfDay(for: now)) : nil
            // Live from OpenAI, falling back to the transcript only when the
            // API cannot be reached. The transcript is a cached copy of the
            // number from your last request: it expires with the two-hour
            // liveness window, and it was measured showing "4% used · 0 credits"
            // while the account was actually at 100% with a $298 balance.
            var quota = wantsAgents ? await self.codexUsage.quota(now: now) : nil
            if wantsAgents, quota == nil { quota = await scanner.codexQuota(now: now) }
            // Never touched unless asked for — the first read prompts.
            let claude = wantsClaude ? await self.claudeUsage.quota(now: now) : nil
            let cursor = wantsCursor ? await self.cursorUsage.quota(now: now) : nil
            await MainActor.run {
                self.publish(sessions, usage: usage, quota: quota,
                             claude: claude, cursor: cursor, from: issued)
            }
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
                + " | \(s.runtimeLabel ?? "-") | \(s.contextLabel ?? "-")"
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

    private func publish(_ ordered: [AgentSession], usage: OpenCodeUsage?, quota: CodexQuota?,
                         claude: ClaudeQuota?, cursor: CursorQuota?, from issued: Int) {
        guard issued == generation else { return }   // stopped mid-scan
        scanning = false
        if usage != lastOpenCodeUsage {
            lastOpenCodeUsage = usage
            onOpenCodeUsageUpdate?(usage)
        }
        if quota != lastCodexQuota {
            lastCodexQuota = quota
            onCodexQuotaUpdate?(quota)
        }
        if claude != lastClaudeQuota {
            lastClaudeQuota = claude
            onClaudeQuotaUpdate?(claude)
        }
        if cursor != lastCursorQuota {
            lastCursorQuota = cursor
            onCursorQuotaUpdate?(cursor)
        }
        // An idle row is value-identical between polls, so suppressing the
        // publish froze its age on screen: "idle 4m" while ten minutes passed.
        // Compare the rendered labels too, so a row republishes exactly when
        // what it says would change.
        let labels = ordered.map(\.statusLabel)
        guard ordered != lastPublished || labels != lastLabels else { return }
        lastLabels = labels
        lastPublished = ordered
        Self.log(ordered)
        // Counts and states only — the project names and task text that make
        // the file log private stay out of the in-app one.
        let states = Dictionary(grouping: ordered, by: { $0.state.name })
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.count)" }
            .joined(separator: " ")
        LogStore.log("agents", ordered.isEmpty
            ? "no live sessions"
            : "\(ordered.count) session(s): \(states)")
        onUpdate?(ordered)
    }
}
