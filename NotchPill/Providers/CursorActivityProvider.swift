import Foundation
import SQLite3

/// Peeks for Cursor with no hooks installed, by reading the state Cursor keeps
/// in its own SQLite store.
///
/// Cursor is the odd one out: Claude Code and Codex append JSONL transcripts
/// that can simply be tailed, while Cursor writes to
/// `globalStorage/state.vscdb`. That database is ~550MB, so this never scans it
/// blindly — it stats the write-ahead log first and only queries when Cursor has
/// actually written something, then uses the indexed `lastUpdatedAt` column.
///
/// It also gets two things the JSONL watchers cannot:
///
/// - **A blocked-agent peek.** `composerHeaders.hasBlockingPendingActions` says
///   the conversation is waiting on you, so Cursor gets waiting peeks without a
///   hook — unlike Claude Code and Codex, whose pending prompts are not on disk.
/// - **A bundle id.** The agent runs *inside* Cursor, so tapping the peek can
///   focus it. For a terminal agent there is nothing on disk naming the window.
@MainActor
final class CursorActivityProvider {
    var onDevReady: ((DevReadyAlert) -> Void)?

    private let quietPeriod: TimeInterval = 2.5
    private let pollInterval: TimeInterval = 1.5
    private let cursorBundleId = "com.todesktop.230313mzl4w4u92"

    private struct Composer {
        var lastUpdatedAt: Int64
        var seenAt: Date
        var pinged: Bool
        var blocked: Bool
    }

    private var composers: [String: Composer] = [:]
    private var timer: Timer?
    private var primed = false
    private var lastWalStamp: Date?

    private var dbURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
    }

    func start() {
        guard timer == nil, FileManager.default.fileExists(atPath: dbURL.path) else { return }
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        composers.removeAll()
        primed = false
    }

    private func tick() {
        guard AppSettings.shared.showDevReadyPings,
              AppSettings.shared.watchAgentTranscripts else { return }

        // Cheap gate: only touch a half-gigabyte database when Cursor has
        // written to it since the last look.
        if let stamp = writeStamp() {
            if stamp == lastWalStamp, primed { expireQuiet(); return }
            lastWalStamp = stamp
        }

        for row in recentComposers() {
            let now = Date()
            guard var existing = composers[row.id] else {
                composers[row.id] = Composer(lastUpdatedAt: row.updatedAt, seenAt: now,
                                             pinged: true, blocked: row.blocked)
                continue
            }
            if row.updatedAt != existing.lastUpdatedAt || row.blocked != existing.blocked {
                existing.lastUpdatedAt = row.updatedAt
                existing.seenAt = now
                existing.pinged = false
                existing.blocked = row.blocked
                composers[row.id] = existing
            }
        }
        expireQuiet()
        primed = true
    }

    /// Fires for any conversation that has stopped changing.
    private func expireQuiet() {
        let now = Date()
        for (id, c) in composers where !c.pinged {
            guard now.timeIntervalSince(c.seenAt) >= quietPeriod else { continue }
            composers[id]?.pinged = true
            guard primed, let alert = pending[id] else { continue }
            onDevReady?(alert)
        }
        pending.removeAll()
    }

    private var pending: [String: DevReadyAlert] = [:]

    private struct Row {
        let id: String
        let updatedAt: Int64
        let blocked: Bool
    }

    private func writeStamp() -> Date? {
        let fm = FileManager.default
        let wal = dbURL.appendingPathExtension("wal")
        for url in [wal, dbURL] {
            if let d = try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                return d
            }
        }
        return nil
    }

    /// Reads conversations touched in the last few minutes. Read-only, and via a
    /// URI so SQLite never tries to create or recover Cursor's database.
    private func recentComposers() -> [Row] {
        var db: OpaquePointer?
        let uri = "file:\(dbURL.path)?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }

        let cutoff = Int64(Date().addingTimeInterval(-600).timeIntervalSince1970 * 1000)
        let sql = """
        SELECT composerId, workspaceId, lastUpdatedAt, value FROM composerHeaders
        WHERE lastUpdatedAt > ? AND isArchived = 0 AND isSubagent = 0
        ORDER BY lastUpdatedAt DESC LIMIT 20
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var rows: [Row] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let idC = sqlite3_column_text(stmt, 0) else { continue }
            let id = String(cString: idC)
            let workspace = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let updatedAt = sqlite3_column_int64(stmt, 2)
            let json = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "{}"
            let meta = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            let blocked = meta["hasBlockingPendingActions"] as? Bool ?? false
            rows.append(Row(id: id, updatedAt: updatedAt, blocked: blocked))
            pending[id] = alert(id: id, workspace: workspace, meta: meta, blocked: blocked)
        }
        return rows
    }

    private func alert(id: String, workspace: String?,
                       meta: [String: Any], blocked: Bool) -> DevReadyAlert {
        let project = workspace.flatMap(projectName) ?? "Cursor"
        let name = (meta["name"] as? String) ?? (meta["subtitle"] as? String)
        return DevReadyAlert(
            title: project,
            subtitle: blocked ? "waiting" : "finished",
            source: "Cursor",
            agent: "cursor",
            // The agent runs inside Cursor, so tapping the peek can focus it —
            // the one case where watching disk still knows where to send you.
            bundleId: cursorBundleId,
            kind: blocked ? .waiting : .finished,
            message: blocked ? (name ?? "Cursor is waiting on you") : nil,
            createdAt: Date().timeIntervalSince1970,
            sessionId: id,
            // Cursor is a GUI: keystrokes would land in whatever holds focus.
            deliverySpec: "none"
        )
    }

    /// `workspaceStorage/<id>/workspace.json` holds the folder this conversation
    /// belongs to.
    private func projectName(_ workspaceId: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage")
            .appendingPathComponent(workspaceId)
            .appendingPathComponent("workspace.json")
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let folder = obj["folder"] as? String,
              let decoded = URL(string: folder) else { return nil }
        let name = decoded.lastPathComponent
        return name.isEmpty ? nil : name
    }
}
