import Foundation

/// Removes credential-shaped strings from anything the notch is about to show.
///
/// The card and the peeks render text taken straight from agent transcripts —
/// the prompt you are working on, the command an agent asked permission to run.
/// That text is whatever you typed, and people paste tokens to their agents:
/// a GitHub PAT pasted into a session was rendered on screen as the task line,
/// on an overlay that sits above every window and gets screen-shared and
/// screenshotted.
///
/// So this runs on the display path, not the storage path. The transcript on
/// disk is not ours to rewrite; what we put on someone's screen is.
enum SecretRedactor {
    /// Deliberately specific. A greedy "anything long and random" rule would
    /// eat commit SHAs, session ids and file hashes — all of which are useful
    /// on the card — and the noise would make the redaction worth ignoring.
    private static let patterns: [String] = [
        // GitHub: ghp_ (classic PAT), gho_, ghu_, ghs_, ghr_, and fine-grained.
        "gh[pousr]_[A-Za-z0-9]{16,}",
        "github_pat_[A-Za-z0-9_]{20,}",
        // Anthropic, OpenAI and friends.
        "sk-ant-[A-Za-z0-9\\-_]{16,}",
        "sk-[A-Za-z0-9]{32,}",
        // AWS access key ids, and Slack's whole family.
        "AKIA[0-9A-Z]{16}",
        "xox[abposr]-[A-Za-z0-9\\-]{10,}",
        // Google API keys.
        "AIza[0-9A-Za-z\\-_]{35}",
        // Anything handed over as a bearer token or basic auth.
        "(?i)bearer\\s+[A-Za-z0-9\\-._~+/]{20,}={0,2}",
        // A token embedded in a URL: https://user:secret@host
        "(?i)https?://[^\\s/@]+:[^\\s/@]+@",
    ]

    private static let expressions: [NSRegularExpression] = patterns.compactMap {
        try? NSRegularExpression(pattern: $0)
    }

    static let placeholder = "[redacted]"

    /// Replaces every credential-shaped run with `[redacted]`.
    static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var out = text
        for expression in expressions {
            out = expression.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: placeholder)
        }
        return out
    }

    /// True when redaction changed anything — for tests and for deciding
    /// whether a line is worth logging at all.
    static func containsSecret(_ text: String) -> Bool {
        redact(text) != text
    }
}
