import Foundation

/// Whether the agent behind a session is still *running* — asked of the
/// operating system rather than inferred from a file's timestamp.
///
/// Every state on the card was derived from one number: when the transcript
/// was last written. That reads two failures as the same thing. An agent
/// running a ten-minute build writes nothing and looks idle, then vanishes
/// after `idleWindow` while it is very much alive; an agent whose terminal was
/// closed also writes nothing, and keeps a row that says "working" for the
/// next forty-five seconds. Silence is not the signal — the process is.
///
/// cmux records the pid it launched each agent under, so the answer is already
/// on disk. This reads it and asks the kernel.
///
/// Read-only, and tolerant in the same way as `CmuxIndex`: this is another
/// app's private state file, every field is optional, and an unrecognised
/// shape yields nothing rather than a wrong answer.
struct CmuxAgentRuntime: Equatable {
    struct Agent: Equatable {
        var pid: Int32
        /// cmux's own lifecycle label — "running", "idle", "needsInput",
        /// "unknown". Carried for diagnostics; the card does not trust it,
        /// because nothing on a working machine has ever been observed to set
        /// it to anything but "running" or "unknown".
        var lifecycle: String?
        var cwd: String?
    }

    /// Keyed by agent session id, which is what the card carries.
    private(set) var agentsBySession: [String: Agent] = [:]

    var isEmpty: Bool { agentsBySession.isEmpty }

    func agent(forSession id: String?) -> Agent? {
        guard let id, !id.isEmpty else { return nil }
        return agentsBySession[id]
    }

    /// Nil when the session has no runtime record at all — Codex and Cursor
    /// sessions, and any agent not launched inside cmux. Callers must treat
    /// nil as "unknown" and fall back to the timestamp rules, or those agents
    /// would all be judged dead.
    func isAlive(sessionId: String?, isRunning: (Agent) -> Bool = Self.isRunning) -> Bool? {
        guard let agent = agent(forSession: sessionId) else { return nil }
        return isRunning(agent)
    }

    /// A pid alone is not proof: pids are reused, and a recycled one would
    /// keep a dead session on the card for the full two-hour window. So the
    /// process must also still *be* the agent — checked by its executable
    /// path, which is the launcher cmux recorded ("…/bin/claude").
    static func isRunning(_ agent: Agent) -> Bool {
        guard agent.pid > 0 else { return false }
        // ESRCH is the definitive answer: no such process. EPERM means it
        // exists but belongs to someone else, which cannot happen for an agent
        // this user launched — treated as gone rather than guessed alive.
        guard kill(agent.pid, 0) == 0 else { return false }
        guard let path = executablePath(pid: agent.pid) else {
            // The process exists but will not say what it is. Keeping the row
            // is the smaller error: this only ever *extends* a session's life,
            // and the timestamp rules still retire it.
            return true
        }
        return path.lowercased().contains("claude")
    }

    static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    static let sessionFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cmuxterm/claude-hook-sessions.json")

    static func load(from url: URL = sessionFile) -> CmuxAgentRuntime {
        guard let data = try? Data(contentsOf: url) else { return CmuxAgentRuntime() }
        return parse(data)
    }

    static func parse(_ data: Data) -> CmuxAgentRuntime {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any]
        else { return CmuxAgentRuntime() }
        var runtime = CmuxAgentRuntime()
        for (key, value) in sessions {
            guard let record = value as? [String: Any] else { continue }
            // The dictionary key and the record's own id agree in practice;
            // the record wins, and the key is the fallback.
            let sessionId = (record["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? key
            guard !sessionId.isEmpty else { continue }
            // JSON numbers arrive as NSNumber whatever they were written as.
            guard let pid = (record["pid"] as? NSNumber)?.int32Value, pid > 0 else { continue }
            runtime.agentsBySession[sessionId] = Agent(
                pid: pid,
                lifecycle: record["agentLifecycle"] as? String,
                cwd: record["cwd"] as? String)
        }
        return runtime
    }
}
