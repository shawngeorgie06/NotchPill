import Foundation

/// One line in the in-app log.
struct LogEntry: Identifiable, Equatable, Sendable {
    enum Level: String, Sendable, CaseIterable {
        case info, warn, error

        /// Leading glyph, so a wall of lines can be skimmed for the bad ones.
        var symbol: String {
            switch self {
            case .info: return "·"
            case .warn: return "!"
            case .error: return "×"
            }
        }
    }

    let id: UInt64
    let date: Date
    let level: Level
    let category: String
    let message: String

    /// Fixed-width-ish so columns line up in a monospaced view and in the
    /// exported report.
    func line(formatter: DateFormatter) -> String {
        "\(formatter.string(from: date)) \(level.symbol) [\(category)] \(message)"
    }
}

/// The log the app keeps about itself.
///
/// Deliberately in memory, not a file. The env-var logs this replaces
/// (`NOTCHPILL_LOG_PEEKS` and friends) wrote project names and the text of
/// whatever an agent asked into `~/.notchpill/*.log` on every machine that
/// turned them on — fine for one person chasing one bug, wrong as a default.
/// Nothing here is written to disk until you explicitly export a report, and
/// what goes in is limited to facts about the app's own behaviour: counts,
/// identifiers, states and errors, never prompt or task text.
///
/// The cost is that a restart loses the history, which is the right trade for
/// something whose job is "reproduce it, then look".
@MainActor
final class LogStore: ObservableObject {
    static let shared = LogStore()

    /// Roughly an hour of ordinary activity, and small enough that the whole
    /// buffer can be pasted into an issue.
    nonisolated static let capacity = 600

    @Published private(set) var entries: [LogEntry] = []
    private var nextID: UInt64 = 0

    /// Drops the oldest entries once the buffer is over capacity. Pure, so the
    /// one piece of arithmetic here is tested rather than assumed.
    nonisolated static func trim(_ entries: [LogEntry], to capacity: Int) -> [LogEntry] {
        guard capacity > 0 else { return [] }
        guard entries.count > capacity else { return entries }
        return Array(entries.suffix(capacity))
    }

    func record(_ category: String, _ message: String,
                level: LogEntry.Level = .info, date: Date = Date()) {
        let entry = LogEntry(id: nextID, date: date, level: level,
                             category: category, message: message)
        nextID &+= 1
        entries = Self.trim(entries + [entry], to: Self.capacity)
        // The window is for users; this is for whoever is driving the app from
        // a terminal and wants the same lines where `grep` can reach them.
        // stderr, not stdout: unbuffered, so a line is readable the moment it
        // happens rather than whenever a 4KB block fills. Chasing a timing bug
        // through a buffer is how you conclude the wrong thing.
        let line = entry.line(formatter: Self.lineFormatter)
        if Self.mirrorsToStdout {
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        // Opt-in, and off the main thread: this is the notch's own actor, and a
        // slow disk must never be able to stutter an animation. Serial, so
        // lines land in the order they happened.
        if AppSettings.shared.persistLog {
            Self.fileQueue.async { LogFile.append(line) }
        }
    }

    private static let fileQueue = DispatchQueue(label: "com.local.notchpill.logfile",
                                                 qos: .utility)

    func clear() {
        entries.removeAll()
    }

    /// Safe to call from any thread — providers do their work off the main
    /// actor and should not have to think about where the log lives.
    nonisolated static func log(_ category: String, _ message: String,
                                level: LogEntry.Level = .info) {
        let now = Date()
        Task { @MainActor in
            LogStore.shared.record(category, message, level: level, date: now)
        }
    }

    var formatted: String {
        let f = Self.lineFormatter
        return entries.map { $0.line(formatter: f) }.joined(separator: "\n")
    }

    nonisolated static let mirrorsToStdout =
        ProcessInfo.processInfo.environment["NOTCHPILL_LOG_STDOUT"] == "1"

    nonisolated static let lineFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}
