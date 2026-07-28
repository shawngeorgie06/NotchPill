import Foundation
import SQLite3

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

    private var activeFiles: [URL]?
    private var lastDiscovery = Date.distantPast
    private let rediscoverInterval: TimeInterval = 15

    /// Sessions the hooks told us are blocked, by session id. A pending prompt
    /// is not written to a transcript until it is answered, so for the terminal
    /// agents this is the only way to know.
    private var blockedSessions: [String: Date] = [:]
    /// Prompt text by file path, invalidated by modification date.
    private var taskCache: [String: (stamp: Date?, task: String?)] = [:]
    /// Sub-agent type by agent id; immutable once known.
    private var subagentTypeCache: [String: (type: String, task: String?)] = [:]

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
        scan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        lastPublished = []
        activeFiles = nil
        taskCache.removeAll()
        blockedSessions.removeAll()
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
        let now = Date()
        // A blocked flag that nothing has refreshed is stale — the prompt was
        // answered in the terminal and we never heard about it.
        blockedSessions = blockedSessions.filter { now.timeIntervalSince($0.value) < 600 }

        var found = transcriptSessions(now: now)
        found.append(contentsOf: cursorSessions(now: now))
        // Keyed by path and otherwise unbounded: a long session would accumulate
        // an entry for every transcript that ever went live.
        let liveKeys = Set(found.map(\.id))
        taskCache = taskCache.filter { liveKeys.contains(URL(fileURLWithPath: $0.key)
            .deletingPathExtension().lastPathComponent) }
        let ordered = AgentSession.ordered(found)
        // An idle row is value-identical between polls, so suppressing the
        // publish froze its age on screen: "idle 4m" while ten minutes passed.
        // Compare the rendered labels too, so a row republishes exactly when
        // what it says would change.
        let labels = ordered.map(\.statusLabel)
        guard ordered != lastPublished || labels != lastLabels else { return }
        lastLabels = labels
        lastPublished = ordered
        onUpdate?(ordered)
    }

    private func transcriptSessions(now: Date) -> [AgentSession] {
        transcripts(now: now).compactMap { url in
            let isCodex = url.path.contains("/.codex/")
            guard let mod = modified(url) else { return nil }
            let sessionId = url.deletingPathExtension().lastPathComponent
            guard let project = projectName(for: url, isCodex: isCodex) else { return nil }
            let sidechain = Self.subagentId(from: url)
            let info = sidechain.flatMap { subagentInfo(for: $0, sidechain: url) }
            return AgentSession(
                id: sessionId,
                agent: isCodex ? "codex" : "claude-code",
                project: project,
                // A prompt answered in the terminal clears nothing, so the flag
                // would read "waiting" for ten minutes. Writing past the moment
                // it was recorded is better evidence than the timeout.
                state: AgentSession.state(lastWrite: mod,
                                          blocked: blockedSessions[sessionId].map { mod <= $0 } ?? false,
                                          now: now),
                lastActivity: mod,
                locatorId: sidechain == nil ? sessionId : parentSessionId(of: url),
                subagent: info?.type,
                // A sidechain has no `last-prompt` record, so without the
                // parent's description a sub-agent row had no task line at all
                // — and two Explores looked identical.
                task: AgentSession.summarize(info?.task
                                             ?? currentTask(in: url, isCodex: isCodex)))
        }
    }

    private func transcripts(now: Date) -> [URL] {
        if let cached = activeFiles, now.timeIntervalSince(lastDiscovery) < rediscoverInterval {
            // Re-stat the cached handful; that is cheap and keeps "working"
            // responsive between full walks.
            let live = cached.filter { url in
                guard let m = modified(url) else { return false }
                return now.timeIntervalSince(m) < AgentSession.liveWindow
            }
            activeFiles = live      // don't re-stat the dead ones for 15s
            return live
        }
        var found: [URL] = []
        let fm = FileManager.default
        for root in roots {
            guard let e = fm.enumerator(at: root,
                                        includingPropertiesForKeys: [.contentModificationDateKey],
                                        options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" {
                if let m = modified(url), now.timeIntervalSince(m) < AgentSession.liveWindow {
                    found.append(url)
                }
            }
        }
        activeFiles = found
        lastDiscovery = now
        return found
    }

    /// The prompt the session is currently working on.
    ///
    /// Claude Code writes a `last-prompt` record whose `lastPrompt` is exactly
    /// this, updated each turn — so the tail is read backwards for the most
    /// recent one. Codex has no such record, so the *first* `user_message` is
    /// used instead: it is what the session was opened to do, which is the
    /// closest honest answer.
    ///
    /// Cached per file+mtime. This reads the last 256KB of a transcript that
    /// can run to tens of megabytes, and re-reading it every 3 seconds for a
    /// string that only changes once a turn would undo the CPU work.
    private func currentTask(in url: URL, isCodex: Bool) -> String? {
        let key = url.path
        // Stat once. Reading it again after parsing let a write land between the
        // two, storing the new mtime beside the old text — a stale row that
        // could never invalidate itself.
        let stamp = modified(url)
        if let cached = taskCache[key], cached.stamp == stamp { return cached.task }
        let task = isCodex ? codexFirstPrompt(url) : claudeLastPrompt(url)
        taskCache[key] = (stamp, task)
        return task
    }

    /// `…/<parent-session>/subagents/agent-x.jsonl` → `<parent-session>`.
    nonisolated static func parentSessionId(ofPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        guard url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        return url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
    }

    private func parentSessionId(of url: URL) -> String? {
        Self.parentSessionId(ofPath: url.path)
    }

    /// `…/subagents/agent-<id>.jsonl` → `<id>`, or nil for a normal session.
    nonisolated static func subagentId(from url: URL) -> String? {
        guard url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("agent-") else { return nil }
        return String(name.dropFirst("agent-".count))
    }

    /// The kind of sub-agent this sidechain is running.
    ///
    /// The sub-agent's own transcript never names its type; only the parent
    /// knows, because the type was an argument to the call that started it.
    /// The parent records a `Task`/`Agent` tool call carrying `subagent_type`,
    /// and the result quoting that call's id carries the agent id — so pairing
    /// the two maps one to the other.
    nonisolated static func subagentInfo(inParent text: String,
                                        agentId: String) -> (type: String, task: String?)? {
        var typeByToolUse: [String: (type: String, task: String?)] = [:]
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                if block["type"] as? String == "tool_use",
                   let name = block["name"] as? String, name == "Task" || name == "Agent",
                   let id = block["id"] as? String {
                    let input = block["input"] as? [String: Any]
                    // The description is what separates two runs of the same
                    // kind of agent. Without it, three Explores are three
                    // identical rows.
                    typeByToolUse[id] = (input?["subagent_type"] as? String ?? "agent",
                                         input?["description"] as? String)
                }
                if block["type"] as? String == "tool_result",
                   let id = block["tool_use_id"] as? String,
                   let info = typeByToolUse[id],
                   line.contains(agentId) {
                    return info
                }
            }
        }
        return nil
    }

    private func subagentInfo(for agentId: String,
                              sidechain url: URL) -> (type: String, task: String?)? {
        if let cached = subagentTypeCache[agentId] { return cached }
        // <project>/<session>/subagents/agent-x.jsonl → <project>/<session>.jsonl
        let sessionDir = url.deletingLastPathComponent().deletingLastPathComponent()
        let parent = sessionDir.deletingLastPathComponent()
            .appendingPathComponent(sessionDir.lastPathComponent + ".jsonl")
        guard let text = text(of: parent, tail: 524_288) else { return nil }
        let info = Self.subagentInfo(inParent: text, agentId: agentId)
        // Neither the type nor the description changes for a given agent, so
        // one successful lookup is the last one.
        if let info { subagentTypeCache[agentId] = info }
        return info
    }

    /// The sub-agent currently running, if one is.
    ///
    /// A sub-agent shows up as a `tool_use` block named Task/Agent; it is still
    /// running until a `tool_result` quotes that block's id back. Matching the
    /// two is what distinguishes "a reviewer is running right now" from "a
    /// reviewer ran twenty minutes ago", and only the first is worth a row.
    nonisolated static func runningSubagent(inTail text: String) -> String? {
        var finished = Set<String>()
        var candidate: (id: String, name: String)?
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content {
                let kind = block["type"] as? String
                if kind == "tool_result", let id = block["tool_use_id"] as? String {
                    finished.insert(id)
                }
                guard kind == "tool_use",
                      let name = block["name"] as? String, name == "Task" || name == "Agent",
                      let id = block["id"] as? String, !finished.contains(id) else { continue }
                let input = block["input"] as? [String: Any]
                let type = (input?["subagent_type"] as? String) ?? "agent"
                if candidate == nil { candidate = (id, type) }
            }
            if let candidate, !finished.contains(candidate.id) { return candidate.name }
        }
        return nil
    }

    private func claudeLastPrompt(_ url: URL) -> String? {
        guard let text = text(of: url, tail: 262_144) else { return nil }
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "last-prompt",
                  let prompt = obj["lastPrompt"] as? String, !prompt.isEmpty else { continue }
            return prompt
        }
        return nil
    }

    private func codexFirstPrompt(_ url: URL) -> String? {
        guard let text = text(of: url, head: 262_144) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "user_message",
                  let message = payload["message"] as? String, !message.isEmpty else { continue }
            return message
        }
        return nil
    }

    /// Reads a window of a file as text.
    ///
    /// `String(data:encoding:)` returns nil for the *entire* buffer if the
    /// window happens to start mid-codepoint, which silently blanked a row's
    /// task and sub-agent until the file size shifted. Lossy decoding cannot
    /// fail, and a replacement character in one line is harmless here.
    private func text(of url: URL, tail: UInt64? = nil, head: Int? = nil) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let data: Data?
        if let tail {
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > tail ? size - tail : 0)
            data = try? handle.readToEnd()
        } else {
            data = try? handle.read(upToCount: head ?? 32_768)
        }
        guard let data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func modified(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func projectName(for url: URL, isCodex: Bool) -> String? {
        if !isCodex {
            // A sub-agent transcript sits at <project>/<session>/subagents/agent-x
            // so its immediate parent directory is literally "subagents". Climb
            // to the project directory or every sub-agent row would be named
            // after the folder rather than the work.
            var dir = url.deletingLastPathComponent()
            if dir.lastPathComponent == "subagents" {
                dir = dir.deletingLastPathComponent().deletingLastPathComponent()
            }
            return AgentTranscriptProvider.claudeProjectName(fromDirectory: dir.lastPathComponent)
        }
        guard let cwd = firstValue(in: url, key: "cwd") else { return nil }
        return AgentTranscriptProvider.displayName(forPath: cwd)
    }

    private func firstValue(in url: URL, key: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768),
              let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let v = obj[key] as? String, !v.isEmpty { return v }
            if let payload = obj["payload"] as? [String: Any],
               let v = payload[key] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - Cursor

    private var cursorDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    private func cursorSessions(now: Date) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: cursorDB.path) else { return [] }
        var db: OpaquePointer?
        // Plain path, not a URI: `file:\(path)?mode=ro` embeds the path raw, so
        // a `?` or `#` anywhere in it silently truncates the filename. The
        // read-only flag already does what `mode=ro` was there for.
        guard sqlite3_open_v2(cursorDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let cutoff = Int64(now.addingTimeInterval(-AgentSession.liveWindow).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT composerId, workspaceId, lastUpdatedAt, value FROM composerHeaders
        WHERE lastUpdatedAt > ? AND isArchived = 0 AND isSubagent = 0
        ORDER BY lastUpdatedAt DESC LIMIT 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var out: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let workspace = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 2)) / 1000)
            let json = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
            let meta = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            let blocked = meta["hasBlockingPendingActions"] as? Bool ?? false
            out.append(AgentSession(
                id: id,
                agent: "cursor",
                project: workspace.flatMap(cursorProject) ?? "Cursor",
                state: AgentSession.state(lastWrite: updated, blocked: blocked, now: now),
                lastActivity: updated,
                // Cursor names its own conversations, which beats anything that
                // could be recovered from the prompt.
                task: AgentSession.summarize((meta["name"] as? String)
                                             ?? (meta["subtitle"] as? String))))
        }
        return out
    }

    private func cursorProject(_ workspaceId: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = obj["folder"] as? String,
              let decoded = URL(string: folder) else { return nil }
        return AgentTranscriptProvider.displayName(forPath: decoded.path)
    }
}
