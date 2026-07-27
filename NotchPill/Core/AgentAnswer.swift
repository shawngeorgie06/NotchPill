import Foundation

/// A quick-answer choice offered on a waiting peek: a label to tap and the
/// keystroke it sends.
///
/// This used to be a closed enum of Claude Code's permission prompt
/// (Yes/No/1/2/3), which meant NotchPill could only answer that one agent —
/// every other agent got buttons that sent the wrong keys. The set now travels
/// in the signal, so any agent can describe how it wants to be answered.
struct AgentAnswer: Equatable {
    var label: String
    var keystroke: String
    /// Whether Return is appended after the keystroke. True for raw y/n readline
    /// prompts; a TUI that self-confirms on keypress should declare `Yes:y!` to
    /// turn it off, since a stray Return there confirms whatever came next.
    var appendsReturn: Bool

    init(label: String, keystroke: String, appendsReturn: Bool = true) {
        self.label = label
        self.keystroke = keystroke
        self.appendsReturn = appendsReturn
    }

    /// Spoken/hover description. A bare "1" tells a VoiceOver user nothing about
    /// what the button does.
    var accessibilityLabel: String { "Answer \(label)" }

    static let yes = AgentAnswer(label: "Yes", keystroke: "y")
    static let no = AgentAnswer(label: "No", keystroke: "n")
    static func digit(_ n: Int) -> AgentAnswer {
        AgentAnswer(label: String(n), keystroke: String(n))
    }

    /// Claude Code's permission prompt. Still the default when a signal declares
    /// no set of its own, so hooks written before this stay unchanged.
    static let standardSet: [AgentAnswer] = [.yes, .no, .digit(1), .digit(2), .digit(3)]

    /// Parses an `answers` spec: items separated by `|`, each `Label:keystroke`,
    /// or a bare `Label` when the label *is* the keystroke (digits, mostly).
    /// A trailing `!` on the keystroke means "do not append Return".
    ///
    ///     Yes:y|No:n|1|2|3
    ///     Approve:a!|Deny:d!
    ///
    /// `|` and `:` are the separators because a label may contain spaces and
    /// commas ("Allow for session"). Returns nil for a spec that yields nothing,
    /// so callers can fall back rather than render an empty button row.
    static func parse(_ spec: String?) -> [AgentAnswer]? {
        guard let spec, !spec.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let parsed: [AgentAnswer] = spec.split(separator: "|").compactMap { rawItem in
            let item = rawItem.trimmingCharacters(in: .whitespaces)
            guard !item.isEmpty else { return nil }
            let label: String
            var keys: String
            if let colon = item.firstIndex(of: ":") {
                label = String(item[item.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
                keys = String(item[item.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            } else {
                label = item
                keys = item
            }
            var appendsReturn = true
            if keys.hasSuffix("!") {
                appendsReturn = false
                keys.removeLast()
            }
            guard !label.isEmpty, !keys.isEmpty else { return nil }
            return AgentAnswer(label: label, keystroke: keys, appendsReturn: appendsReturn)
        }
        return parsed.isEmpty ? nil : parsed
    }
}
