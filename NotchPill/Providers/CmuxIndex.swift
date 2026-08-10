import Foundation

/// What cmux knows about the agents running inside it.
///
/// The live-agents card could say almost nothing useful about a Claude Code
/// session: the transcript names a *project* and the agent kind, so every row
/// read "Claude" plus a folder, and three sessions in one repo were three
/// identical rows. Tapping one was a guess too — cmux was matched by working
/// directory, so two agents in the same repo were ambiguous and the tap
/// declined rather than pick wrong.
///
/// cmux already has both answers and writes them to disk. Its session file
/// records, per terminal panel, the title it auto-generated for the work
/// ("Improve NJIT room finder usability"), the panel's stable id, and the id of
/// the Claude session running in it. That is a name worth showing and an exact
/// target to focus.
///
/// Read-only, and tolerant: this is another app's private state file. Every
/// field is optional, a shape we do not recognise yields nothing, and nothing
/// here is ever written back.
struct CmuxIndex: Equatable {
    struct Pane: Equatable {
        /// Stable panel id — what `terminal`'s AppleScript `id` matches on.
        var panelId: String
        /// cmux's own name for the work, absent until it has named it.
        var title: String?
        var directory: String?
        var ttyName: String?
    }

    /// Keyed by the agent's session id, which is what the card carries.
    private(set) var panesBySession: [String: Pane] = [:]

    var isEmpty: Bool { panesBySession.isEmpty }

    func pane(forSession id: String?) -> Pane? {
        guard let id, !id.isEmpty else { return nil }
        return panesBySession[id]
    }

    /// cmux prefixes a title with a status glyph — "✳ Improve NJIT room finder
    /// usability", "⠐ finish-approvals-toggle". The glyph is a spinner frame
    /// that changes as the agent works, so keeping it would make the row's name
    /// flicker; the words are the part that identifies the session.
    static func cleanTitle(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw.drop { character in
            character.unicodeScalars.allSatisfy { scalar in
                !CharacterSet.alphanumerics.contains(scalar)
            }
        }
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static let sessionFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/cmux/session-com.cmuxterm.app.json")

    static func load(from url: URL = sessionFile) -> CmuxIndex {
        guard let data = try? Data(contentsOf: url) else { return CmuxIndex() }
        return parse(data)
    }

    static func parse(_ data: Data) -> CmuxIndex {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return CmuxIndex()
        }
        var index = CmuxIndex()
        let windows = root["windows"] as? [[String: Any]] ?? []
        for window in windows {
            let manager = window["tabManager"] as? [String: Any] ?? [:]
            let workspaces = manager["workspaces"] as? [[String: Any]] ?? []
            for workspace in workspaces {
                for panel in workspace["panels"] as? [[String: Any]] ?? [] {
                    guard let panelId = panel["id"] as? String, !panelId.isEmpty else { continue }
                    let terminal = panel["terminal"] as? [String: Any] ?? [:]
                    let agent = terminal["agent"] as? [String: Any] ?? [:]
                    guard let sessionId = agent["sessionId"] as? String, !sessionId.isEmpty
                    else { continue }
                    index.panesBySession[sessionId] = Pane(
                        panelId: panelId,
                        // Title and tty sit on the panel, not on its terminal.
                        title: cleanTitle(panel["title"] as? String),
                        directory: panel["directory"] as? String,
                        ttyName: panel["ttyName"] as? String)
                }
            }
        }
        return index
    }
}
