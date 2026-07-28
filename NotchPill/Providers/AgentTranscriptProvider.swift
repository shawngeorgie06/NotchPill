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
            if primed, let alert = alert(for: url) {
                onDevReady?(alert)
            }
        }
        // One full pass to learn the world before anything is allowed to fire.
        primed = true
    }

    private func transcripts() -> [URL] {
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
        return found
    }

    private func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
    }

    /// Builds a peek matching what the hooks emit, so the two dedup against
    /// each other rather than double-peeking.
    private func alert(for url: URL) -> DevReadyAlert? {
        let isCodex = url.path.contains("/.codex/")
        let sessionId = url.deletingPathExtension().lastPathComponent
        guard let project = projectName(for: url, isCodex: isCodex) else { return nil }
        let branch = gitBranch(for: url, isCodex: isCodex)
        return DevReadyAlert(
            title: project,
            subtitle: "finished" + (branch.map { " · \($0)" } ?? ""),
            source: isCodex ? "Codex" : "Claude Code",
            agent: isCodex ? "codex" : "claude-code",
            // Deliberately no bundleId: nothing here says which terminal the
            // session runs in, and guessing would focus the wrong window.
            bundleId: nil,
            kind: .finished,
            createdAt: Date().timeIntervalSince1970,
            sessionId: sessionId
        )
    }

    /// Claude Code encodes the working directory in the *directory* name with
    /// slashes turned into dashes (`-Users-me-Projects-NotchPill`). Codex keeps
    /// the cwd inside the transcript instead.
    private func projectName(for url: URL, isCodex: Bool) -> String? {
        if !isCodex {
            let dir = url.deletingLastPathComponent().lastPathComponent
            guard let last = dir.split(separator: "-").last, !last.isEmpty else { return nil }
            return String(last)
        }
        guard let cwd = firstValue(in: url, key: "cwd") else { return nil }
        return URL(fileURLWithPath: cwd).lastPathComponent
    }

    private func gitBranch(for url: URL, isCodex: Bool) -> String? {
        let cwd: String?
        if isCodex {
            cwd = firstValue(in: url, key: "cwd")
        } else {
            let dir = url.deletingLastPathComponent().lastPathComponent
            cwd = dir.hasPrefix("-") ? dir.replacingOccurrences(of: "-", with: "/") : nil
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
        }
        return nil
    }
}
