import Foundation

/// What an agent is actually asking permission to do.
///
/// The peek used to show the notification text — "Claude needs your permission
/// to use Edit" — which tells you the shape of the question and nothing about
/// the answer. The decision is in the payload: *which* file, *what* change,
/// *which* command. `PreToolUse` carries all of it; nothing was reading it.
///
/// Everything here is derived, pure and tested, because it renders on an
/// overlay above every window and gets approved with one keystroke.
struct PermissionRequest: Equatable {
    /// A compact, safe Markdown-derived line for the notch. Plans remain text
    /// (never HTML), but their hierarchy should survive the trip from the
    /// agent's proposal to a glanceable approval surface.
    struct PlanPreviewLine: Equatable, Identifiable {
        enum Style: Equatable { case heading, bullet, numbered, checkbox, body }
        var style: Style
        var text: String
        var id: String { "\(style)-\(text)" }
    }
    enum Action: Equatable {
        /// An edit to an existing file, with the change itself.
        case edit(path: String, diff: [DiffLine])
        /// A new file.
        case write(path: String, lines: Int)
        /// A shell command, and the agent's own description of it if given.
        case run(command: String, note: String?)
        /// Claude's ExitPlanMode handoff, rendered as a compact Markdown preview.
        case plan(markdown: String)
        /// Anything else — named, but with no structured body to show.
        case other(tool: String, detail: String?)
    }

    var action: Action
    /// The tool name exactly as the agent reported it, for the badge.
    var tool: String

    /// One line of the change, as it should be drawn.
    struct DiffLine: Equatable {
        enum Kind: Equatable { case context, added, removed }
        var kind: Kind
        var text: String
    }

    /// Headline for the peek: short, and specific enough to decide on.
    var summary: String {
        switch action {
        case .edit(let path, _): return "Edit \(Self.shorten(path))"
        case .write(let path, _): return "Create \(Self.shorten(path))"
        case .run(let command, _): return command
        case .plan: return "Review plan"
        case .other(let tool, let detail): return detail.map { "\(tool): \($0)" } ?? tool
        }
    }

    /// `+3 −1`, the shape every code host uses. Nil when there is no diff.
    var changeCount: String? {
        guard case .edit(_, let diff) = action else { return nil }
        let added = diff.filter { $0.kind == .added }.count
        let removed = diff.filter { $0.kind == .removed }.count
        guard added + removed > 0 else { return nil }
        return "+\(added) −\(removed)"
    }

    /// Whether the summary is machine text (a command) rather than prose, so
    /// the row can set it in a monospaced face and truncate from the end.
    var isCommand: Bool {
        if case .run = action { return true }
        return false
    }

    var isPlan: Bool {
        if case .plan = action { return true }
        return false
    }

    /// The command preview gets a few wrapped lines in the notch. Commands are
    /// often one long shell statement, so a one-line preview hid the useful
    /// half (for example the `printf …` after `Bash`). The cap keeps an
    /// unbounded pasted script from turning an approval into a full-screen UI.
    var commandPreviewLineLimit: Int { isCommand ? 3 : 1 }

    /// Markdown is intentionally rendered as text, not HTML: the plan came
    /// from an agent and the notch needs a safe, glanceable review surface.
    var planPreview: [PlanPreviewLine] {
        guard case .plan(let markdown) = action else { return [] }
        return Array(markdown.components(separatedBy: .newlines)
            .compactMap(Self.planPreviewLine)
            .prefix(4))
    }

    /// Backward-compatible text-only view used by non-visual callers/tests.
    var planPreviewLines: [String] {
        planPreview.map(\.text)
    }

    private static func planPreviewLine(_ raw: String) -> PlanPreviewLine? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        line = line.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        if raw.trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            return PlanPreviewLine(style: .heading, text: line)
        }
        if line.hasPrefix("- [ ] ") || line.hasPrefix("* [ ] ") {
            return PlanPreviewLine(style: .checkbox, text: "☐ " + String(line.dropFirst(6)))
        }
        if line.hasPrefix("- [x] ") || line.hasPrefix("- [X] ") || line.hasPrefix("* [x] ") || line.hasPrefix("* [X] ") {
            return PlanPreviewLine(style: .checkbox, text: "☑ " + String(line.dropFirst(6)))
        }
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return PlanPreviewLine(style: .bullet, text: "• " + String(line.dropFirst(2)))
        }
        if line.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
            return PlanPreviewLine(style: .numbered, text: line)
        }
        return PlanPreviewLine(style: .body, text: line)
    }

    /// How many diff lines the peek has room for. The peek does not scroll, and
    /// past four lines it is taller than the notch it hangs from.
    static let previewLimit = 4

    /// The lines to draw, capped.
    ///
    /// Context lines are dropped before changed ones. Context is what makes a
    /// small diff readable, but when there is more change than fits, spending a
    /// line on something that did *not* change is the wrong trade — the count
    /// still says how much changed in total, so the cap reads as a cap.
    var previewLines: [DiffLine] {
        guard case .edit(_, let diff) = action else { return [] }
        guard diff.count > Self.previewLimit else { return diff }
        let changed = diff.filter { $0.kind != .context }
        return Array((changed.count >= Self.previewLimit ? changed : diff)
            .prefix(Self.previewLimit))
    }

    /// Trailing path components only. A peek is ~380pt wide and the leading
    /// directories are the least distinguishing part of a path.
    static func shorten(_ path: String, components: Int = 2) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > components else {
            return parts.joined(separator: "/")
        }
        return parts.suffix(components).joined(separator: "/")
    }

    /// Builds the change from an `Edit` payload's before/after strings.
    ///
    /// Deliberately not a real diff algorithm. The payload is one contiguous
    /// replacement, so the honest rendering is "these lines went, those came" —
    /// and a Myers diff over a hunk this small would spend its cleverness
    /// producing the same answer. Common leading and trailing lines are shown
    /// as context, which is what makes the change readable rather than a wall.
    static func diff(old: String, new: String, contextLimit: Int = 2) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var prefix = 0
        while prefix < oldLines.count, prefix < newLines.count,
              oldLines[prefix] == newLines[prefix] { prefix += 1 }

        var suffix = 0
        while suffix < oldLines.count - prefix, suffix < newLines.count - prefix,
              oldLines[oldLines.count - 1 - suffix] == newLines[newLines.count - 1 - suffix] {
            suffix += 1
        }

        var out: [DiffLine] = []
        for line in oldLines.prefix(prefix).suffix(contextLimit) {
            out.append(DiffLine(kind: .context, text: line))
        }
        for line in oldLines[prefix..<(oldLines.count - suffix)] {
            out.append(DiffLine(kind: .removed, text: line))
        }
        for line in newLines[prefix..<(newLines.count - suffix)] {
            out.append(DiffLine(kind: .added, text: line))
        }
        for line in oldLines.suffix(suffix).prefix(contextLimit) {
            out.append(DiffLine(kind: .context, text: line))
        }
        return out
    }

    /// Reads a `PreToolUse` payload: the tool's name and its input object.
    ///
    /// Unknown tools are not dropped. An agent asking for something we cannot
    /// render still deserves a peek that names it — silently showing nothing
    /// is how someone ends up waiting on a prompt they never saw.
    static func parse(tool: String, input: [String: Any]) -> PermissionRequest? {
        let trimmed = tool.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let path = (input["file_path"] as? String) ?? (input["path"] as? String)

        switch trimmed.lowercased() {
        case "edit", "multiedit", "str_replace_editor":
            guard let path else { break }
            let old = (input["old_string"] as? String) ?? ""
            let new = (input["new_string"] as? String) ?? ""
            return PermissionRequest(action: .edit(path: path, diff: diff(old: old, new: new)),
                                     tool: trimmed)
        case "write", "create":
            guard let path else { break }
            let body = (input["content"] as? String) ?? ""
            let count = body.isEmpty ? 0 : body.components(separatedBy: "\n").count
            return PermissionRequest(action: .write(path: path, lines: count), tool: trimmed)
        case "bash", "shell", "run", "execute":
            guard let command = (input["command"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty else { break }
            let note = (input["description"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return PermissionRequest(action: .run(command: command,
                                                  note: note?.isEmpty == true ? nil : note),
                                     tool: trimmed)
        case "exitplanmode":
            let plan = ((input["plan"] as? String) ?? (input["content"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !plan.isEmpty else { break }
            return PermissionRequest(action: .plan(markdown: plan), tool: trimmed)
        default:
            break
        }

        // Best-effort detail for anything unrecognised: a path if there is one,
        // else whatever short string the payload leads with.
        let detail = path.map { shorten($0) } ?? input.values.compactMap { $0 as? String }
            .first { $0.count < 120 }
        return PermissionRequest(action: .other(tool: trimmed, detail: detail), tool: trimmed)
    }

    /// Same, straight from the hook's JSON.
    static func parse(payload: Data) -> PermissionRequest? {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let tool = root["tool_name"] as? String else { return nil }
        let input = (root["tool_input"] as? [String: Any]) ?? [:]
        return parse(tool: tool, input: input)
    }

    /// Redacted copy, for anything that reaches the screen. A command line is
    /// the single most likely place for a credential to appear.
    var redacted: PermissionRequest {
        var copy = self
        switch action {
        case .edit(let path, let diff):
            copy.action = .edit(path: path, diff: diff.map {
                DiffLine(kind: $0.kind, text: SecretRedactor.redact($0.text))
            })
        case .write, .other:
            break
        case .run(let command, let note):
            copy.action = .run(command: SecretRedactor.redact(command),
                               note: note.map(SecretRedactor.redact))
        case .plan(let markdown):
            copy.action = .plan(markdown: SecretRedactor.redact(markdown))
        }
        return copy
    }
}
