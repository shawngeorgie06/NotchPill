import Foundation
import SQLite3

/// The file and database reads behind the live-agents card.
///
/// Split out as an `actor` so none of it runs on the main thread. It walks two
/// directory trees, tails transcripts that reach tens of megabytes, and queries
/// a ~550MB SQLite database Cursor is actively writing — every three seconds.
/// On the main actor that is a UI hitch waiting for a slow disk; here the
/// notch stays responsive and only the finished list hops back.
actor AgentSessionScanner {
    private var activeFiles: [URL]?
    private var lastDiscovery = Date.distantPast
    private let rediscoverInterval: TimeInterval = 15
    /// Prompt text by file path, invalidated by modification date.
    private var taskCache: [String: (stamp: Date?, task: String?)] = [:]
    /// Sub-agent type and description by agent id; immutable once known.
    private var subagentTypeCache: [String: (type: String, task: String?)] = [:]

    private var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".claude/projects"),
                home.appendingPathComponent(".codex/sessions")]
    }

    func reset() {
        activeFiles = nil
        lastDiscovery = .distantPast
        taskCache.removeAll()
        subagentTypeCache.removeAll()
    }

    /// The whole scan, off the main actor.
    func sessions(now: Date, blocked: [String: Date]) -> [AgentSession] {
        blockedSessions = blocked
        var found = transcriptSessions(now: now)
        found.append(contentsOf: cursorSessions(now: now))
        found.append(contentsOf: openCodeSessions(now: now))
        // Keyed by path and otherwise unbounded: a long session would
        // accumulate an entry for every transcript that ever went live.
        let live = Set(found.map(\.id))
        taskCache = taskCache.filter { live.contains(URL(fileURLWithPath: $0.key)
            .deletingPathExtension().lastPathComponent) }
        // Aged out here rather than at render time, so an emptied card can take
        // itself off the row — and so the task cache above is pruned against
        // what actually got scanned, not what survives.
        return AgentSession.ordered(AgentSession.current(found, now: now))
    }

    private var blockedSessions: [String: Date] = [:]

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
                directory: workingDirectory(for: url, isCodex: isCodex),
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
    /// recent one. Codex has no such record, so its newest `user_message` is
    /// used instead. A Codex session can stay alive across several requests;
    /// the first message describes its history, while the newest one is what
    /// it is working on now.
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
        let task = isCodex ? codexLastPrompt(url) : claudeLastPrompt(url)
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

    private func codexLastPrompt(_ url: URL) -> String? {
        guard let text = text(of: url, tail: 262_144) else { return nil }
        return Self.codexLastPrompt(in: text)
    }

    /// Codex has used two transcript shapes for submitted requests:
    /// `event_msg.user_message` and `response_item` with `role=user`. Scan
    /// backwards so the live-agents card names the current request rather than
    /// the prompt that originally created a long-running session.
    nonisolated static func codexLastPrompt(in text: String) -> String? {
        var sawApprovalHandoff = false
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  let message = codexUserMessage(from: payload), !message.isEmpty else { continue }
            // The desktop app's approval reviewer is itself an agent session.
            // It receives a synthetic user_message containing the transcript
            // delta for every approval check; that is protocol plumbing, not a
            // user task, and otherwise leaked as a misleading live-agent row.
            if isCodexApprovalHandoff(message) {
                sawApprovalHandoff = true
                continue
            }
            return message
        }
        // A reviewer session has no user-authored request in its own transcript.
        // Give its row truthful, stable language instead of exposing the internal
        // handoff text. A normal Codex session never reaches this fallback.
        return sawApprovalHandoff ? "Reviewing a permission request" : nil
    }

    nonisolated private static func codexUserMessage(from payload: [String: Any]) -> String? {
        if payload["type"] as? String == "user_message" {
            return payload["message"] as? String
        }
        guard payload["role"] as? String == "user",
              let content = payload["content"] as? [[String: Any]] else { return nil }
        let pieces = content.compactMap { item -> String? in
            guard item["type"] as? String == "input_text" else { return nil }
            return item["text"] as? String
        }
        let message = pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? nil : message
    }

    nonisolated private static func isCodexApprovalHandoff(_ message: String) -> Bool {
        let prefix = "The following is the Codex agent history "
        return message.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
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

    /// The session's cwd, for anything that needs the repo rather than a label.
    private func workingDirectory(for url: URL, isCodex: Bool) -> String? {
        if isCodex { return firstValue(in: url, key: "cwd") }
        var dir = url.deletingLastPathComponent()
        if dir.lastPathComponent == "subagents" {
            dir = dir.deletingLastPathComponent().deletingLastPathComponent()
        }
        return AgentTranscriptProvider.claudePath(fromDirectory: dir.lastPathComponent)
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
            let folder = workspace.flatMap(cursorWorkspaceFolder)
            out.append(AgentSession(
                id: id,
                agent: "cursor",
                project: folder.flatMap { AgentTranscriptProvider.displayName(forPath: $0) }
                    ?? "Cursor",
                state: AgentSession.state(lastWrite: updated, blocked: blocked, now: now),
                lastActivity: updated,
                // Cursor records the workspace folder, so its sessions can feed
                // the CI card the same way a terminal agent's do. Without this
                // a repo open only in Cursor could never surface its builds.
                directory: folder,
                // Cursor names its own conversations, which beats anything that
                // could be recovered from the prompt.
                task: AgentSession.summarize((meta["name"] as? String)
                                             ?? (meta["subtitle"] as? String))))
        }
        return out
    }

    /// The folder a Cursor conversation belongs to.
    // MARK: - OpenCode

    /// OpenCode keeps its sessions in SQLite, like Cursor and unlike the
    /// transcript-file agents, so it is read the same read-only way.
    private var openCodeDB: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// Rows OpenCode is showing you right now.
    ///
    /// `time_archived` is the user putting a session away deliberately, which
    /// is a stronger signal than age — an archived session should not come back
    /// just because something touched it.
    static let openCodeSQL = """
    SELECT id, title, directory, parent_id, time_updated FROM session
    WHERE time_updated > ? AND time_archived IS NULL
    ORDER BY time_updated DESC LIMIT 10
    """

    /// The only durable usage OpenCode keeps locally. It deliberately does not
    /// attempt to infer an account quota or reset time from these values.
    static let openCodeUsageSQL = """
    SELECT COALESCE(SUM(tokens_input), 0), COALESCE(SUM(tokens_output), 0),
           COALESCE(SUM(tokens_reasoning), 0), COALESCE(SUM(tokens_cache_read), 0),
           COALESCE(SUM(tokens_cache_write), 0), COALESCE(SUM(cost), 0)
    FROM session
    WHERE time_updated >= ? AND time_archived IS NULL
    """

    func openCodeUsage(since: Date) -> OpenCodeUsage? {
        guard FileManager.default.fileExists(atPath: openCodeDB.path) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(openCodeDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return nil
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.openCodeUsageSQL, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(since.timeIntervalSince1970 * 1000))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let usage = OpenCodeUsage(
            inputTokens: sqlite3_column_int64(stmt, 0),
            outputTokens: sqlite3_column_int64(stmt, 1),
            reasoningTokens: sqlite3_column_int64(stmt, 2),
            cacheReadTokens: sqlite3_column_int64(stmt, 3),
            cacheWriteTokens: sqlite3_column_int64(stmt, 4),
            cost: sqlite3_column_double(stmt, 5))
        return usage.hasActivity ? usage : nil
    }

    private func openCodeSessions(now: Date) -> [AgentSession] {
        guard FileManager.default.fileExists(atPath: openCodeDB.path) else { return [] }
        var db: OpaquePointer?
        guard sqlite3_open_v2(openCodeDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db); return []
        }
        defer { sqlite3_close(db) }

        let cutoff = Int64(now.addingTimeInterval(-AgentSession.liveWindow).timeIntervalSince1970 * 1000)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.openCodeSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var out: [AgentSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let directory = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            let parent = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
            let updated = Date(timeIntervalSince1970: Double(sqlite3_column_int64(stmt, 4)) / 1000)
            out.append(AgentSession(
                id: id,
                agent: "opencode",
                project: directory.flatMap { AgentTranscriptProvider.displayName(forPath: $0) }
                    ?? "OpenCode",
                // Nothing in the schema says "blocked on you" — the permission
                // table is scoped to a project, not a session, so it cannot
                // tell you *which* session is waiting. Claiming waiting on that
                // basis would put a false Allow/Deny row on the card.
                state: AgentSession.state(lastWrite: updated, blocked: false, now: now),
                lastActivity: updated,
                directory: directory,
                // A child session is OpenCode's sub-agent. Naming it that way
                // makes it read like every other sub-agent row on the card.
                subagent: parent == nil ? nil : "subagent",
                task: AgentSession.summarize(title)))
        }
        return out
    }

    private func cursorWorkspaceFolder(_ workspaceId: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = obj["folder"] as? String,
              let decoded = URL(string: folder) else { return nil }
        return decoded.path
    }
}
