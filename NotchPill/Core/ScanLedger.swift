import Foundation

/// Reconciles what a scan found on disk against what reached the card.
///
/// The existing log records what the app *did*: a peek arrived, a poll ran, a
/// jump was attempted. Every bug worth chasing in this app so far has been the
/// opposite — the app quietly deciding *not* to do something, and saying
/// nothing. A pill drawn in the wrong place because the notch measurement
/// silently fell back to a guess; a tap that did nothing because the target was
/// resolved to an app that was not running; four phantom agent rows because
/// every transcript on disk counted as a session. In all three the log was
/// working perfectly and had nothing to say, because nothing failed. Something
/// was *excluded*, and exclusions were invisible.
///
/// A ledger closes that gap by recording the arithmetic rather than the events:
/// how many candidates a scan considered, how many survived, and — the part
/// that actually ends an investigation — the tally of reasons the rest did not.
/// "6 transcripts → 2 shown (4 dropped: sdk-run 4)" is the line that turns
/// "why is this agent on my card" from a code-reading exercise into a glance.
///
/// Pure and value-typed so the arithmetic is tested rather than assumed, and so
/// the scanner can build one off the main actor without touching the store.
struct ScanLedger: Equatable {
    /// What was scanned — "transcripts", "cursor rows".
    let unit: String
    private(set) var considered = 0
    private(set) var kept = 0
    /// Drop reasons and their counts. A dictionary rather than a list: the
    /// interesting quantity is "how many for each reason", and a busy scan
    /// would otherwise produce a line too long to read.
    private(set) var drops: [String: Int] = [:]

    init(unit: String) { self.unit = unit }

    mutating func keep() {
        considered += 1
        kept += 1
    }

    /// `reason` must be a fixed, low-cardinality label — never a file path, a
    /// project name, or anything an agent wrote. It is a tally key, and it also
    /// keeps the privacy promise the log is built on.
    mutating func drop(_ reason: String) {
        considered += 1
        drops[reason, default: 0] += 1
    }

    var dropped: Int { considered - kept }

    /// One line, stable enough to compare against the previous scan.
    ///
    /// Reasons are sorted by count then name so the same scan always renders
    /// the same string — otherwise dictionary ordering alone would make every
    /// scan look like a change and defeat `hasChanged`.
    var summary: String {
        var line = "\(considered) \(unit) → \(kept) shown"
        guard !drops.isEmpty else { return line }
        let detail = drops
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }
            .joined(separator: ", ")
        line += " (\(dropped) dropped: \(detail))"
        return line
    }

    /// Whether this scan is worth a log line at all.
    ///
    /// The scan runs every three seconds. Logging each one would fill the
    /// 600-line buffer in half an hour with a single repeated sentence and bury
    /// the peeks, jumps and errors the log exists for — a "better" log that is
    /// strictly worse to read. So a ledger is only news when its arithmetic
    /// differs from the last one.
    func differs(from previous: ScanLedger?) -> Bool {
        guard let previous else { return considered > 0 }
        return summary != previous.summary
    }
}
