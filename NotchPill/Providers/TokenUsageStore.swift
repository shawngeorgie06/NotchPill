import Foundation
import Combine

/// Tokens used per tool and model, over a period the user picks.
struct TokenUsageSummary: Equatable {
    /// Tool → model → tally, already filtered to the chosen period.
    var byTool: [String: [String: TokenTally]] = [:]

    /// Day (`yyyy-MM-dd`) → tool → full-price tokens, for the history card.
    /// Independent of the period: a history is the days before it.
    var daily: [String: [String: Int]] = [:]

    /// Full-price tokens: fresh prompt, generation, and cache writes.
    func total(for tool: String) -> Int {
        (byTool[tool] ?? [:]).values.reduce(0) { $0 + $1.total }
    }

    /// Cached context re-sent each turn. Real, but billed at a fraction, so it
    /// is reported beside the total rather than inside it.
    func cached(for tool: String) -> Int {
        (byTool[tool] ?? [:]).values.reduce(0) { $0 + $1.cacheRead }
    }

    /// Models for a tool, largest first — the order a reader wants them in.
    func models(for tool: String) -> [(model: String, tokens: Int)] {
        (byTool[tool] ?? [:])
            .map { (model: $0.key, tokens: $0.value.total) }
            .sorted { $0.tokens > $1.tokens }
    }

    var isEmpty: Bool { byTool.values.allSatisfy { $0.isEmpty } }

    /// Model lines a quota card will draw: at most two, and none at all when
    /// the tool did no work in the period.
    ///
    /// The height budget and the view both read this, so a card cannot render
    /// more rows than it reserved and push the page dots off the pill.
    static let maxModelRows = 2

    func modelRows(for tool: String) -> Int {
        guard total(for: tool) > 0 || cached(for: tool) > 0 else { return 0 }
        return min(Self.maxModelRows, (byTool[tool] ?? [:]).count)
    }

    /// The tallest card's worth, for sizing a deck that may show either.
    var widestModelRows: Int {
        max(modelRows(for: Self.claude), modelRows(for: Self.codex))
    }

    static let claude = "Claude Code"
    static let codex = "Codex"
}

/// How far back the figures reach.
enum TokenUsagePeriod: String, CaseIterable {
    case session, today, week, all

    var label: String {
        switch self {
        case .session: return "Since NotchPill opened"
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .all: return "All time"
        }
    }

    /// Short enough to sit beside a number on a notch-sized card.
    var shortLabel: String {
        switch self {
        case .session: return "since launch"
        case .today: return "today"
        case .week: return "7d"
        case .all: return "all time"
        }
    }

    /// Nil means no cutoff at all.
    func cutoff(now: Date = Date(), launchedAt: Date) -> Date? {
        switch self {
        case .session: return launchedAt
        case .today: return Calendar.current.startOfDay(for: now)
        case .week: return Calendar.current.date(byAdding: .day, value: -6,
                                                 to: Calendar.current.startOfDay(for: now))
        case .all: return nil
        }
    }
}

/// Scans agent transcripts for token usage and keeps the answer current.
///
/// There is close to a gigabyte of transcripts on a working machine, so
/// unchanged files are skipped. Each file's timestamped usage is cached
/// against the size it was computed at; a file that has grown is
/// read from that offset on, because JSONL is append-only.
@MainActor
final class TokenUsageStore: ObservableObject {
    static let shared = TokenUsageStore()

    @Published private(set) var summary = TokenUsageSummary()

    private let launchedAt = Date()
    private var cache: [String: FileState] = [:]
    private var period: TokenUsagePeriod?
    private var isScanning = false
    private var lastScan = Date.distantPast

    /// The transcript is local and append-only, so a short incremental scan is
    /// cheap once a file is known. This keeps the token line current while the
    /// notch is open instead of waiting for the next open gesture.
    private static let minInterval: TimeInterval = 30

    struct FileState: Codable {
        var size: Int
        var buckets: TokenLedger.Timeline
        /// Codex reports running totals, so each read continues from where
        /// the last one left the total.
        var isCumulative: Bool
        var codex: TokenLedger.CodexProgress?
        var claudeMessageIDs: Set<String>?
    }

    private static var cacheURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notchpill")
        // v4 keeps exact timestamps and rebuilds the corrected provider totals.
        return dir.appendingPathComponent("token-cache-v4.json")
    }

    init() { loadCache() }

    func refresh(period: TokenUsagePeriod, force: Bool = false) {
        if self.period != period {
            self.period = period
            recompute(period: period)
        }
        let now = Date()
        guard !isScanning, force || now.timeIntervalSince(lastScan) >= Self.minInterval else { return }
        isScanning = true
        lastScan = now
        let known = cache
        Task.detached(priority: .utility) {
            let scanned = Self.scan(known: known)
            await MainActor.run {
                self.cache = scanned
                self.isScanning = false
                self.saveCache()
                self.recompute(period: self.period ?? period)
            }
        }
    }

    private func recompute(period: TokenUsagePeriod) {
        let fresh = Self.summarize(cache.values, period: period, launchedAt: launchedAt)
        if fresh != summary { summary = fresh }
    }

    static func summarize(_ files: some Sequence<FileState>, period: TokenUsagePeriod,
                          launchedAt: Date, now: Date = Date()) -> TokenUsageSummary {
        let cutoff = period.cutoff(now: now, launchedAt: launchedAt) ?? .distantPast
        let historyStart = UsageHistory.firstDay(now: now)
        var result = TokenUsageSummary()
        var historyDays: [Date: String] = [:]
        let calendar = Calendar.current
        for state in files {
            let tool = state.isCumulative ? TokenUsageSummary.codex : TokenUsageSummary.claude
            for (timestamp, models) in state.buckets where timestamp <= now {
                if timestamp >= cutoff {
                    for (model, tally) in models {
                        result.byTool[tool, default: [:]][model, default: TokenTally()] =
                            (result.byTool[tool]?[model] ?? TokenTally()) + tally
                    }
                }
                if timestamp >= historyStart {
                    let dayStart = calendar.startOfDay(for: timestamp)
                    let day = historyDays[dayStart] ?? TokenLedger.day(from: dayStart)
                    historyDays[dayStart] = day
                    let tokens = models.values.reduce(0) { $0 + $1.total }
                    if tokens > 0 { result.daily[day, default: [:]][tool, default: 0] += tokens }
                }
            }
        }
        return result
    }

    // MARK: - Scanning

    nonisolated private static func scan(known: [String: FileState]) -> [String: FileState] {
        var out = known
        let home = NSHomeDirectory()
        let claude = transcripts(under: "\(home)/.claude/projects")
        let codex = transcripts(under: "\(home)/.codex/sessions")

        for url in claude {
            let path = url.path
            let size = fileSize(url)
            if let cached = out[path], cached.size == size, !cached.isCumulative { continue }
            let previous = out[path]
            // Append-only, so only the new bytes need parsing.
            let resumable = previous?.claudeMessageIDs != nil && (previous?.size ?? 0) <= size
            let offset = resumable ? previous?.size ?? 0 : 0
            if !resumable { out[path] = nil }
            guard let (text, consumed) = read(url, from: offset) else { continue }
            var seen = resumable ? previous?.claudeMessageIDs ?? [] : []
            let fresh = TokenLedger.claudeBuckets(in: text, seen: &seen, bucket: { $0 })
            let base = resumable ? previous?.buckets ?? [:] : [:]
            out[path] = FileState(size: offset + consumed,
                                  buckets: TokenLedger.merge(base, fresh),
                                  isCumulative: false, claudeMessageIDs: seen)
        }

        for url in codex {
            let path = url.path
            let size = fileSize(url)
            if let cached = out[path], cached.size == size, cached.codex != nil { continue }
            let previous = out[path]
            // Append-only like Claude's, so only the new bytes need parsing. A
            // file that shrank was replaced, and is read again from the top.
            let resumable = previous?.codex != nil && (previous?.size ?? 0) <= size
            let offset = resumable ? previous?.size ?? 0 : 0
            if !resumable { out[path] = nil }
            guard let (text, consumed) = read(url, from: offset) else { continue }
            let (fresh, progress) = TokenLedger.codexBuckets(
                in: text, continuing: resumable ? previous?.codex ?? .init() : .init(), bucket: { $0 })
            var base = resumable ? previous?.buckets ?? [:] : [:]
            // Work read before the model was named went under the fallback
            // label. Name it now, so the answer does not depend on where
            // one read happened to stop.
            if previous?.codex?.model == nil, let model = progress.model {
                base = TokenLedger.relabel(base, from: "codex", to: model)
            }
            out[path] = FileState(size: offset + consumed,
                                  buckets: TokenLedger.merge(base, fresh),
                                  isCumulative: true,
                                  codex: progress)
        }

        // Forget files that are gone, so a cleared history stops being counted.
        let live = Set(claude.map(\.path)).union(codex.map(\.path))
        out = out.filter { live.contains($0.key) }
        return out
    }

    nonisolated private static func transcripts(under root: String) -> [URL] {
        let base = URL(fileURLWithPath: root)
        guard let walker = FileManager.default.enumerator(
            at: base, includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            out.append(url)
        }
        return out
    }

    nonisolated private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    /// Reads from `offset` to the last complete line, returning how many bytes
    /// were actually consumed so a half-written record is read again next time.
    nonisolated private static func read(_ url: URL, from offset: Int) -> (String, Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        return (String(decoding: complete, as: UTF8.self), complete.count)
    }

    // MARK: - Cache persistence

    private func loadCache() {
        // The superseded cache is never read again; leave nothing stale behind.
        try? FileManager.default.removeItem(
            at: Self.cacheURL.deletingLastPathComponent().appendingPathComponent("token-cache-v2.json"))
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([String: FileState].self, from: data)
        else { return }
        cache = decoded
    }

    private func saveCache() {
        let url = Self.cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
