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
    /// What a transcript said about itself, by path. A file cannot stop being
    /// a sidechain, so this is read once and kept.
    private var identityCache: [String: SidechainIdentity] = [:]
    /// Agent ids whose parent transcript has already been searched, so a miss
    /// costs one read rather than one per scan.
    private var attemptedParentLookup: Set<String> = []

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
        identityCache.removeAll()
        attemptedParentLookup.removeAll()
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
        let current = AgentSession.current(found, now: now)
        // The other invisible exclusion, and a confusing one: a session can be
        // scanned successfully and still not appear, because `idleWindow` is
        // thirty seconds. Without this line the card and the disk disagree for
        // a reason nothing anywhere states.
        if current.count != found.count {
            var aging = ScanLedger(unit: "sessions")
            for session in found {
                if current.contains(where: { $0.id == session.id }) {
                    aging.keep()
                } else {
                    aging.drop("idle>\(Int(AgentSession.idleWindow))s")
                }
            }
            if aging.differs(from: lastAgingLedger) { LogStore.log("scan", aging.summary) }
            lastAgingLedger = aging
        } else {
            lastAgingLedger = nil
        }
        return AgentSession.ordered(current)
    }

    private var blockedSessions: [String: Date] = [:]

    /// The last reconciliations, so an unchanged scan stays silent.
    private var lastLedger: ScanLedger?
    private var lastAgingLedger: ScanLedger?

    private func transcriptSessions(now: Date) -> [AgentSession] {
        var ledger = ScanLedger(unit: "transcripts")
        defer {
            if ledger.differs(from: lastLedger) {
                LogStore.log("scan", ledger.summary)
            }
            lastLedger = ledger
        }
        return transcripts(now: now).compactMap { url -> AgentSession? in
            let isCodex = url.path.contains("/.codex/")
            guard let mod = modified(url) else {
                ledger.drop("unreadable")
                return nil
            }
            let sessionId = url.deletingPathExtension().lastPathComponent
            // Never drop a live session just because it could not be named.
            //
            // A Codex project name comes from `cwd` in the transcript's first
            // record, and desktop Codex writes base instructions large enough
            // to push that past the read window (see `firstValue`). This used to
            // `guard … else { return nil }`, so a running agent disappeared from
            // the list entirely — no row, no log line, nothing to notice. An
            // unnamed row is a far smaller loss than a missing one, and the
            // agent name is still true.
            let project = projectName(for: url, isCodex: isCodex)
                ?? Self.fallbackProjectName(isCodex: isCodex)
            // The desktop app starts an internal Codex reviewer for every
            // escalation. It is protocol machinery, not a conversation the
            // user is working with; it also writes more recently than the
            // actual task and could push that useful row below the fold.
            if isCodex, codexIsApprovalReviewer(url) {
                ledger.drop("codex-approval-reviewer")
                return nil
            }
            // An SDK-driven run is not a session the user can tab to.
            if !isCodex, !claudeIsInteractive(url) {
                ledger.drop("sdk-run")
                return nil
            }
            ledger.keep()
            // Ask the transcript what it is. Codex has no sidechains, so it is
            // not read for one; the path check remains only as a fallback for
            // a file whose records could not be parsed at all.
            let identity = isCodex ? SidechainIdentity() : sidechainIdentity(for: url)
            let pathAgentId = Self.subagentId(from: url)
            let isSubagent = identity.isSidechain || (!isCodex && pathAgentId != nil)
            let sidechain = isSubagent ? (identity.agentId ?? pathAgentId) : nil
            // The parent is still the only place a dispatch *description*
            // exists, so it stays worth one lookup.
            let info = sidechain.flatMap { subagentInfo(for: $0, sidechain: url) }
            let modelInfo = currentModel(in: url, isCodex: isCodex)
            return AgentSession(
                id: sessionId,
                agent: isCodex ? "codex" : "claude-code",
                project: project,
                // A prompt answered in the terminal clears nothing, so the flag
                // would read "waiting" for ten minutes. Writing past the moment
                // it was recorded is better evidence than the timeout.
                state: AgentSession.state(
                    lastWrite: mod,
                    blocked: blockedSessions[sessionId].map { mod <= $0 } ?? false,
                    blockedSince: blockedSessions[sessionId],
                    now: now),
                lastActivity: mod,
                // A sub-agent has no window of its own; tabbing to one means
                // tabbing to the session that dispatched it. The records name
                // that session outright, so the path is only the fallback.
                locatorId: isSubagent
                    ? (identity.parentSessionId ?? parentSessionId(of: url))
                    : sessionId,
                directory: workingDirectory(for: url, isCodex: isCodex),
                // `attributionAgent` comes from the sub-agent's own transcript
                // and is always there; the parent lookup only still matters
                // for a transcript written before that field existed.
                subagent: identity.agentType ?? info?.type,
                // A sidechain has no `last-prompt` record, so without the
                // parent's description a sub-agent row had no task line at all
                // — and two Explores looked identical. The dispatch prompt in
                // its own file covers the case where the parent has since
                // outgrown the tail window.
                task: AgentSession.summarize(
                    info?.task
                        ?? (isSubagent ? sidechainPrompt(in: url) : nil)
                        ?? currentTask(in: url, isCodex: isCodex)),
                toolActivity: currentToolActivity(in: url, isCodex: isCodex),
                model: modelInfo.model,
                effort: modelInfo.effort,
                contextTokens: contextTokens(in: url, isCodex: isCodex),
                startedAt: created(url))
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
    ///
    /// The layout is corroboration, not the answer. `sidechainIdentity` reads
    /// what the transcript says about itself; this only stands in when the
    /// records are unreadable.
    nonisolated static func subagentId(from url: URL) -> String? {
        guard url.deletingLastPathComponent().lastPathComponent == "subagents" else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("agent-") else { return nil }
        return String(name.dropFirst("agent-".count))
    }

    /// What a Claude transcript says about itself.
    ///
    /// Telling a sub-agent apart from the session the user is actually talking
    /// to used to be a question about the file's *path* — a transcript counted
    /// as a sidechain if it sat in a `subagents/` directory under a name
    /// starting `agent-`. That is a convention of one release's on-disk layout,
    /// not a fact about the run, and getting it wrong is the expensive kind of
    /// wrong: a sub-agent promoted to a top-level row is a notification
    /// claiming to be the thing you were waiting on.
    ///
    /// Every record carries the answer directly. `isSidechain` is the flag
    /// Claude Code itself sets, `sessionId` on a sidechain names the *parent*
    /// session rather than the file, and `attributionAgent` names the kind of
    /// agent running — which the sub-agent's own transcript was previously
    /// assumed never to know.
    struct SidechainIdentity: Equatable {
        var isSidechain = false
        var agentId: String?
        /// The session this work belongs to — the one worth tabbing to.
        var parentSessionId: String?
        /// `code-reviewer`, `Explore`, `general-purpose`…
        var agentType: String?
    }

    nonisolated static func sidechainIdentity(in text: String) -> SidechainIdentity {
        var identity = SidechainIdentity()
        var sawFlag = false
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let flag = obj["isSidechain"] as? Bool, !sawFlag {
                identity.isSidechain = flag
                sawFlag = true
            }
            if identity.agentId == nil, let id = obj["agentId"] as? String, !id.isEmpty {
                identity.agentId = id
            }
            if identity.parentSessionId == nil,
               let id = obj["sessionId"] as? String, !id.isEmpty {
                identity.parentSessionId = id
            }
            // Written on the assistant's records rather than the opening one,
            // so this keeps reading after the flag is settled.
            if identity.agentType == nil,
               let type = obj["attributionAgent"] as? String, !type.isEmpty {
                identity.agentType = type
            }
            if sawFlag, identity.agentId != nil,
               identity.parentSessionId != nil, identity.agentType != nil { break }
        }
        return identity
    }

    /// Read once per file from the head window and kept: a transcript cannot
    /// change its mind about being a sidechain.
    private func sidechainIdentity(for url: URL) -> SidechainIdentity {
        if let cached = identityCache[url.path] { return cached }
        guard let text = text(ofHead: url) else { return SidechainIdentity() }
        let identity = Self.sidechainIdentity(in: text)
        identityCache[url.path] = identity
        return identity
    }

    /// The prompt a sub-agent was dispatched with.
    ///
    /// A sidechain has no `last-prompt` record, and the parent's `description`
    /// is only reachable while the call that started it is still inside the
    /// tail window — on a parent transcript that has grown to a hundred
    /// megabytes it usually is not. The dispatch prompt is the first thing in
    /// the sub-agent's own file and says what it was sent to do.
    private func sidechainPrompt(in url: URL) -> String? {
        guard let text = text(ofHead: url) else { return nil }
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any] else { continue }
            if let text = message["content"] as? String {
                return Self.clean(text)
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let joined = blocks.compactMap { $0["text"] as? String }.joined(separator: " ")
                if !joined.isEmpty { return Self.clean(joined) }
            }
        }
        return nil
    }

    private func text(ofHead url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.metadataReadWindow) else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
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
        // A miss is permanent and worth remembering. The dispatch record only
        // exists inside the parent's tail window, and a parent that has grown
        // past it never gets shorter — so without this, every scan re-read half
        // a megabyte of a transcript that will never hold the answer.
        if attemptedParentLookup.contains(agentId) { return nil }
        attemptedParentLookup.insert(agentId)
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

    /// Whether a Claude Code transcript belongs to a session someone is sitting
    /// in front of.
    ///
    /// `~/.claude/projects` is not a list of terminal sessions — it is a list of
    /// every Claude Code run on the machine, and anything driven through the SDK
    /// writes a transcript there exactly like an interactive session does. On
    /// this machine 260 of 286 transcripts are SDK runs; only 22 are `cli`. Each
    /// one that gets written inside the two-hour `liveWindow` becomes a row in
    /// Live Agents for an agent the user never started and cannot tab to, on
    /// whatever model the SDK caller chose — which is one way a model you are
    /// not using appears on the card.
    ///
    /// Unknown or missing entrypoints count as interactive. Older Claude Code
    /// versions wrote no `entrypoint` at all, and this codebase would rather
    /// show an imperfect row than silently hide a running agent.
    nonisolated static func claudeIsInteractive(entrypoint: String?) -> Bool {
        guard let entrypoint = entrypoint?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !entrypoint.isEmpty else { return true }
        // `sdk-py`, `sdk-cli`, and whatever the next binding is called.
        return !entrypoint.hasPrefix("sdk")
    }

    private func claudeIsInteractive(_ url: URL) -> Bool {
        Self.claudeIsInteractive(entrypoint: firstValue(in: url, key: "entrypoint"))
    }

    private func codexIsApprovalReviewer(_ url: URL) -> Bool {
        guard let text = text(of: url, tail: 262_144) else { return false }
        return Self.codexLastPrompt(in: text) == "Reviewing a permission request"
    }

    /// The latest tool call answers “what is it doing?” more usefully than a
    /// generic working dot. It remains a one-line local summary, never a full
    /// transcript replay.
    private func currentToolActivity(in url: URL, isCodex: Bool) -> AgentToolActivity? {
        guard let text = text(of: url, tail: 262_144) else { return nil }
        return isCodex ? Self.codexToolActivity(in: text) : Self.claudeToolActivity(in: text)
    }

    /// The model and effort the session is currently running.
    ///
    /// Read from the newest record backwards, because both can change mid
    /// session — switching model, or a sub-agent running on a different one
    /// than its parent — and the row should say what is running now, not what
    /// it started on.
    private func currentModel(in url: URL, isCodex: Bool) -> (model: String?, effort: String?) {
        guard let text = text(of: url, tail: 262_144) else { return (nil, nil) }
        return isCodex ? Self.codexModel(in: text) : Self.claudeModel(in: text)
    }

    /// Claude Code puts the model inside `message` and the effort beside it at
    /// the top level of the same record.
    nonisolated static func claudeModel(in text: String) -> (model: String?, effort: String?) {
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let model = message["model"] as? String,
                  !model.isEmpty, model != "<synthetic>" else { continue }
            return (model, obj["effort"] as? String)
        }
        return (nil, nil)
    }

    /// Codex records both under `payload`, with the effort under its longer
    /// name. `thread_settings` is preferred where present: it is the session's
    /// settled configuration rather than one turn's parameters.
    nonisolated static func codexModel(in text: String) -> (model: String?, effort: String?) {
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let settings = payload["thread_settings"] as? [String: Any]
            let model = (settings?["model"] as? String) ?? (payload["model"] as? String)
            guard let model, !model.isEmpty else { continue }
            let effort = (settings?["reasoning_effort"] as? String)
                ?? (payload["reasoning_effort"] as? String)
                ?? (payload["effort"] as? String)
            return (model, effort)
        }
        return (nil, nil)
    }

    nonisolated static func claudeToolActivity(in text: String) -> AgentToolActivity? {
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            for block in content.reversed() where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String else { continue }
                return toolActivity(name: name, input: block["input"] as? [String: Any])
            }
        }
        return nil
    }

    nonisolated static func codexToolActivity(in text: String) -> AgentToolActivity? {
        for line in text.split(separator: "\n").reversed() {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "custom_tool_call",
                  let name = payload["name"] as? String else { continue }
            let input = (payload["input"] as? String).flatMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
            return toolActivity(name: name, input: input, rawInput: payload["input"] as? String)
        }
        return nil
    }

    nonisolated private static func toolActivity(name: String,
                                                 input: [String: Any]?,
                                                 rawInput: String? = nil) -> AgentToolActivity {
        let label: String
        switch name.lowercased() {
        case "exec", "bash", "shell", "run_command": label = "Bash"
        case "read", "read_file": label = "Read"
        case "edit", "apply_patch": label = "Edit"
        case "write", "write_file": label = "Write"
        case "glob": label = "Find"
        case "grep", "search": label = "Search"
        default: label = name
        }
        let raw = ["file_path", "path", "cmd", "command", "pattern", "query"]
            .compactMap { input?[$0] as? String }
            .first
            ?? command(in: rawInput)
        return AgentToolActivity(tool: label, detail: AgentSession.summarize(raw, limit: 46))
    }

    /// Desktop Codex serializes custom tool calls as a JavaScript expression
    /// (`tools.exec_command({"cmd":"…"})`), not as the JSON object used by
    /// its CLI transcript. Recover the one named argument we render, without
    /// trying to interpret or execute any of that expression.
    nonisolated private static func command(in text: String?) -> String? {
        guard let text, let key = text.range(of: "\"cmd\"") else { return nil }
        let afterKey = text[key.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let opening = afterColon.firstIndex(of: "\"") else { return nil }

        var escaped = ""
        var isEscaped = false
        for character in afterColon[afterColon.index(after: opening)...] {
            if character == "\"", !isEscaped { break }
            escaped.append(character)
            if character == "\\" { isEscaped.toggle() } else { isEscaped = false }
        }
        guard !escaped.isEmpty else { return nil }
        let wrapped = "\"" + escaped + "\""
        return try? JSONDecoder().decode(String.self, from: Data(wrapped.utf8))
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

    /// When the transcript first appeared, which is when the session started.
    /// Cheaper and steadier than parsing the first line's timestamp — Claude
    /// Code's opening record has no `timestamp` field at all.
    private func created(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
    }

    /// The live context size: what the next request will carry.
    ///
    /// Read from the newest usage record rather than summed over the file —
    /// these are cumulative per request, so adding them up would report a
    /// number many times the size of the window.
    private func contextTokens(in url: URL, isCodex: Bool) -> Int? {
        guard let text = text(of: url, tail: 262_144) else { return nil }
        return Self.contextTokens(in: text, isCodex: isCodex)
    }

    nonisolated static func contextTokens(in text: String, isCodex: Bool) -> Int? {
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            if isCodex {
                // Codex reports the window directly in its token_count events.
                guard let payload = object["payload"] as? [String: Any],
                      payload["type"] as? String == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = (info["last_token_usage"] as? [String: Any])
                        ?? (info["total_token_usage"] as? [String: Any])
                else { continue }
                let total = int(last["input_tokens"]) + int(last["cached_input_tokens"])
                if total > 0 { return total }
            } else {
                guard let message = object["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any] else { continue }
                // Prompt plus both cache figures. Output is excluded: it is not
                // carried into the next request, so counting it would inflate
                // the number against the window it is being compared to.
                let total = int(usage["input_tokens"])
                    + int(usage["cache_read_input_tokens"])
                    + int(usage["cache_creation_input_tokens"])
                if total > 0 { return total }
            }
        }
        return nil
    }

    /// The agent's last spoken message — what you would be replying *to*.
    ///
    /// A finished peek's subtitle is "finished · branch", which says an agent
    /// stopped but nothing about what it said. Replying to that is answering a
    /// question you cannot see. Both transcript formats are read here so every
    /// agent gets the same treatment rather than Claude Code alone.
    ///
    /// Reasoning and tool output are skipped deliberately: they are the
    /// agent's working, not its answer, and the last tool call is never the
    /// thing being replied to.
    nonisolated static func lastAgentMessage(in text: String, isCodex: Bool) -> String? {
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any] else { continue }
            if isCodex {
                guard let payload = object["payload"] as? [String: Any],
                      let type = payload["type"] as? String,
                      type == "agent_message" || type == "message" else { continue }
                // `message` is a plain string; `content` is the array form.
                if let direct = payload["message"] as? String,
                   let cleaned = clean(direct) { return cleaned }
                if let content = payload["content"] as? [[String: Any]] {
                    for part in content.reversed()
                    where part["type"] as? String == "output_text"
                        || part["type"] as? String == "text" {
                        if let cleaned = clean(part["text"] as? String) { return cleaned }
                    }
                }
            } else {
                guard object["type"] as? String == "assistant",
                      let message = object["message"] as? [String: Any],
                      let content = message["content"] as? [[String: Any]] else { continue }
                for part in content.reversed() where part["type"] as? String == "text" {
                    if let cleaned = clean(part["text"] as? String) { return cleaned }
                }
            }
        }
        return nil
    }

    /// The agent's last message for a session id, found by locating its
    /// transcript.
    ///
    /// Needed because a peek from a hook carries no transcript text — and
    /// hooks are the primary path, so populating this only where the peek was
    /// *built* from a transcript missed the ordinary case entirely.
    func lastAgentMessage(sessionId: String, now: Date = Date()) -> String? {
        for url in transcripts(now: now) {
            let isCodex = url.path.contains("/.codex/")
            let name = url.deletingPathExtension().lastPathComponent
            // Codex names its files `rollout-<timestamp>-<id>`; the hook sends
            // the bare id.
            guard name == sessionId || (isCodex && name.hasSuffix(sessionId)) else { continue }
            guard let text = text(of: url, tail: 262_144) else { return nil }
            return Self.lastAgentMessage(in: text, isCodex: isCodex)
        }
        return nil
    }

    /// Trimmed, redacted, and cut to something a notch row can hold.
    private nonisolated static func clean(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // The composer floats above every window, and an agent's last message
        // can quote a command line — which is where a token ends up.
        let redacted = SecretRedactor.redact(trimmed)
        // First paragraph only: the composer has room for a sentence or two,
        // not a report.
        let firstParagraph = redacted.components(separatedBy: "\n\n").first ?? redacted
        let flattened = firstParagraph.replacingOccurrences(of: "\n", with: " ")
        return AgentSession.summarize(flattened, limit: 220)
    }

    private nonisolated static func int(_ any: Any?) -> Int {
        (any as? Int) ?? (any as? NSNumber)?.intValue ?? 0
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

    /// Shown when a session is live but unnamed. Deliberately the agent's own
    /// name: it is the one thing still known to be true.
    nonisolated static func fallbackProjectName(isCodex: Bool) -> String {
        isCodex ? "Codex" : "Claude Code"
    }

    /// How much of a transcript's head is read looking for metadata.
    ///
    /// 256 KB, up from 32 KB. Desktop Codex's first record carries its full base
    /// instructions and routinely runs past 32 KB, which put `cwd` out of reach
    /// and — before the fallback above — made the whole session invisible. This
    /// is a bounded head read on a handful of files, so the cost is a few
    /// hundred KB per rediscovery, not a scan of the transcript.
    static let metadataReadWindow = 262_144

    private func firstValue(in url: URL, key: String) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.metadataReadWindow) else { return nil }
        // A fixed-size read can land mid-codepoint, and strict UTF-8 decoding of
        // that returns nil — losing the whole window over its last byte.
        let text = String(data: data, encoding: .utf8)
            ?? String(decoding: data, as: UTF8.self)
        return Self.firstValue(in: text, key: key)
    }

    /// Desktop Codex puts its large base instructions in the first JSONL
    /// record. That record can exceed the metadata read window, so JSON line
    /// decoding alone never sees a complete object even though `cwd` is near
    /// the beginning. Keep the normal structured path, then recover a simple
    /// string field from that partial record.
    nonisolated static func firstValue(in text: String, key: String) -> String? {
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let v = obj[key] as? String, !v.isEmpty { return v }
            if let payload = obj["payload"] as? [String: Any],
               let v = payload[key] as? String, !v.isEmpty { return v }
        }
        let escapedKey = NSRegularExpression.escapedPattern(for: key)
        let pattern = #"\"# + escapedKey + #"\"\s*:\s*\"([^\"]+)\""#
        if let expression = try? NSRegularExpression(pattern: pattern),
           let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range])
        }
        // A partial first record can end inside a huge instruction field. Keep
        // a tiny structured fallback for the simple metadata string fields
        // this method requests, rather than rejecting the whole record.
        let quotedKey = "\"\(key)\""
        guard let keyRange = text.range(of: quotedKey) else { return nil }
        let afterKey = text[keyRange.upperBound...]
        guard let colon = afterKey.firstIndex(of: ":") else { return nil }
        let afterColon = afterKey[afterKey.index(after: colon)...]
        guard let opening = afterColon.firstIndex(of: "\"") else { return nil }
        let valueStart = afterColon.index(after: opening)
        guard let closing = afterColon[valueStart...].firstIndex(of: "\"") else { return nil }
        let value = String(afterColon[valueStart..<closing])
        return value.isEmpty ? nil : value
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

    /// Codex desktop writes its provider-reported window usage into every
    /// `token_count` event. Read the newest available value locally; no account
    /// API, browser session, or made-up quota is involved.
    func codexQuota(now: Date) -> CodexQuota? {
        let files = transcripts(now: now)
            .filter { $0.path.contains("/.codex/") }
            .sorted { (modified($0) ?? .distantPast) > (modified($1) ?? .distantPast) }
        for file in files {
            if let text = text(of: file, tail: 262_144), let quota = Self.codexQuota(in: text) {
                return quota
            }
        }
        return nil
    }

    nonisolated static func codexQuota(in text: String) -> CodexQuota? {
        for line in text.split(separator: "\n").reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any],
                  let primary = limits["primary"] as? [String: Any],
                  let used = primary["used_percent"] as? Double else { continue }
            let resetSeconds = (primary["resets_at"] as? Double)
                ?? (primary["resets_at"] as? NSNumber)?.doubleValue
            let credits = limits["credits"] as? [String: Any]
            let balanceText = credits?["balance"] as? String
            let balance = balanceText.flatMap {
                Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX"))
            }
            let updatedAt = (object["timestamp"] as? String).flatMap {
                ISO8601DateFormatter().date(from: $0)
            }
            return CodexQuota(usedPercent: min(100, max(0, Int(used.rounded()))),
                              resetsAt: resetSeconds.map(Date.init(timeIntervalSince1970:)),
                              creditBalance: balance,
                              updatedAt: updatedAt)
        }
        return nil
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
