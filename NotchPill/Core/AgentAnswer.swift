/// A quick-answer choice sent to a waiting agent. Pure mapping to a keystroke.
enum AgentAnswer: Equatable {
    case yes, no, digit(Int)

    var keystroke: String {
        switch self {
        case .yes: return "y"
        case .no: return "n"
        case .digit(let n): return String(n)
        }
    }
    var label: String {
        switch self {
        case .yes: return "Yes"
        case .no: return "No"
        case .digit(let n): return String(n)
        }
    }
    /// Spoken/hover description. A bare "1" tells a VoiceOver user nothing about
    /// what the button does.
    var accessibilityLabel: String {
        switch self {
        case .yes: return "Answer Yes"
        case .no: return "Answer No"
        case .digit(let n): return "Answer \(n)"
        }
    }
    /// Whether Return is appended after the keystroke. Set per Task 1 spike
    /// (default true — raw y/n readline prompts need it; adjust if the target
    /// TUI self-confirms on keypress).
    var appendsReturn: Bool { true }

    static let standardSet: [AgentAnswer] = [.yes, .no, .digit(1), .digit(2), .digit(3)]
}
