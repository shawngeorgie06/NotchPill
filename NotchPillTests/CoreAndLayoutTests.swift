import Testing
import Foundation
import Combine
import CoreAudio
import AppKit
import SwiftUI
@testable import NotchPill

// MARK: - Process capture (artwork deadlock regression)

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("captures output larger than the pipe buffer without deadlocking")
    func largeOutput() {
        // ~200 KB, far exceeding the ~64 KB pipe buffer. The old pattern
        // (waitUntilExit before draining) would hang here — the exact bug that
        // froze the now-playing stream on artwork fetch.
        let byteCount = 200_000
        let data = ProcessRunner.capture("/bin/sh", ["-c", "head -c \(byteCount) /dev/zero | base64"])
        #expect(data != nil)
        // base64 of 200 KB is ~270 KB; just assert we got well past the buffer.
        #expect((data?.count ?? 0) > 100_000)
    }

    @Test("returns nil on non-zero exit")
    func failureExit() {
        #expect(ProcessRunner.capture("/bin/sh", ["-c", "exit 3"]) == nil)
    }
}

// MARK: - Shelf filing

@Suite("Token ledger")
struct TokenLedgerTests {
    @Test("Claude usage sums per model and per day")
    func claudeSums() {
        let text = """
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":100,"output_tokens":20}}}
        {"timestamp":"2026-08-24T11:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":50,"output_tokens":5}}}
        {"timestamp":"2026-08-23T10:00:00.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":7,"output_tokens":3}}}
        """
        let buckets = TokenLedger.claudeBuckets(in: text)
        #expect(buckets["2026-08-24"]?["claude-opus-5"]?.total == 175)
        #expect(buckets["2026-08-23"]?["claude-sonnet-5"]?.total == 10)
    }

    /// Cache writes are fresh tokens at full price and belong in the total.
    /// Cache reads are re-sent every turn and billed at a fraction, so they are
    /// carried beside it. Counting only input and output reported generation
    /// and called it usage — a day of real work came out as 120K.
    @Test("cache writes count, cache reads are carried separately")
    func cacheIsSplitNotDropped() {
        let text = """
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":10,"output_tokens":2,"cache_read_input_tokens":900000,"cache_creation_input_tokens":5000}}}
        """
        let tally = TokenLedger.claudeBuckets(in: text)["2026-08-24"]?["claude-opus-5"]
        #expect(tally?.total == 5012)
        #expect(tally?.cacheRead == 900_000)
    }

    /// The shape that broke the number: a fully cached turn reports almost no
    /// `input`, so anything ignoring cache writes reads as output alone.
    @Test("a cached turn still reports what it cost")
    func cachedTurnIsNotInvisible() {
        let text = """
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":2,"output_tokens":1200,"cache_creation_input_tokens":113900,"cache_read_input_tokens":42100000}}}
        """
        let tally = TokenLedger.claudeBuckets(in: text)["2026-08-24"]?["claude-opus-5"]
        #expect(tally?.total == 115_102)
        #expect(tally?.cacheRead == 42_100_000)
    }

    @Test("synthetic and unusable records are skipped")
    func skipsNoise() {
        let text = """
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"<synthetic>","usage":{"input_tokens":5,"output_tokens":5}}}
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"claude-opus-5","usage":{"input_tokens":0,"output_tokens":0}}}
        not json at all
        {"timestamp":"2026-08-24T10:00:00.000Z","message":{"model":"claude-opus-5"}}
        """
        #expect(TokenLedger.claudeBuckets(in: text).isEmpty)
    }

    /// Codex reports a running total, not a per-turn delta. Summing the
    /// records would multiply one session by its number of turns.
    @Test("Codex totals are taken, not summed")
    func codexTakesTheNewestTotal() {
        let text = """
        {"timestamp":"2026-08-24T09:00:00.000Z","payload":{"type":"session_meta","model":"gpt-5.6-terra"}}
        {"timestamp":"2026-08-24T10:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":10}}}}
        {"timestamp":"2026-08-24T10:05:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":300,"output_tokens":40}}}}
        """
        let buckets = TokenLedger.codexBuckets(in: text)
        #expect(buckets["2026-08-24"]?["gpt-5.6-terra"]?.total == 340)
        #expect(buckets.values.flatMap(\.values).count == 1)
    }

    @Test("a Codex session with no model named still counts")
    func codexWithoutAModel() {
        let text = """
        {"timestamp":"2026-08-24T10:00:00.000Z","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":5,"output_tokens":1}}}}
        """
        #expect(TokenLedger.codexBuckets(in: text)["2026-08-24"]?["codex"]?.total == 6)
    }

    @Test("merging combines days and models without losing either")
    func mergeKeepsEverything() {
        let a: TokenLedger.Buckets = ["2026-08-24": ["opus": TokenTally(input: 1, output: 1)]]
        let b: TokenLedger.Buckets = ["2026-08-24": ["opus": TokenTally(input: 2, output: 3),
                                                     "sonnet": TokenTally(input: 4, output: 0)],
                                      "2026-08-23": ["opus": TokenTally(input: 9, output: 9)]]
        let merged = TokenLedger.merge(a, b)
        #expect(merged["2026-08-24"]?["opus"]?.total == 7)
        #expect(merged["2026-08-24"]?["sonnet"]?.total == 4)
        #expect(merged["2026-08-23"]?["opus"]?.total == 18)
    }

    @Test("a period sums only the days inside it")
    func periodFiltering() {
        let buckets: TokenLedger.Buckets = [
            "2026-08-24": ["opus": TokenTally(input: 10, output: 1)],
            "2026-08-20": ["opus": TokenTally(input: 100, output: 10)],
            "2026-07-01": ["opus": TokenTally(input: 1000, output: 100)],
        ]
        let day = TokenLedger.dayComponents(year: 2026, month: 8, day: 22)
        #expect(TokenLedger.total(buckets, since: day)["opus"]?.total == 11)
        #expect(TokenLedger.total(buckets, since: nil)["opus"]?.total == 1221)
    }
}

@Suite("Token usage summary")
struct TokenUsageSummaryTests {
    private func summary() -> TokenUsageSummary {
        TokenUsageSummary(byTool: [
            TokenUsageSummary.claude: [
                "claude-opus-5": TokenTally(input: 364, output: 182_100),
                "claude-opus-4-7": TokenTally(input: 110, output: 30_600),
            ],
            TokenUsageSummary.codex: ["gpt-5.6-terra": TokenTally(input: 900, output: 100)],
        ])
    }

    @Test("a tool total is the sum of its models")
    func toolTotals() {
        #expect(summary().total(for: TokenUsageSummary.claude) == 213_174)
        #expect(summary().cached(for: TokenUsageSummary.claude) == 0)
        #expect(summary().total(for: TokenUsageSummary.codex) == 1_000)
        #expect(summary().total(for: "Cursor") == 0)
    }

    @Test("models are ordered largest first")
    func modelOrder() {
        let models = summary().models(for: TokenUsageSummary.claude)
        #expect(models.first?.model == "claude-opus-5")
        #expect(models.last?.model == "claude-opus-4-7")
    }

    @Test("figures are shortened to two significant places")
    func compactFormatting() {
        #expect(ExpandedActivityCard.compactTokens(213_174) == "213.2K")
        #expect(ExpandedActivityCard.compactTokens(1_100_000) == "1.1M")
        #expect(ExpandedActivityCard.compactTokens(2_500_000_000) == "2.5B")
        #expect(ExpandedActivityCard.compactTokens(842) == "842")
    }

    @Test("the vendor prefix is dropped from a model name")
    func modelNames() {
        #expect(ExpandedActivityCard.shortModel("claude-opus-4-8") == "opus-4-8")
        #expect(ExpandedActivityCard.shortModel("gpt-5.6-terra") == "gpt-5.6-terra")
    }

    @Test("a period cutoff is derived from the calendar, not a fixed span")
    func periodCutoffs() {
        let launch = Date(timeIntervalSince1970: 1_000_000)
        #expect(TokenUsagePeriod.all.cutoff(launchedAt: launch) == nil)
        #expect(TokenUsagePeriod.session.cutoff(launchedAt: launch) == launch)
        let today = TokenUsagePeriod.today.cutoff(launchedAt: launch)
        #expect(today == Calendar.current.startOfDay(for: Date()))
        if let week = TokenUsagePeriod.week.cutoff(launchedAt: launch), let today {
            #expect(week < today)
        }
    }
}

@Suite("Display selection")
struct DisplaySelectionTests {
    /// A 14" Pro: notch measured from the two auxiliary areas.
    private func builtInNotched(isMain: Bool = true) -> NotchGeometry.Candidate {
        let frame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        return NotchGeometry.Candidate(
            isBuiltIn: true, isMain: isMain,
            frame: frame,
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
            safeTop: 38,
            left: CGRect(x: 0, y: 944, width: 656, height: 38),
            right: CGRect(x: 856, y: 944, width: 656, height: 38))
    }

    /// An external monitor: no cutout, no safe-area inset, menu bar only if it
    /// is the main display.
    private func external(isMain: Bool, hasMenuBar: Bool = true,
                          origin: CGPoint = CGPoint(x: 1512, y: 0)) -> NotchGeometry.Candidate {
        let frame = CGRect(origin: origin, size: CGSize(width: 2560, height: 1440))
        let barHeight: CGFloat = hasMenuBar ? 24 : 0
        return NotchGeometry.Candidate(
            isBuiltIn: false, isMain: isMain,
            frame: frame,
            visibleFrame: CGRect(x: frame.minX, y: frame.minY,
                                 width: frame.width, height: frame.height - barHeight),
            safeTop: 0)
    }

    @Test("the built-in display still wins while the lid is open")
    func builtInPreferred() {
        let screens = [builtInNotched(), external(isMain: false)]
        let choice = NotchGeometry.choose(screens, mode: .builtInThenExternal)
        #expect(choice?.index == 0)
        #expect(choice?.source == .measured)
    }

    /// The bug: in clamshell the built-in screen leaves `NSScreen.screens`, so
    /// the old rule found nothing and hid the overlay entirely.
    @Test("clamshell falls back to the external display")
    func clamshellUsesExternal() {
        let screens = [external(isMain: true)]
        #expect(NotchGeometry.choose(screens, mode: .builtInOnly) == nil)

        let choice = NotchGeometry.choose(screens, mode: .builtInThenExternal)
        #expect(choice?.index == 0)
        #expect(choice?.source == .external)
    }

    @Test("an external placeholder sits at top centre under the menu bar")
    func placeholderIsCentred() {
        let monitor = external(isMain: true)
        let rect = NotchGeometry.placeholderNotch(for: monitor)
        #expect(abs(rect.midX - monitor.frame.midX) < 0.5)
        #expect(abs(rect.maxY - monitor.frame.maxY) < 0.5)
        #expect(rect.height == 24)
    }

    /// A secondary display with no menu bar of its own reports no inset at all;
    /// a zero-height rect would give the pill no neck to hang from.
    @Test("a display with no menu bar still gets a usable height")
    func noMenuBarStillHasHeight() {
        let rect = NotchGeometry.placeholderNotch(for: external(isMain: false, hasMenuBar: false))
        #expect(rect.height == NotchGeometry.standardMenuBarHeight)
    }

    @Test("main-display mode follows the monitor when it holds the menu bar")
    func mainDisplayModeFollowsTheMenuBar() {
        let screens = [builtInNotched(isMain: false), external(isMain: true)]
        let choice = NotchGeometry.choose(screens, mode: .mainDisplay)
        #expect(choice?.index == 1)
        #expect(choice?.source == .external)
    }

    @Test("main-display mode still measures a built-in main display")
    func mainDisplayModeMeasuresBuiltIn() {
        let screens = [builtInNotched(isMain: true), external(isMain: false)]
        let choice = NotchGeometry.choose(screens, mode: .mainDisplay)
        #expect(choice?.index == 0)
        #expect(choice?.source == .measured)
    }

    @Test("built-in-only keeps the old behaviour exactly")
    func builtInOnlyUnchanged() {
        #expect(NotchGeometry.choose([external(isMain: true)], mode: .builtInOnly) == nil)
        #expect(NotchGeometry.choose([builtInNotched()], mode: .builtInOnly)?.index == 0)
    }

    @Test("no displays at all resolves to nothing rather than crashing")
    func noScreens() {
        #expect(NotchGeometry.choose([], mode: .builtInThenExternal) == nil)
        #expect(NotchGeometry.choose([], mode: .mainDisplay) == nil)
    }
}

@Suite("Completion folding")
struct CompletionFoldingTests {
    private func alert(_ id: String, title: String, kind: AlertKind = .finished,
                       source: String? = "cmux", subtitle: String? = "finished · main",
                       createdAt: TimeInterval? = 100) -> DevReadyAlert {
        DevReadyAlert(id: id, title: title, subtitle: subtitle, source: source,
                      kind: kind, createdAt: createdAt)
    }

    @MainActor
    @Test("a session and its subagents fold into one row")
    func subagentsFoldIntoTheSession() {
        let state = NotchState()
        state.enqueueDevReady([
            alert("a", title: "NotchPill"),
            alert("b", title: "NotchPill", subtitle: "subagent finished · main"),
            alert("c", title: "NotchPill", subtitle: "subagent finished · main"),
        ])
        #expect(state.devReadyAlerts.count == 1)
        #expect(state.devReadyAlerts.first?.completionCount == 3)
        // Keeps the first row's identity, so a dismissal already aimed at it lands.
        #expect(state.devReadyAlerts.first?.id == "a")
        #expect(state.devReadyAlerts.first?.displaySubtitle == "3 finished · main")
    }

    @MainActor
    @Test("different projects stay separate rows")
    func projectsDoNotFold() {
        let state = NotchState()
        state.enqueueDevReady([
            alert("a", title: "NotchPill"),
            alert("b", title: "murmur-app"),
        ])
        #expect(state.devReadyAlerts.count == 2)
        #expect(state.devReadyAlerts.allSatisfy { $0.completionCount == 1 })
    }

    /// A waiting alert carries the answer buttons and the reply target. Folding
    /// two of them would leave no way to answer either.
    @MainActor
    @Test("questions never fold")
    func waitingNeverFolds() {
        let state = NotchState()
        state.enqueueDevReady([
            alert("a", title: "NotchPill", kind: .waiting, subtitle: "needs input"),
            alert("b", title: "NotchPill", kind: .waiting, subtitle: "needs input"),
        ])
        #expect(state.devReadyAlerts.count == 2)
    }

    @Test("folding carries the newest timestamp")
    func foldingTakesTheNewerTime() {
        let older = alert("a", title: "NotchPill", createdAt: 100)
        let newer = alert("b", title: "NotchPill", createdAt: 500)
        #expect(older.folding(newer).createdAt == 500)
        #expect(newer.folding(older).createdAt == 500)
    }

    @Test("a single completion reads exactly as before")
    func singleIsUnchanged() {
        let one = alert("a", title: "NotchPill")
        #expect(one.completionCount == 1)
        #expect(one.displaySubtitle == "finished · main")
    }

    /// The count is folded into redacted text, never into the raw subtitle —
    /// otherwise a grouped row becomes the one path that prints a secret.
    @Test("a folded subtitle is still redacted")
    func foldedSubtitleStaysRedacted() {
        var a = alert("a", title: "NotchPill", subtitle: "finished · sk-ant-api03-SECRETVALUE")
        a.groupedCount = 4
        let shown = a.displaySubtitle ?? ""
        #expect(shown.hasPrefix("4 finished"))
        #expect(!shown.contains("SECRETVALUE"))
    }

    @Test("a history entry written before folding still decodes")
    func legacyHistoryDecodes() throws {
        let json = #"{"id":"x","title":"NotchPill","subtitle":"finished · main","kind":"finished"}"#
        let decoded = try JSONDecoder().decode(DevReadyAlert.self, from: Data(json.utf8))
        #expect(decoded.completionCount == 1)
    }
}

@Suite("ShelfFiler")
struct ShelfFilerTests {
    private func tree(_ name: String = UUID().uuidString) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        return (root, destination)
    }

    @Test("files into an empty folder and returns an undo token")
    func filesIntoEmptyFolder() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.pdf")
        try Data("hello".utf8).write(to: source)
        let token = try ShelfFiler.file(source, into: folder)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: token.to.path))
        #expect(token.to.lastPathComponent == "report.pdf")
    }

    @Test("collision adds Finder-style numeric suffixes without overwriting")
    func collisions() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("report.pdf")
        let original = folder.appendingPathComponent("report.pdf")
        try Data("new".utf8).write(to: source)
        try Data("original".utf8).write(to: original)
        let first = try ShelfFiler.file(source, into: folder)
        #expect(first.to.lastPathComponent == "report 2.pdf")
        #expect(String(data: try Data(contentsOf: original), encoding: .utf8) == "original")

        let secondSource = root.appendingPathComponent("report.pdf")
        try Data("third".utf8).write(to: secondSource)
        let second = try ShelfFiler.file(secondSource, into: folder)
        #expect(second.to.lastPathComponent == "report 3.pdf")
    }

    @Test("extensionless and dotfile names get suffixes")
    func extensionlessNames() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["README", ".env"] {
            let source = root.appendingPathComponent(name)
            let existing = folder.appendingPathComponent(name)
            try Data("source".utf8).write(to: source)
            try Data("existing".utf8).write(to: existing)
            let token = try ShelfFiler.file(source, into: folder)
            #expect(token.to.lastPathComponent == "\(name) 2")
        }
    }

    @Test("undo restores the original path and contents")
    func undoRestores() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: source)
        let token = try ShelfFiler.file(source, into: folder)
        try ShelfFiler.undo(token)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(!FileManager.default.fileExists(atPath: token.to.path))
        #expect(String(data: try Data(contentsOf: source), encoding: .utf8) == "notes")
    }

    @Test("undo refuses a vanished filed file or occupied source")
    func undoConflicts() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("a.txt")
        try Data("a".utf8).write(to: source)
        let token = try ShelfFiler.file(source, into: folder)
        try FileManager.default.removeItem(at: token.to)
        #expect(throws: ShelfFiler.FilingError.undoConflicted) { try ShelfFiler.undo(token) }

        try Data("a".utf8).write(to: source)
        try Data("b".utf8).write(to: token.to)
        #expect(throws: ShelfFiler.FilingError.undoConflicted) { try ShelfFiler.undo(token) }
    }

    @Test("missing source is rejected before touching the destination")
    func missingSource() throws {
        let (root, folder) = try tree()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("missing.txt")
        #expect(throws: ShelfFiler.FilingError.sourceMissing(source)) {
            try ShelfFiler.file(source, into: folder)
        }
    }

    @Test("a read-only destination leaves the source in place")
    func readOnlyDestination() throws {
        let (root, folder) = try tree()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("locked.txt")
        try Data("locked".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        do {
            try ShelfFiler.file(source, into: folder)
            #expect(FileManager.default.fileExists(atPath: source.path) == false)
        } catch let error as ShelfFiler.FilingError {
            #expect(error == .destinationUnwritable(folder))
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }
}

@Suite("FinderRecentFolders")
struct FinderRecentFoldersTests {
    private func bookmark(_ url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    @Test("resolves directories, filters files, and preserves order")
    func resolvesAndLimits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let one = root.appendingPathComponent("one")
        let two = root.appendingPathComponent("two")
        let file = root.appendingPathComponent("file.txt")
        try FileManager.default.createDirectory(at: one, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: two, withIntermediateDirectories: true)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "finder-tests.\(UUID().uuidString)")!
        defaults.set([
            ["file-bookmark": try bookmark(one)],
            ["file-bookmark": try bookmark(file)],
            ["file-bookmark": try bookmark(two)]
        ], forKey: FinderRecentFolders.defaultsKey)
        let result = FinderRecentFolders.load(defaults: defaults, limit: 2)
        #expect(result.map { $0.path } == [one, two].map { $0.standardizedFileURL.path })
    }

    @Test("malformed and absent data returns an empty list")
    func malformedIsEmpty() {
        let defaults = UserDefaults(suiteName: "finder-tests.\(UUID().uuidString)")!
        #expect(FinderRecentFolders.load(defaults: defaults).isEmpty)
        defaults.set(["not a dictionary"], forKey: FinderRecentFolders.defaultsKey)
        #expect(FinderRecentFolders.load(defaults: defaults).isEmpty)
    }
}

@MainActor
@Suite("DestinationStore")
struct DestinationStoreTests {
    private func folder(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dest-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("pinned precede recents and duplicates remain pinned")
    func orderingAndDeduplication() throws {
        let pinned = try folder("pinned")
        let recent = try folder("recent")
        let defaults = UserDefaults(suiteName: "destination-tests.\(UUID().uuidString)")!
        let store = DestinationStore(defaults: defaults, recents: { [pinned, recent] })
        store.pin(pinned)
        #expect(store.destinations().map(\.url) == [pinned, recent])
        #expect(store.destinations().first?.source == .pinned)
        try? FileManager.default.removeItem(at: pinned)
        #expect(store.pinned == [pinned])
        #expect(store.destinations().map(\.url) == [recent])
        try? FileManager.default.removeItem(at: recent)
    }

    @Test("recents are capped at six")
    func recentLimit() throws {
        let urls = try (0..<8).map { try folder("recent-\($0)") }
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let store = DestinationStore(
            defaults: UserDefaults(suiteName: "destination-tests.\(UUID().uuidString)")!,
            recents: { urls }
        )
        #expect(store.destinations().count == 6)
    }
}

@Suite("ExpandedActivityBuilder shelf")
struct ExpandedActivityShelfTests {
    private func build(
        shelfItems: [ShelfCardItem],
        receipt: ShelfFilingReceipt? = nil,
        error: String? = nil
    ) -> [ExpandedActivity] {
        ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            showMedia: false, showActiveApp: false, showVolume: false,
            showClock: false, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            shelfItems: shelfItems, shelfReceipt: receipt, shelfError: error)
    }

    @Test("an empty shelf has no card without a receipt or error")
    func emptyShelfIsHidden() {
        #expect(build(shelfItems: []).isEmpty)
    }

    /// A drop arrives from outside the deck and knows nothing about which page
    /// is showing. Landing on any other card makes the drop look like it did
    /// nothing at all.
    @MainActor
    @Test("a drop pulls the deck to the shelf from any other card")
    func dropFocusesTheShelf() {
        let kinds = ["agents", "media", "shelf", "battery"]
        let state = NotchState()
        state.selectExpandedDeckPage(1, kinds: kinds)
        #expect(state.resolvedExpandedDeckPage(for: kinds) == 1)

        state.focusExpandedDeck(kind: "shelf")
        #expect(state.resolvedExpandedDeckPage(for: kinds) == 2)
    }

    /// The shelf is not always on the deck — it appears only when it has
    /// something to show. Asking for a card that is not there must not strand
    /// the deck on a page that does not exist.
    @MainActor
    @Test("focusing a card the deck does not have leaves it in range")
    func focusingAnAbsentCardIsSafe() {
        let kinds = ["agents", "media"]
        let state = NotchState()
        state.focusExpandedDeck(kind: "shelf")
        let page = state.resolvedExpandedDeckPage(for: kinds)
        #expect(kinds.indices.contains(page))
    }

    /// A drop target stays immediately reachable with the complete deck enabled.
    @Test("a drop target remains reachable in the full deck")
    func dropSurvivesACrowdedDeck() {
        let quota = ClaudeQuota(sessionPercent: 7, weeklyPercent: 85)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: NowPlaying(title: "Song", artist: "Artist", isPlaying: true),
            nextEvent: nil, appSwitchHint: nil, frontmostApp: "Safari",
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [], claudeQuota: quota, ciRuns: [],
            showMedia: true, showActiveApp: true, showVolume: false,
            showClock: true, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            showAgents: true, showCI: true,
            shelfItems: [], shelfReceipt: nil, shelfError: nil,
            shelfDropTargeted: true)

        // A transient drop target remains directly reachable even in a full deck.
        #expect(items.contains { $0.kind == "shelf" })
    }

    /// The undo lives on the shelf card, so a live receipt keeps it reachable.
    @Test("a live receipt remains reachable")
    func receiptRemainsReachable() {
        let receipt = ShelfFilingReceipt(
            token: ShelfFiler.UndoToken(from: URL(fileURLWithPath: "/tmp/a.txt"),
                                        to: URL(fileURLWithPath: "/tmp/dst/a.txt")),
            destinationName: "dst", itemName: "a.txt",
            expiresAt: Date().addingTimeInterval(10))
        let quota = ClaudeQuota(sessionPercent: 7, weeklyPercent: 85)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: NowPlaying(title: "Song", artist: "Artist", isPlaying: true),
            nextEvent: nil, appSwitchHint: nil, frontmostApp: "Safari",
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [], claudeQuota: quota, ciRuns: [],
            showMedia: true, showActiveApp: true, showVolume: false,
            showClock: true, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            showAgents: true, showCI: true,
            shelfItems: [], shelfReceipt: receipt, shelfError: nil,
            shelfDropTargeted: false)
        #expect(items.first?.kind == "shelf")
    }

    /// Files on the shelf are files that are invisible anywhere else.
    @Test("a shelf holding files stays visible on a full deck")
    func loadedShelfSurvivesAFullDeck() {
        let item = ShelfCardItem(id: UUID(), name: "a.txt",
                                 url: URL(fileURLWithPath: "/tmp/a.txt"))
        let quota = ClaudeQuota(sessionPercent: 7, weeklyPercent: 85)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: NowPlaying(title: "Song", artist: "Artist", isPlaying: true),
            nextEvent: nil, appSwitchHint: nil, frontmostApp: "Safari",
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [], claudeQuota: quota, ciRuns: [],
            showMedia: true, showActiveApp: true, showVolume: false,
            showClock: true, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            showAgents: true, showCI: true,
            shelfItems: [item], shelfReceipt: nil, shelfError: nil,
            shelfDropTargeted: false)
        #expect(items.contains { $0.kind == "shelf" })
    }

    /// Live agents answer "what is running right now" and keep the lead.
    @Test("live agents still come first")
    func agentsOutrankTheShelf() {
        let item = ShelfCardItem(id: UUID(), name: "a.txt",
                                 url: URL(fileURLWithPath: "/tmp/a.txt"))
        let session = AgentSession(id: "s1", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session],
            showMedia: false, showActiveApp: false, showVolume: false,
            showClock: false, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            showAgents: true,
            shelfItems: [item], shelfReceipt: nil, shelfError: nil,
            shelfDropTargeted: false)
        #expect(items.first?.kind == "agents")
        #expect(items.dropFirst().first?.kind == "shelf")
    }

    /// Without this the feature is invisible: an empty shelf draws no card, so
    /// a file dragged at the notch has nothing to aim at and gives no sign that
    /// releasing would do anything.
    @Test("a hovering drag reveals the drop zone on an empty shelf")
    func dragRevealsDropZone() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            showMedia: false, showActiveApp: false, showVolume: false,
            showClock: false, showCalendar: false, showTimer: false,
            showSystemStats: false, showBattery: false, showShelf: true,
            shelfItems: [], shelfReceipt: nil, shelfError: nil,
            shelfDropTargeted: true)
        #expect(items.contains { $0.kind == "shelf" })
        if case .shelf(_, _, _, let targeted) = items.first {
            #expect(targeted)
        } else {
            Issue.record("expected a shelf card while a drag is targeting")
        }
    }

    /// A dropped file stays reachable even when every optional card is enabled.
    @Test("a dropped file remains reachable in the complete deck")
    func shelfSurvivesInTheCompleteDeck() {
        let item = ShelfCardItem(id: UUID(), name: "report.txt",
                                 url: URL(fileURLWithPath: "/tmp/report.txt"))
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: NowPlaying(title: "Song", artist: "Artist", isPlaying: true),
            nextEvent: nil, appSwitchHint: nil, frontmostApp: "Safari",
            systemVolume: 42, timer: nil,
            systemStats: SystemStats(cpuPercent: 10, memoryPercent: 20),
            battery: BatteryStatus(level: 50, isCharging: false),
            showMedia: true, showActiveApp: true, showVolume: true,
            showClock: true, showCalendar: false, showTimer: false,
            showSystemStats: true, showBattery: true, showShelf: true,
            shelfItems: [item], shelfReceipt: nil, shelfError: nil)
        #expect(items.contains { $0.kind == "shelf" })
    }

    @Test("an empty shelf stays visible while the receipt is live")
    func receiptKeepsCard() {
        let receipt = ShelfFilingReceipt(
            token: ShelfFiler.UndoToken(from: URL(fileURLWithPath: "/tmp/a"), to: URL(fileURLWithPath: "/tmp/b/a")),
            destinationName: "b", itemName: "a", expiresAt: .now)
        #expect(build(shelfItems: [], receipt: receipt).count == 1)
    }

    @Test("receipt expiry timestamps do not reanimate the shelf card")
    func receiptTimeDoesNotChangeContentKey() {
        let token = ShelfFiler.UndoToken(from: URL(fileURLWithPath: "/tmp/a"), to: URL(fileURLWithPath: "/tmp/b/a"))
        let first = ShelfFilingReceipt(token: token, destinationName: "b", itemName: "a", expiresAt: .now)
        let second = ShelfFilingReceipt(token: token, destinationName: "b", itemName: "a", expiresAt: .now.addingTimeInterval(5))
        #expect(build(shelfItems: [], receipt: first).first?.contentKey == build(shelfItems: [], receipt: second).first?.contentKey)
    }
}

// MARK: - Update version comparison

@Suite("UpdateChecker version compare")
struct UpdateVersionTests {
    @Test("newer versions are detected, equal/older are not")
    func ordering() {
        #expect(UpdateChecker.isNewer("1.2.0", than: "1.1.9"))
        #expect(UpdateChecker.isNewer("1.1.10", than: "1.1.9"))   // numeric, not lexical
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.9.9"))
        #expect(!UpdateChecker.isNewer("1.1.9", than: "1.1.9"))   // equal
        #expect(!UpdateChecker.isNewer("1.1.8", than: "1.1.9"))   // older
        #expect(UpdateChecker.isNewer("1.1.9", than: "1.1"))      // more components
        #expect(!UpdateChecker.isNewer("1.1", than: "1.1.0"))     // equal padded
    }

    // The download URL came out of the API response with its scheme and host
    // unread, so the entire chain rested on api.github.com being the only
    // thing that could ever shape that JSON.
    @Test("only https GitHub origins are accepted as update downloads")
    func downloadOriginIsChecked() {
        #expect(UpdateChecker.isTrustedDownload(
            URL(string: "https://github.com/shawngeorgie06/NotchPill/releases/download/v1/a.zip")!))
        #expect(UpdateChecker.isTrustedDownload(
            URL(string: "https://objects.githubusercontent.com/x/a.zip")!))

        // Plaintext, a local path, and a look-alike that would pass a naive
        // prefix or "contains" check.
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "http://github.com/x/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "file:///tmp/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "https://github.com.evil.test/a.zip")!))
        #expect(!UpdateChecker.isTrustedDownload(
            URL(string: "https://notgithub.com/a.zip")!))
    }
}

// MARK: - Geometry / metrics math (hardware-independent)

@Suite("NotchMetrics")
struct NotchMetricsTests {
    @Test("collapsed size matches the notch, expanded design scales uniformly")
    func sizes() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 1.0)
        #expect(m.collapsedSize == CGSize(width: 180, height: 32))
        #expect(m.expandedWidth == 640)
        #expect(m.expandedHeight == 190)
    }

    @Test("scale shrinks the rendered pill uniformly")
    func scaled() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 680, designExpandedHeight: 190, scale: 0.65)
        #expect(m.expandedWidth == 442)          // 680 * 0.65
        #expect(abs(m.expandedHeight - 123.5) < 0.001) // 190 * 0.65
        #expect(m.designContentSize == CGSize(width: 680, height: 190))
    }

    @Test("collapsed preview grows with chip count")
    func collapsedPreview() {
        let m = NotchMetrics(notchWidth: 180, notchHeight: 32,
                             designExpandedWidth: 640, designExpandedHeight: 190, scale: 0.65)
        #expect(m.collapsedPreviewSize(chipCount: 0) == m.collapsedSize)
        #expect(m.collapsedPreviewSize(chipCount: 2).width > m.collapsedSize.width)
        #expect(m.collapsedPreviewSize(chipCount: 2).height > m.collapsedSize.height)
    }
}

@Suite("Overlay window pixel alignment")
struct WindowPixelAlignmentTests {
    private let screenTop: CGFloat = 982
    /// Fractional on purpose: a centred notch on a 1512pt display with an odd
    /// content width lands every edge on a half-point, which is the soft-rim case.
    private let notchMidX: CGFloat = 756.25
    private let contentSizes = [CGSize(width: 389.3, height: 121.7),
                                CGSize(width: 200, height: 38),
                                CGSize(width: 1058.49, height: 214.01)]

    private func frame(_ size: CGSize, scale: CGFloat) -> CGRect {
        NotchGeometry.windowFrame(notchMidX: notchMidX, screenMaxY: screenTop,
                                  contentSize: size, scale: scale)
    }

    private func isOnPixelGrid(_ value: CGFloat, scale: CGFloat) -> Bool {
        let device = value * scale
        return abs(device - device.rounded()) < 1e-9
    }

    @Test("every edge lands on a device pixel at 2x and 1x")
    func edgesOnGrid() {
        for scale in [CGFloat(2), 1] {
            for size in contentSizes {
                let f = frame(size, scale: scale)
                for edge in [f.minX, f.maxX, f.minY, f.maxY] {
                    #expect(isOnPixelGrid(edge, scale: scale), "edge \(edge) @\(scale)x for \(size)")
                }
            }
        }
    }

    @Test("never smaller than the padded content size")
    func neverShrinks() {
        for scale in [CGFloat(2), 1] {
            for size in contentSizes {
                let f = frame(size, scale: scale)
                #expect(f.width >= size.width + 4)
                #expect(f.height >= size.height + 2)
            }
        }
    }

    @Test("stays centred on the notch within half a device pixel")
    func staysCentred() {
        for scale in [CGFloat(2), 1] {
            for size in contentSizes {
                let f = frame(size, scale: scale)
                #expect(abs(f.midX - notchMidX) <= 0.5 / scale + 1e-9)
            }
        }
    }

    @Test("top edge stays flush with the top of the screen")
    func topFlush() {
        for scale in [CGFloat(2), 1] {
            for size in contentSizes {
                #expect(frame(size, scale: scale).maxY == screenTop)
            }
        }
    }

    /// A measured notch has both edges on whole points, so its centre is on
    /// a whole or half point. The window must then be centred on it exactly:
    /// the silhouette and the hit rects centre on the window, so any drift
    /// slides the neck off the hardware cutout.
    @Test("a measured notch centre is kept exactly, at 2x and 1x")
    func exactCentreForMeasuredNotch() {
        for mid in [CGFloat(756), 756.5] {
            for scale in [CGFloat(2), 1] {
                for size in contentSizes {
                    let f = NotchGeometry.windowFrame(notchMidX: mid, screenMaxY: screenTop,
                                                      contentSize: size, scale: scale)
                    #expect(abs(f.midX - mid) < 1e-9, "midX \(f.midX) for \(mid) @\(scale)x \(size)")
                    for edge in [f.minX, f.maxX, f.minY] {
                        #expect(isOnPixelGrid(edge, scale: scale))
                    }
                    #expect(f.width >= size.width + 4)
                }
            }
        }
    }

    @Test("already-aligned input is left untouched")
    func idempotent() {
        let f = frame(CGSize(width: 396, height: 120), scale: 2)
        #expect(NotchGeometry.pixelAligned(f, scale: 2) == f)
    }
}

@Suite("NotchContentLayout")
struct NotchContentLayoutTests {
    @Test("text scale grows faster than layout when items are few")
    func textScaling() {
        let layoutScale: CGFloat = 1.8
        let text = NotchContentLayout.textScale(forLayoutScale: layoutScale)
        #expect(text > layoutScale)
    }

    @Test("every expanded page uses one fixed canvas")
    func expandedSizing() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 148, scale: 0.58)
        let short: [ExpandedActivity] = [.clock]
        let full = Array(repeating: ExpandedActivity.clock, count: ExpandedActivity.allKinds.count)
        let shortLayout = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: short)
        let fullLayout = NotchContentLayout.expandedDeckLayout(metrics: metrics, activities: full)
        #expect(shortLayout.size == fullLayout.size)
        #expect(shortLayout.readability == fullLayout.readability)
        #expect(shortLayout.textScale == fullLayout.textScale)
    }

    @Test("collapsed pill grows wider with more chips and shrinks readability")
    func collapsedSizing() {
        let metrics = NotchMetrics(notchWidth: 120, notchHeight: 32,
                                   designExpandedWidth: 720, designExpandedHeight: 148, scale: 0.58)
        let np = NowPlaying(title: "T", artist: "A", isPlaying: true, artwork: nil)
        let one = NotchContentLayout.collapsedLayout(metrics: metrics, chips: [.media(np)])
        let three: [CollapsedChip] = [
            .media(np),
            .calendar(CalendarEvent(title: "Meet", start: .now, location: nil, isAllDay: false)),
            .timer(ActiveTimer(label: "Focus", endDate: Date().addingTimeInterval(300)))
        ]
        let many = NotchContentLayout.collapsedLayout(metrics: metrics, chips: three)
        #expect(one.readability > many.readability)
        #expect(many.size.width >= one.size.width)
    }
}

@MainActor @Suite("Wave 3 surface layout")
struct NotchSurfaceLayoutTests {
    private func metrics(hasNotch: Bool = true, userScale: CGFloat = 1,
                         topGap: CGFloat = 10) -> NotchMetrics {
        NotchMetrics(notchWidth: 185, notchHeight: 32,
                     designExpandedWidth: 720, designExpandedHeight: 190,
                     scale: 0.54 * userScale, topGap: topGap, userScale: userScale,
                     hasPhysicalNotch: hasNotch, screenWidth: 1512)
    }

    @Test("content clears the hardware bottom with a consistent inner margin")
    func shoulderClearance() {
        for scale in [CGFloat(0.7), 1, 1.3] {
            let inset = NotchContentLayout.surfaceTopInset(metrics: metrics(userScale: scale))
            #expect(inset == 12)
        }
        #expect(NotchContentLayout.surfaceTopInset(metrics: metrics(topGap: 60)) == 60)
    }

    @Test("floating displays reserve daylight and a deliberate inner top inset")
    func floatingClearance() {
        let m = metrics(hasNotch: false)
        #expect(NotchContentLayout.surfaceTopInset(metrics: m) == ExpandedNotchShape.floatingGap + 12)
        #expect(NotchContentLayout.surfaceTopInset(metrics: m)
                > NotchContentLayout.surfaceTopInset(metrics: metrics()))
        #expect(NotchContentLayout.surfaceTopInset(metrics: metrics(hasNotch: false, topGap: 60)) == 60)
    }

    @Test("clearance adds height without spending the deck's card or footer budget")
    func deckBodyAndFooter() {
        for hasNotch in [true, false] {
            for scale in [CGFloat(0.7), 1, 1.3] {
                let m = metrics(hasNotch: hasNotch, userScale: scale)
                let one = NotchContentLayout.expandedDeckLayout(metrics: m, activities: [.clock])
                let every = NotchContentLayout.expandedDeckLayout(
                    metrics: m, activities: Array(repeating: .clock, count: ExpandedActivity.allKinds.count))
                #expect(one.size == every.size)
                #expect(one.size.width <= m.designExpandedWidth * m.scale)
                let body = NotchContentLayout.surfaceContentHeight(metrics: m, surfaceSize: one.size)
                #expect(body - NotchContentLayout.deckChromeHeight - NotchContentLayout.expandedTrayInset
                        == NotchContentLayout.expandedContentCeiling)
                #expect(NotchContentLayout.expandedContentCeiling == 168)
                // ExpandedView spends one 8pt inset on either side of the
                // 168pt card and reserves its footer below, inside the rim.
                let rect = CGRect(origin: .zero, size: one.size)
                let path = ExpandedNotchShape(notchWidth: m.notchWidth, notchHeight: m.notchHeight,
                                              hasPhysicalNotch: hasNotch, wrapsHardwareNotch: true).path(in: rect)
                let cardTop = m.notchHeight + NotchContentLayout.surfaceTopInset(metrics: m) + NotchSpace.base
                for x in [NotchSpace.section, one.size.width - NotchSpace.section] {
                    #expect(path.contains(CGPoint(x: x, y: cardTop)))
                    #expect(path.contains(CGPoint(x: x, y: cardTop + 168)))
                }
                for x in [rect.midX - 100, rect.midX, rect.midX + 100] {
                    #expect(path.contains(CGPoint(x: x, y: rect.maxY - NotchSpace.base)))
                }
            }
        }
    }

    @Test("peeks, waiting rows, replies and updates all retain their body allowance")
    func overlayBudgets() {
        let alert = DevReadyAlert(id: "clearance", title: "Build finished", agent: "Fixture")
        let waiting = DevReadyAlert(id: "waiting-clearance", title: "Needs input", agent: "Fixture",
                                    kind: .waiting, agentMessage: "Continue?")
        for hasNotch in [true, false] {
            for gap in [CGFloat(0), 10, 60] {
                let m = metrics(hasNotch: hasNotch, topGap: gap)
                func body(_ layout: NotchContentLayoutMetrics) -> CGFloat {
                    NotchContentLayout.surfaceContentHeight(metrics: m, surfaceSize: layout.size)
                }
                #expect(body(NotchContentLayout.devReadyLayout(metrics: m, alerts: [alert], answerEnabled: false))
                        == NotchContentLayout.devReadyRowHeight + 4)
                #expect(body(NotchContentLayout.devReadyLayout(metrics: m, alerts: [alert, alert], answerEnabled: false))
                        == 18 + NotchContentLayout.devReadyListHeight(rowCount: 2) + 4)
                #expect(body(NotchContentLayout.waitingLayout(metrics: m, alerts: [waiting], answerEnabled: false))
                        == NotchContentLayout.devReadyRowHeight + 4
                            + NotchContentLayout.waitingExtraHeight(alerts: [waiting], answerEnabled: false))
                #expect(body(NotchContentLayout.updateLayout(metrics: m)) == 78)
                #expect(body(NotchContentLayout.replyComposeLayout(metrics: m)) == 92)
                #expect(body(NotchContentLayout.replyComposeLayout(metrics: m, hasQuestion: true))
                        == 92 + NotchContentLayout.replyQuestionExtra)
            }
        }
    }

    @Test("a wider replacement caption preserves clearance and its measured lines")
    func replacementCaption() {
        let m = metrics()
        let short = DevReadyAlert(id: "short", title: "Done", agent: "Fixture")
        let caption = DevReadyAlert(id: "long", title: String(repeating: "This caption needs room. ", count: 25))
        let small = NotchContentLayout.devReadyLayout(metrics: m, alerts: [short], answerEnabled: false)
        let large = NotchContentLayout.devReadyLayout(metrics: m, alerts: [caption], answerEnabled: false)
        #expect(large.size.width > small.size.width)
        let measured = NotchContentLayout.peekTitleLayout(metrics: m, alerts: [caption], answerEnabled: false)
        #expect(NotchContentLayout.surfaceContentHeight(metrics: m, surfaceSize: large.size)
                == NotchContentLayout.devReadyRowHeight + 4
                    + NotchContentLayout.titleExtraHeight(alerts: [caption], lines: measured.lines))
        for size in [small.size, large.size] {
            let path = ExpandedNotchShape(notchWidth: m.notchWidth, notchHeight: m.notchHeight, wrapsHardwareNotch: true)
                .path(in: CGRect(origin: .zero, size: size))
            for x in [CGFloat(14), size.width - 14] {
                #expect(path.contains(CGPoint(x: x, y: m.notchHeight + NotchContentLayout.surfaceTopInset(metrics: m))))
            }
        }
    }

    @Test("early grow and close frames use one progress on a fixed canvas")
    func singleGrowthAndReversal() {
        let m = metrics()
        let size = NotchContentLayout.expandedDeckSize(metrics: m, activities: [.clock])
        let rect = CGRect(origin: .zero, size: size)
        let steps: [CGFloat] = [0.01, 0.05, 0.12, 0.3, 0.5, 0.75, 1]
        for hasNotch in [true, false] {
            var closing = ExpandedNotchShape(notchWidth: m.notchWidth, notchHeight: m.notchHeight,
                                             hasPhysicalNotch: hasNotch, wrapsHardwareNotch: true)
            for progress in steps.reversed() {
                let opening = ExpandedNotchShape(notchWidth: m.notchWidth, notchHeight: m.notchHeight,
                                                 progress: progress, hasPhysicalNotch: hasNotch, wrapsHardwareNotch: true)
                closing.animatableData = opening.animatableData
                let path = opening.path(in: rect)
                #expect(path == closing.path(in: rect), "reversal changed geometry at \(progress)")
                let bounds = path.boundingRect
                let widthProgress = hasNotch ? progress : progress * (0.5 + 0.5 * progress)
                #expect(abs(bounds.width - (m.notchWidth + (size.width - m.notchWidth) * widthProgress)) < 0.001)
                #expect(abs(bounds.maxY - (m.notchHeight + (size.height - m.notchHeight) * progress)) < 0.001)
                #expect(hasNotch ? bounds.minY == 0 : bounds.minY >= m.notchHeight)
                #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(bounds))
                if !hasNotch { #expect(!path.contains(CGPoint(x: 10, y: m.notchHeight / 2))) }
            }
        }
    }

    @Test("compact chip dimensions stay independent of expanded clearance")
    func compactSizing() {
        let baseline = NotchContentLayout.collapsedLayout(metrics: metrics(topGap: 0), chips: [.clock])
        let roomy = NotchContentLayout.collapsedLayout(metrics: metrics(topGap: 60), chips: [.clock])
        #expect(baseline.size == roomy.size)
        #expect(baseline.readability == roomy.readability)
        #expect(baseline.size == CGSize(width: 201, height: 95))
    }

    @Test("the actual update root expands around the hardware sides")
    func rootShoulderWiring() throws {
        let m = metrics()
        let state = NotchState()
        state.updateProgress = UpdateProgress(version: "fixture", phase: .downloading, fraction: 0.5)
        let suite = "notchpill.geometry.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let size = NotchContentLayout.updateLayout(metrics: m).size
        let root = NotchRootView(state: state, shelf: ShelfStore(defaults: defaults), timer: .shared,
                                 metrics: m, actions: .noop)
        let renderer = ImageRenderer(content: root.frame(width: size.width, height: size.height))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(data: &pixels, width: image.width, height: image.height,
                                             bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func alpha(_ x: CGFloat, _ y: CGFloat) -> UInt8 {
            pixels[(Int(y * 2) * image.width + Int(x * 2)) * 4 + 3]
        }
        #expect(alpha(8, m.notchHeight / 2) > 250)
        #expect(alpha(8, m.notchHeight + ExpandedNotchShape.neckDepth + 1) > 250)
        #expect(alpha(8, m.notchHeight + NotchContentLayout.surfaceTopInset(metrics: m)) > 250)
        #expect(alpha(size.width / 2, size.height - 5) > 250)
    }
}

@Suite("ExpandedActivityBuilder")
struct ExpandedActivityBuilderTests {
    @Test("builds live status cards without calendar or shelf")
    func liveCards() {
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true, artwork: nil)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: np,
            nextEvent: nil,
            appSwitchHint: nil,
            frontmostApp: "Safari",
            systemVolume: 42,
            timer: nil,
            systemStats: nil,
            battery: nil,
            showMedia: true,
            showActiveApp: true,
            showVolume: true,
            showClock: true,
            showCalendar: false,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showShelf: false
        )
        #expect(items.contains(.media(np)))
        #expect(items.contains(.activeApp(name: "Safari")))
        #expect(items.contains(.volume(42)))
        #expect(items.contains(.clock))
        #expect(items.count == 4)
    }

    @Test("respects card toggles")
    func toggles() {
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil,
            nextEvent: nil,
            appSwitchHint: nil,
            frontmostApp: "Safari",
            systemVolume: 50,
            timer: nil,
            systemStats: nil,
            battery: nil,
            showMedia: false,
            showActiveApp: false,
            showVolume: false,
            showClock: true,
            showCalendar: false,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showShelf: false
        )
        #expect(items == [.clock])
    }

    /// Quiet usage still keeps its swipe page — the agents page itself is
    /// sessions only.
    @Test("a quiet quota keeps its swipe page beside live agents")
    func quietQuotaKeepsItsPage() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let quiet = ClaudeQuota(sessionPercent: 12, weeklyPercent: 20)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session], claudeQuota: quiet,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["agents", "claudeQuota"])
        guard case .agents(let tray) = items.first else {
            Issue.record("expected the agents page")
            return
        }
        #expect(tray.sessions.count == 1)
    }

    @Test("a hot quota keeps its own page, not the agents page")
    func hotQuotaKeepsItsPage() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let hot = ClaudeQuota(sessionPercent: 72, weeklyPercent: 20)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session], claudeQuota: hot,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["agents", "claudeQuota"])
    }

    @Test("a quiet quota is still the page when nothing else is on the deck")
    func quietQuotaStaysWhenItIsTheContent() {
        let quiet = ClaudeQuota(sessionPercent: 12, weeklyPercent: 20)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            claudeQuota: quiet,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["claudeQuota"])
    }

    @Test("CI keeps its swipe page beside live agents")
    func ciKeepsItsPage() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let passed = CIRun(id: "r", repo: "o/r", workflow: "CI", branch: "main",
                           state: .passed, started: Date())
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session], ciRuns: [passed],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true, showCI: true)
        #expect(items.map(\.kind) == ["agents", "ci"])
    }

    @Test("a failing build keeps its own page, not the agents page")
    func failedCIKeepsItsPage() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let failed = CIRun(id: "r", repo: "o/r", workflow: "CI", branch: "main",
                           state: .failed, started: Date())
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session], ciRuns: [failed],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true, showCI: true)
        #expect(items.map(\.kind) == ["agents", "ci"])
    }

    @Test("now playing keeps its own page beside live agents")
    func mediaKeepsItsPage() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: np, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session],
            showMedia: true, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["agents", "media"])
        guard case .agents(let tray) = items.first else {
            Issue.record("expected the agents page")
            return
        }
        #expect(tray.sessions.count == 1)
    }

    @Test("now playing keeps its own page when no agents are live")
    func mediaAloneStaysAPage() {
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true)
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: np, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            showMedia: true, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false, showAgents: true)
        #expect(items.map(\.kind) == ["media"])
    }

    @Test("shelf and clipboard stay their own pages beside the tray")
    func shelfStaysASwipe() {
        let session = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                                   state: .working, lastActivity: Date())
        let item = ShelfCardItem(id: UUID(), name: "a.txt",
                                 url: URL(fileURLWithPath: "/tmp/a.txt"))
        let clip = ClipboardEntry(id: UUID(), text: "copied", copiedAt: Date())
        let items = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            agentSessions: [session],
            showMedia: false, showActiveApp: false, showVolume: false, showClock: false,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: true, showAgents: true,
            shelfItems: [item], clipboard: [clip])
        #expect(items.map(\.kind) == ["agents", "shelf", "clipboard"])
    }

    @Test("pinned activity moves to the front without changing the others")
    func pinnedActivity() {
        let items: [ExpandedActivity] = [.clock, .timer(ActiveTimer(label: "Focus", endDate: .now.addingTimeInterval(60))), .volume(40)]
        let ordered = ExpandedActivityBuilder.prioritizing(items, pinnedKind: "timer")
        #expect(ordered.map(\.kind) == ["timer", "clock", "volume"])
    }
}

@Suite("NowPlaying progress")
struct NowPlayingProgressTests {
    @Test("interpolates elapsed time while playing")
    func interpolation() {
        let start = Date(timeIntervalSince1970: 1_000)
        let np = NowPlaying(
            title: "T",
            artist: "A",
            isPlaying: true,
            artwork: nil,
            elapsed: 10,
            duration: 100,
            playbackRate: 1,
            timestamp: start
        )
        let later = start.addingTimeInterval(5)
        #expect(abs((np.interpolatedElapsed(at: later) ?? 0) - 15) < 0.001)
    }
}

@Suite("CollapsedChipBuilder")
struct CollapsedChipBuilderTests {
    @Test("builds multiple chips at once")
    func multiple() {
        let np = NowPlaying(title: "Song", artist: "Artist", isPlaying: true, artwork: nil)
        let event = CalendarEvent(title: "Standup", start: Date().addingTimeInterval(900), location: nil, isAllDay: false)
        let chips = CollapsedChipBuilder.chips(
            nowPlaying: np,
            nextEvent: event,
            shelfCount: 2,
            appSwitchHint: nil,
            timer: nil,
            systemStats: nil,
            battery: nil,
            showMedia: true,
            showCalendar: true,
            showShelf: true,
            showAppSwitch: true,
            showTimer: false,
            showSystemStats: false,
            showBattery: false,
            showClock: false
        )
        #expect(chips.count == 3)
    }

    @Test("surfaces the active agent before expansion")
    func activeAgent() {
        let session = AgentSession(id: "s", agent: "codex", project: "NotchPill",
                                   state: .working, lastActivity: Date(), locatorId: nil,
                                   directory: nil, subagent: nil, task: nil)
        let chips = CollapsedChipBuilder.chips(
            nowPlaying: nil, nextEvent: nil, shelfCount: 0, appSwitchHint: nil,
            timer: nil, systemStats: nil, battery: nil, agentSessions: [session],
            showMedia: false, showCalendar: false, showShelf: false, showAppSwitch: false,
            showTimer: false, showSystemStats: false, showBattery: false,
            showAgents: true, showClock: false)
        #expect(chips == [.agent(name: "Codex", state: "working", count: 1)])
    }

    @Test("generated Codex workspace labels yield to the real task")
    func generatedWorkspaceDoesNotBecomeAgentContext() {
        let session = AgentSession(id: "s", agent: "codex", project: "w",
                                   state: .working, lastActivity: Date(), locatorId: nil,
                                   directory: nil, subagent: nil,
                                   task: "Fix the expanded notch title")
        #expect(session.displayContext == "Fix the expanded notch title")
    }
}

@Suite("NotchActivity priority")
struct NotchActivityTests {
    @Test("app-switch outranks media, which outranks idle")
    func ordering() {
        let np = NowPlaying(title: "T", artist: "A", isPlaying: true, artwork: nil)
        #expect(NotchActivity.appSwitch("X").priority > NotchActivity.media(np).priority)
        #expect(NotchActivity.media(np).priority > NotchActivity.idle.priority)
    }
}

@Suite("System HUD sources")
struct SystemHUDSourceTests {
    @Test("brightness values clamp to the HUD range")
    func brightnessPercent() {
        #expect(BrightnessProvider.percent(from: -0.5) == 0)
        #expect(BrightnessProvider.percent(from: 0.625) == 63)
        #expect(BrightnessProvider.percent(from: 1.5) == 100)
    }

    @Test("HUD duration stays within a readable range")
    func hudDurationClamp() {
        #expect(AppSettings.clampSystemHUDDuration(0.1) == 0.8)
        #expect(AppSettings.clampSystemHUDDuration(1.7) == 1.7)
        #expect(AppSettings.clampSystemHUDDuration(9) == 3.0)
    }
}

@Suite("Dev-ready dismiss gesture")
struct DevReadyDismissSwipeTests {
    @Test("only a deliberate leftward horizontal swipe dismisses")
    func dismissalDirection() {
        #expect(DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -52, height: 2)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: 52, height: 2)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -30, height: 1)))
        #expect(!DevReadyDismissSwipe.isDismissal(translation: CGSize(width: -90, height: 90)))
    }
}

// MARK: - Shelf store

@MainActor
@Suite("ShelfStore")
struct ShelfStoreTests {
    private func isolatedStore() -> ShelfStore {
        ShelfStore(defaults: UserDefaults(suiteName: "notchpill.tests.\(UUID().uuidString)")!)
    }

    @Test("add dedupes by URL")
    func dedupe() {
        let shelf = isolatedStore()
        let a = URL(fileURLWithPath: "/tmp/a.txt")
        let b = URL(fileURLWithPath: "/tmp/b.txt")
        shelf.add(urls: [a, b, a])
        #expect(shelf.items.count == 2)
        shelf.add(urls: [a])
        #expect(shelf.items.count == 2)
    }

    @Test("remove and clear")
    func removeClear() {
        let shelf = isolatedStore()
        shelf.add(urls: [URL(fileURLWithPath: "/tmp/a.txt"),
                         URL(fileURLWithPath: "/tmp/b.txt")])
        if let first = shelf.items.first { shelf.remove(first) }
        #expect(shelf.items.count == 1)
        shelf.clear()
        #expect(shelf.items.isEmpty)
    }

    @Test("items persist across store instances via shared defaults")
    func persistence() throws {
        let suite = "notchpill.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        // Use real, existing files so bookmarks resolve.
        let a = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("np-a.txt")
        let b = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("np-b.txt")
        try "a".write(to: a, atomically: true, encoding: .utf8)
        try "b".write(to: b, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }

        let first = ShelfStore(defaults: defaults)
        first.add(urls: [a, b])
        #expect(first.items.count == 2)

        // A fresh store on the same defaults should restore the items.
        let restored = ShelfStore(defaults: defaults)
        #expect(restored.items.count == 2)
        #expect(Set(restored.items.map { $0.url.lastPathComponent }) == ["np-a.txt", "np-b.txt"])
    }
}

// MARK: - State manager: debounce + priority (the core no-duplicate guarantee)

@MainActor
@Suite("NotchState debounce")
struct NotchStateTests {
    /// Two media changes within the debounce window must resolve to exactly one
    /// published activity.
    @Test("two media changes in <200ms => single render")
    func mediaBurstCoalesces() async throws {
        let state = NotchState()
        var emissions: [String] = []
        let cancellable = state.$activity.dropFirst().sink { emissions.append($0.transitionKey) }
        defer { cancellable.cancel() }

        state.notifyMediaChanged(NowPlaying(title: "A", artist: "x", isPlaying: true, artwork: nil))
        state.notifyMediaChanged(NowPlaying(title: "B", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 120_000_000)

        #expect(emissions == ["media"])
    }

    @Test("app-switch hint appears alongside media")
    func appSwitchBurst() async throws {
        let state = NotchState()
        var hints: [String?] = []
        let cancellable = state.$appSwitchHint.dropFirst().sink { hints.append($0) }
        defer { cancellable.cancel() }

        state.notifyMediaChanged(NowPlaying(title: "A", artist: "x", isPlaying: true, artwork: nil))
        try await Task.sleep(nanoseconds: 300_000_000)
        state.notifyAppSwitched("Xcode")
        try await Task.sleep(nanoseconds: 80_000_000)
        state.notifyAppSwitched("Safari")
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(hints.contains("Safari"))
    }
}

@Suite("DevReadyAlert")
struct DevReadyAlertTests {
    @Test("parses JSON payload")
    func json() throws {
        let data = Data("""
        {"id":"a1","title":"Done","subtitle":"Review","source":"Cursor","agent":"Composer","bundleId":"com.example.app"}
        """.utf8)
        let alert = try #require(DevReadyAlert.parse(from: data))
        #expect(alert.title == "Done")
        #expect(alert.subtitle == "Review")
        #expect(alert.source == "Cursor")
        #expect(alert.agent == "Composer")
        #expect(alert.bundleId == "com.example.app")
    }

    @Test("parses distributed notification userInfo")
    func userInfo() {
        let alert = DevReadyAlert.parse(userInfo: [
            "id": "job-1",
            "title": "Build complete",
            "subtitle": "All green",
            "source": "Terminal",
            "agent": "claude-code",
            "bundleId": "com.apple.Terminal"
        ])
        #expect(alert?.title == "Build complete")
        #expect(alert?.agent == "claude-code")
        #expect(alert?.bundleId == "com.apple.Terminal")
    }

    @Test("dev ready layout is wider than a single collapsed chip")
    @MainActor
    func width() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let alert = DevReadyAlert(title: "Agent finished", agent: "Composer")
        let layout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [alert])
        #expect(layout.size.width >= NotchContentLayout.devReadyMinWidth)
        #expect(layout.size.width > metrics.notchWidth + 120)
    }

    @Test("dev ready layout grows with multiple agents")
    @MainActor
    func layout() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let one = DevReadyAlert(title: "Agent finished", agent: "Composer")
        let two = [
            DevReadyAlert(title: "A", agent: "Composer"),
            DevReadyAlert(title: "B", agent: "claude-code"),
        ]
        let singleLayout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: [one])
        let multiLayout = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: two)
        #expect(multiLayout.size.height > singleLayout.size.height)
    }

    @Test("dev ready layout caps height for many agents")
    @MainActor
    func cappedLayout() {
        let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                   designExpandedWidth: 640, designExpandedHeight: 190,
                                   scale: 0.65, topGap: 10)
        let three = (1...3).map { DevReadyAlert(title: "Task \($0)", agent: "Agent \($0)") }
        let six = (1...6).map { DevReadyAlert(title: "Task \($0)", agent: "Agent \($0)") }
        let layout3 = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: three)
        let layout6 = NotchContentLayout.devReadyLayout(metrics: metrics, alerts: six)
        #expect(layout3.size.height == layout6.size.height)
    }

    @Test("state queues multiple dev-ready alerts")
    @MainActor
    func queue() {
        let state = NotchState()
        state.enqueueDevReady([
            DevReadyAlert(id: "1", title: "One", agent: "A"),
            DevReadyAlert(id: "2", title: "Two", agent: "B"),
        ])
        #expect(state.devReadyAlerts.count == 2)
        state.removeDevReady(id: "1")
        #expect(state.devReadyAlerts.count == 1)
        #expect(state.devReadyAlerts.first?.agent == "B")
    }
}

@Suite("answer sets declared by the signal")
struct AgentAnswerSpecTests {
    @Test("label:keystroke pairs, and bare labels that are their own key")
    func parsesPairs() {
        let parsed = AgentAnswer.parse("Yes:y|No:n|1|2|3")
        #expect(parsed?.map(\.label) == ["Yes", "No", "1", "2", "3"])
        #expect(parsed?.map(\.keystroke) == ["y", "n", "1", "2", "3"])
    }

    @Test("labels may contain spaces and commas")
    func labelsWithPunctuation() {
        // `|` and `:` separate precisely so a label like this stays intact.
        let parsed = AgentAnswer.parse("Allow for session:a|Deny, always:d")
        #expect(parsed?.map(\.label) == ["Allow for session", "Deny, always"])
        #expect(parsed?.map(\.keystroke) == ["a", "d"])
    }

    @Test("a trailing ! suppresses Return")
    func suppressesReturn() {
        // A TUI that self-confirms on keypress must not also get a Return — it
        // would confirm whatever prompt came next.
        let parsed = AgentAnswer.parse("Approve:a!|Deny:d")
        #expect(parsed?.first?.appendsReturn == false)
        #expect(parsed?.last?.appendsReturn == true)
    }

    @Test("empty and malformed specs fall back rather than render nothing")
    func emptySpecs() {
        #expect(AgentAnswer.parse(nil) == nil)
        #expect(AgentAnswer.parse("") == nil)
        #expect(AgentAnswer.parse("   ") == nil)
        #expect(AgentAnswer.parse("||") == nil)
        #expect(AgentAnswer.parse(":x") == nil)     // no label
        #expect(AgentAnswer.parse("Label:") == nil) // no keystroke
    }

    @Test("an alert with no spec offers no buttons at all")
    @MainActor func noSpecMeansNoButtons() {
        // The inferred Yes/No/1/2/3 set was removed by request. Falling back
        // to it here would put those capsules back, since permission
        // decisions also reach the button row.
        let alert = DevReadyAlert(title: "p", agent: "claude-code",
                                  bundleId: "com.apple.Terminal", kind: .waiting)
        #expect(alert.answers.isEmpty)
        #expect(!alert.canAnswerFromNotch(replyEnabled: true))
        #expect(alert.answerDelivery == .keystrokes)
    }

    /// An agent that states its options keeps them: nothing is being guessed.
    @Test("a declared set is still offered")
    @MainActor func declaredAnswersSurvive() {
        let alert = DevReadyAlert(title: "p", agent: "codex",
                                  bundleId: "com.apple.Terminal", kind: .waiting,
                                  answerSpec: "Yes:y|No:n")
        #expect(alert.answers.map(\.label) == ["Yes", "No"])
        #expect(alert.canAnswerFromNotch(replyEnabled: true))
    }

    @Test("a declared set overrides the per-agent guesswork")
    func declarationWins() {
        // Codex would be refused by name, but a signal that says how to answer it
        // knows better than our heuristic.
        let alert = DevReadyAlert(title: "p", agent: "codex", bundleId: "com.apple.Terminal",
                                  kind: .waiting, answerSpec: "Approve:a|Deny:d")
        #expect(alert.supportsTypedAnswers)
        #expect(alert.answers.map(\.label) == ["Approve", "Deny"])
    }

    @Test("delivery=none refuses answers even with a declared set")
    func deliveryNone() {
        let alert = DevReadyAlert(title: "p", bundleId: "com.apple.Terminal", kind: .waiting,
                                  answerSpec: "Yes:y", deliverySpec: "none")
        #expect(!alert.supportsTypedAnswers)
    }

    @Test("delivery=paste is honoured")
    func deliveryPaste() {
        let alert = DevReadyAlert(title: "p", bundleId: "com.apple.Terminal", kind: .waiting,
                                  deliverySpec: "paste")
        #expect(alert.answerDelivery == .paste)
    }

    @Test("answers and delivery survive both signal transports")
    func roundTrips() throws {
        let data = Data("""
        {"id":"a1","title":"p","kind":"waiting","answers":"Approve:a|Deny:d","delivery":"paste"}
        """.utf8)
        let decoded = try #require(DevReadyAlert.parse(from: data))
        #expect(decoded.answers.map(\.keystroke) == ["a", "d"])
        #expect(decoded.answerDelivery == .paste)

        let posted = DevReadyAlert.parse(userInfo: [
            "title": "p", "kind": "waiting", "answers": "Approve:a", "delivery": "none"
        ])
        #expect(posted?.answers.map(\.label) == ["Approve"])
        #expect(posted?.supportsTypedAnswers == false)
    }
}

@Suite("agent branding")
struct AgentBrandingTests {
    @Test("the agent field identifies a brandable agent")
    func recognisesAgents() {
        #expect(DevReadyAlert(title: "p", agent: "claude-code").knownAgent == .claudeCode)
        #expect(DevReadyAlert(title: "p", agent: "codex").knownAgent == .codex)
        // Case-insensitive: the hook writes lowercase, a hand-rolled caller may not.
        #expect(DevReadyAlert(title: "p", agent: "Claude-Code").knownAgent == .claudeCode)
    }

    @Test("`source` identifies the agent when `agent` is absent")
    func fallsBackToSource() {
        #expect(DevReadyAlert(title: "p", source: "codex").knownAgent == .codex)
    }

    @Test("Cursor is recognised under either name it reports")
    func recognisesCursor() {
        #expect(DevReadyAlert(title: "p", agent: "Cursor").knownAgent == .cursor)
        #expect(DevReadyAlert(title: "p", agent: "Composer").knownAgent == .cursor)
    }

    @Test("unrecognised producers stay unbranded and keep the host icon")
    func unknownAgents() {
        // CI hooks and bare scripts must keep falling through to the host app's
        // icon — the branding is additive, not a replacement.
        #expect(DevReadyAlert(title: "p", agent: "buildbot").knownAgent == nil)
        #expect(DevReadyAlert(title: "p").knownAgent == nil)
    }

    @Test("answers are offered only where they would actually land")
    func typedAnswerSupport() {
        // Delivery is synthetic keystrokes into the host's frontmost window.
        // Cursor and the Codex app are GUIs, and Codex's approval prompt uses
        // its own keymap — offering Yes/No/1/2/3 there is a button that lies.
        #expect(DevReadyAlert(title: "p", agent: "claude-code").supportsTypedAnswers)
        #expect(!DevReadyAlert(title: "p", agent: "codex").supportsTypedAnswers)
        #expect(!DevReadyAlert(title: "p", agent: "Composer").supportsTypedAnswers)
        // Unrecognised producers keep the previous behaviour — someone wiring
        // their own terminal agent opted in by sending kind=waiting.
        #expect(DevReadyAlert(title: "p", agent: "my-tui-agent").supportsTypedAnswers)
    }

    @Test("an unanswerable waiting row budgets no button height")
    @MainActor func unanswerableRowIsShorter() {
        // The height budget must mirror `canAnswer`, or a peek reserves space
        // for buttons the row will not draw. Since the generic capsules were
        // removed, neither of these draws any — only a permission decision does.
        let codex = DevReadyAlert(title: "p", agent: "codex", bundleId: "com.openai.codex",
                                  kind: .waiting, message: "Approve?")
        let claude = DevReadyAlert(title: "p", agent: "claude-code", bundleId: "com.apple.Terminal",
                                   kind: .waiting, message: "Approve?")
        let decision = DevReadyAlert(title: "p", agent: "claude-code",
                                     bundleId: "com.apple.Terminal", kind: .waiting,
                                     message: "Approve?", deliverySpec: "decision",
                                     requestId: "req-1")
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [codex], answerEnabled: true)
                == WaitingLayoutTests.messageOnlyExtra)
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [claude], answerEnabled: true)
                == WaitingLayoutTests.messageOnlyExtra)
        #expect(NotchContentLayout.waitingExtraHeight(alerts: [decision], answerEnabled: true)
                == WaitingLayoutTests.withButtonsExtra)
    }

    @Test("an agent with no app installed has no agent icon to show")
    func noAppNoIcon() {
        // Drives the ClaudeMark fallback: knownAgent is set but agentAppIcon is
        // nil, so the row must draw the mark rather than the terminal's icon.
        let alert = DevReadyAlert(title: "p", agent: "claude-code",
                                  bundleId: "com.apple.Terminal")
        if alert.agentAppIcon == nil {
            #expect(alert.knownAgent == .claudeCode)
        }
    }
}

@Suite("DevReadyAlert.questionText")
struct QuestionTextTests {
    @Test("only a waiting alert with a non-empty message has a question")
    func onlyWaitingWithMessage() {
        #expect(DevReadyAlert(title: "p", kind: .waiting, message: "Allow Bash?").questionText == "Allow Bash?")
        // A finished ping's message is not a question — showing it in the
        // composer would invite an answer nothing is waiting for.
        #expect(DevReadyAlert(title: "p", kind: .finished, message: "Allow Bash?").questionText == nil)
        #expect(DevReadyAlert(title: "p", kind: .waiting, message: "").questionText == nil)
        #expect(DevReadyAlert(title: "p", kind: .waiting).questionText == nil)
    }
}

@MainActor @Suite("replyComposeLayout")
struct ReplyComposeLayoutTests {
    private var metrics: NotchMetrics {
        NotchMetrics(notchWidth: 180, notchHeight: 32,
                     designExpandedWidth: 640, designExpandedHeight: 190,
                     scale: 0.65, topGap: 10)
    }
    @Test("the composer reserves extra height when it shows a question")
    func growsForQuestion() {
        let plain = NotchContentLayout.replyComposeLayout(metrics: metrics).size.height
        let withQ = NotchContentLayout.replyComposeLayout(metrics: metrics, hasQuestion: true).size.height
        #expect(withQ - plain == NotchContentLayout.replyQuestionExtra)
    }
    @Test("width is unchanged by the question")
    func widthUnchanged() {
        #expect(NotchContentLayout.replyComposeLayout(metrics: metrics).size.width
                == NotchContentLayout.replyComposeLayout(metrics: metrics, hasQuestion: true).size.width)
    }
}

@Suite("waitingLayout sizing")
struct WaitingLayoutTests {
    // `answerEnabled` is always passed explicitly: reading AppSettings.shared
    // would couple these to the developer's real UserDefaults, and mutating it
    // would write to them.
    private let metrics = NotchMetrics(notchWidth: 180, notchHeight: 32,
                                       designExpandedWidth: 640, designExpandedHeight: 190,
                                       scale: 0.65, topGap: 10)
    /// A permission decision. Since the generic Yes/No/1/2/3 capsules were
    /// removed, this is the only kind that still draws buttons — so it is the
    /// only kind whose height budget has to include them.
    private let waitingAlerts = [
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                      kind: .waiting, message: "Allow Bash?",
                      deliverySpec: "decision", requestId: "req-1")
    ]

    @Test("a waiting alert with a message is taller than the finished peek")
    @MainActor func tallerThanFinished() {
        let waiting = NotchContentLayout
            .waitingLayout(metrics: metrics, alerts: waitingAlerts, answerEnabled: true).size.height
        let finished = NotchContentLayout
            .devReadyLayout(metrics: metrics, alerts: waitingAlerts, answerEnabled: true).size.height
        #expect(waiting > finished)
    }

    /// 6 (outer VStack spacing) + 30 (2-line message), with no button row.
    static let messageOnlyExtra: CGFloat = 36
    /// …plus the button row: 6 gap + capsule + 6 bottom padding. Derived from the
    /// capsule constant so resizing the buttons updates the budget with it —
    /// under-budgeting clips them outside the window, where they stop hit-testing.
    static var withButtonsExtra: CGFloat {
        messageOnlyExtra + 6 + NotchContentLayout.answerButtonHeight + 6
    }

    @Test("the extra height budgets every gap the row actually renders")
    @MainActor func extraMatchesRenderTree() {
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: true)
                == Self.withButtonsExtra)
    }

    @Test("with answering off only the message is budgeted")
    @MainActor func noAnswerButtons() {
        #expect(NotchContentLayout.waitingExtraHeight(alerts: waitingAlerts, answerEnabled: false)
                == Self.messageOnlyExtra)
    }

    @Test("an untargetable waiting alert gets no button allowance")
    @MainActor func untargetable() {
        let alerts = [DevReadyAlert(title: "proj", kind: .waiting, message: "Allow Bash?")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true)
                == Self.messageOnlyExtra)
    }

    /// The generic quick-answer capsules are gone: a plain waiting alert now
    /// budgets the message and nothing else, however answerable it looks.
    @Test("a plain waiting alert no longer budgets buttons")
    @MainActor func plainWaitingHasNoButtons() {
        let alerts = [DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                                    kind: .waiting, message: "Allow Bash?")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true)
                == Self.messageOnlyExtra)
    }

    @Test("finished-only alerts get no waiting allowance")
    @MainActor func finishedOnly() {
        let alerts = [DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: alerts, answerEnabled: true) == 0)
    }

    /// A permission decision, for the same reason as `waitingAlerts`: it is
    /// the only kind that still draws buttons.
    private func waiting(_ msg: String, session: String) -> DevReadyAlert {
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal",
                      kind: .waiting, message: msg, sessionId: session,
                      deliverySpec: "decision", requestId: "req-\(session)")
    }

    @Test("each waiting row gets its own allowance")
    @MainActor func perRowAllowance() {
        // The flat allowance left every row after the first with no room for its
        // question, so its buttons rendered under the previous row's text.
        let two = [waiting("Allow Bash?", session: "a"), waiting("Allow Write?", session: "b")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: two, answerEnabled: true)
                == Self.withButtonsExtra * 2)
    }

    @Test("a finished row alongside a waiting one adds no allowance")
    @MainActor func mixedKinds() {
        let mixed = [waiting("Allow Bash?", session: "a"),
                     DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")]
        #expect(NotchContentLayout.waitingExtraHeight(alerts: mixed, answerEnabled: true)
                == Self.withButtonsExtra)
    }

    @Test("only the visible rows are budgeted, taking the tallest")
    @MainActor func capsAtVisibleRows() {
        // devReadyLayout shows at most devReadyMaxVisibleRows, so budgeting every
        // row would grow the window past what it can display. The tallest are
        // chosen because any row can be scrolled to and must not clip.
        let four = (1...4).map { waiting("Allow Bash \($0)?", session: "s\($0)") }
        let capped = NotchContentLayout.devReadyMaxVisibleRows
        #expect(NotchContentLayout.waitingExtraHeight(alerts: four, answerEnabled: true)
                == CGFloat(capped) * Self.withButtonsExtra)
    }

    @Test("a peek with two waiting rows is taller than one with a single row")
    @MainActor func twoRowsAreTaller() {
        let one = NotchContentLayout.waitingLayout(
            metrics: metrics, alerts: [waiting("Allow Bash?", session: "a")],
            answerEnabled: true).size.height
        let two = NotchContentLayout.waitingLayout(
            metrics: metrics,
            alerts: [waiting("Allow Bash?", session: "a"), waiting("Allow Write?", session: "b")],
            answerEnabled: true).size.height
        // Both the base row and its own waiting allowance must be added.
        #expect(two >= one + NotchContentLayout.devReadyRowHeight + Self.withButtonsExtra)
    }
}

@Suite("NowPlayingDisplayResolver")
struct NowPlayingDisplayResolverTests {
    @Test("streaming domain is not shown as artist")
    func streamingDomain() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Friends",
            artist: "vixsrc.to",
            album: nil,
            bundleIdentifier: "com.brave.Browser"
        )
        #expect(resolved?.title == "Friends")
        #expect(resolved?.artist == "")
    }

    @Test("album show name fills in when artist is a site")
    func episodeWithAlbum() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "The One Where Monica Gets a Roommate",
            artist: "streamsite.net",
            album: "Friends, Season 1",
            bundleIdentifier: "com.google.Chrome"
        )
        #expect(resolved?.title == "The One Where Monica Gets a Roommate")
        #expect(resolved?.artist == "Friends")
    }

    @Test("service name title promotes album movie name")
    func netflixTitleNoise() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Netflix",
            artist: "",
            album: "Inception",
            bundleIdentifier: "com.apple.Safari"
        )
        #expect(resolved?.title == "Inception")
    }

    @Test("combined show and episode title is split")
    func combinedTitle() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "Breaking Bad - Ozymandias",
            artist: "netflix.com",
            album: nil,
            bundleIdentifier: "com.apple.Safari"
        )
        #expect(resolved?.title == "Ozymandias")
        #expect(resolved?.artist == "Breaking Bad")
    }

    @Test("music metadata is unchanged")
    func music() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "T-Shirt",
            artist: "Migos",
            album: "Culture II",
            mediaType: "MRMediaRemoteMediaTypeMusic"
        )
        #expect(resolved?.title == "T-Shirt")
        #expect(resolved?.artist == "Migos")
    }

    @Test("youtube keeps channel as artist")
    func youtube() {
        let resolved = NowPlayingDisplayResolver.resolve(
            title: "WWDC Keynote",
            artist: "Apple",
            album: nil,
            bundleIdentifier: "com.google.Chrome"
        )
        #expect(resolved?.title == "WWDC Keynote")
        #expect(resolved?.artist == "Apple")
    }
}

// MARK: - TerminalReplyInjector (delivery core + targeting policy)

@Suite("TerminalReplyInjector")
struct TerminalReplyInjectorTests {
    private func alert(bundleId: String?) -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code", bundleId: bundleId)
    }

    @Test("canTarget requires a non-empty bundle id")
    func canTargetRule() {
        #expect(TerminalReplyInjector.canTarget(alert(bundleId: "com.googlecode.iterm2")))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: nil)))
        #expect(!TerminalReplyInjector.canTarget(alert(bundleId: "")))
    }

    @Test("validate rejects empty text")
    func rejectsEmpty() {
        #expect(TerminalReplyInjector.validate(text: "   ", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == .emptyText)
    }

    @Test("validate rejects missing target")
    func rejectsNoTarget() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: nil,
            isRunning: true, accessibilityGranted: true) == .noTarget)
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "",
            isRunning: true, accessibilityGranted: true) == .noTarget)
    }

    @Test("validate rejects when target app not running")
    func rejectsNotRunning() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: false, accessibilityGranted: true) == .targetNotRunning)
    }

    @Test("validate rejects when accessibility denied")
    func rejectsAccessibility() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: false) == .accessibilityDenied)
    }

    @Test("validate passes when all preconditions met")
    func passes() {
        #expect(TerminalReplyInjector.validate(text: "hi", bundleId: "x",
            isRunning: true, accessibilityGranted: true) == nil)
    }
}

// MARK: - NotchState reply compose

@MainActor
@Suite("NotchState reply compose")
struct NotchStateReplyTests {
    private func alert() -> DevReadyAlert {
        DevReadyAlert(title: "proj", source: "iTerm", agent: "claude-code",
                      bundleId: "com.googlecode.iterm2")
    }

    @Test("beginReply opens composer targeting the alert")
    func begins() {
        let s = NotchState()
        s.beginReply(to: alert())
        #expect(s.replyCompose?.targetAlert.title == "proj")
        #expect(s.replyCompose?.draft == "")
    }

    @Test("updateReplyDraft records text and clears prior error")
    func updates() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.setReplyError("boom")
        s.updateReplyDraft("hello")
        #expect(s.replyCompose?.draft == "hello")
        #expect(s.replyCompose?.errorText == nil)
    }

    @Test("cancelReply clears the composer")
    func cancels() {
        let s = NotchState()
        s.beginReply(to: alert())
        s.cancelReply()
        #expect(s.replyCompose == nil)
    }

    @Test("mutators no-op when composer is closed")
    func noopWhenClosed() {
        let s = NotchState()
        s.updateReplyDraft("x")
        s.setReplyError("y")
        #expect(s.replyCompose == nil)
    }
}

@Suite("DevReadyAlert kind/message")
struct DevReadyAlertKindTests {
    @Test("legacy JSON without kind decodes as .finished, no message")
    func legacyDecodes() {
        let data = #"{"id":"a","title":"proj","subtitle":"finished","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a != nil)
        #expect(a?.kind == .finished)
        #expect(a?.message == nil)
    }

    @Test("waiting JSON decodes kind + message")
    func waitingDecodes() {
        let data = #"{"id":"b","title":"proj","kind":"waiting","message":"Claude needs permission to run Bash","bundleId":"com.apple.Terminal"}"#.data(using: .utf8)!
        let a = DevReadyAlert.parse(from: data)
        #expect(a?.kind == .waiting)
        #expect(a?.message == "Claude needs permission to run Bash")
    }

    @Test("unknown kind falls back to .finished")
    func unknownKind() {
        let data = #"{"id":"c","title":"proj","kind":"bogus"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: data)?.kind == .finished)
    }

    @Test("userInfo path reads kind + message")
    func userInfoDecodes() {
        let a = DevReadyAlert.parse(userInfo: ["title":"proj","kind":"waiting","message":"pick one"])
        #expect(a?.kind == .waiting)
        #expect(a?.message == "pick one")
    }
}

@MainActor @Suite("NotchState waiting peeks")
struct NotchStateWaitingTests {
    private func waiting(_ msg: String, bundle: String = "com.apple.Terminal",
                         project: String = "proj") -> DevReadyAlert {
        DevReadyAlert(title: project, bundleId: bundle, kind: .waiting, message: msg)
    }
    @Test("a new waiting alert replaces a prior waiting alert for the same session")
    func replacesPerSession() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1"))
        s.enqueueWaiting(waiting("q2"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 1)
        #expect(waits.first?.message == "q2")
    }
    @Test("waiting alerts for different terminal apps coexist")
    func differentTerminals() {
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", bundle: "com.apple.Terminal"))
        s.enqueueWaiting(waiting("q2", bundle: "com.googlecode.iterm2"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 2)
    }
    @Test("two projects in the same terminal app coexist (replace key includes title)")
    func sameBundleDifferentProject() {
        // Two Claude Code sessions in two iTerm windows share the bundle id;
        // keying on bundleId alone would let one project clobber the other.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", bundle: "com.googlecode.iterm2", project: "NotchPill"))
        s.enqueueWaiting(waiting("q2", bundle: "com.googlecode.iterm2", project: "fleetmap"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 2)
        #expect(waits.map(\.message) == ["q1", "q2"])
    }
    @Test("a finished ping supersedes that session's waiting peek")
    func finishedSupersedesOwnSession() {
        // Waiting peeks never auto-dismiss, so the finished ping is what retires
        // them: once the agent reports done it is no longer blocked, and leaving
        // the peek up would offer to type `y` into a terminal that moved on.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?"))
        s.enqueueDevReady([DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.isEmpty)
        #expect(s.devReadyAlerts.count == 1)
    }
    @Test("a finished ping leaves another session's waiting peek alone")
    func finishedSparesOtherSession() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", project: "NotchPill"))
        s.enqueueDevReady([DevReadyAlert(title: "fleetmap", bundleId: "com.apple.Terminal")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }
    @Test("clearAll drops waiting peeks where the finished sweep spares them")
    func clearAllVsFinishedSweep() {
        // The pair's contract: the fade timer must never take a waiting peek,
        // but an explicit ✕/Escape must.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?"))
        s.enqueueDevReady([DevReadyAlert(title: "other", bundleId: "com.apple.Terminal")])
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.map(\.kind) == [.waiting])
        s.clearAllDevReady()
        #expect(s.devReadyAlerts.isEmpty)
    }
    @Test("an on-screen waiting peek demotes once it ages past the stale window")
    func staleWaitingDemotes() {
        // The ingest check can't cover this: a waiting peek never fades, so the
        // one on screen is what sits there while the terminal moves on.
        let s = NotchState()
        let now = Date()
        var old = waiting("Allow Bash?")
        old.createdAt = now.timeIntervalSince1970 - (DevReadyProvider.waitingStaleAfter + 60)
        s.enqueueWaiting(old)
        #expect(s.demoteStaleWaiting(now: now))
        #expect(s.devReadyAlerts.map(\.kind) == [.finished])
        #expect(!s.demoteStaleWaiting(now: now))   // idempotent
    }
    @Test("a fresh waiting peek is left alone by the stale sweep")
    func freshWaitingSurvives() {
        let s = NotchState()
        let now = Date()
        var fresh = waiting("Allow Bash?")
        fresh.createdAt = now.timeIntervalSince1970 - 5
        s.enqueueWaiting(fresh)
        #expect(!s.demoteStaleWaiting(now: now))
        #expect(s.devReadyAlerts.map(\.kind) == [.waiting])
    }
    @Test("removeDevReady clears a waiting alert (answered)")
    func answeredClears() {
        let s = NotchState()
        let a = waiting("q1")
        s.enqueueWaiting(a)
        s.removeDevReady(id: a.id)
        #expect(s.devReadyAlerts.isEmpty)
    }
    @Test("a finished ping's dismiss sweep leaves a waiting peek standing")
    func finishedSweepSparesWaiting() {
        // `dismissDevReady`'s auto-dismiss timer calls clearFinishedDevReady, so a
        // finished ping from terminal B must not erase terminal A's blocked question.
        let s = NotchState()
        let blocked = waiting("Allow Bash?")
        s.enqueueWaiting(blocked)
        s.enqueueDevReady([DevReadyAlert(id: "fin", title: "other", subtitle: "finished")])
        #expect(s.devReadyAlerts.count == 2)
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.map(\.id) == [blocked.id])
    }
    @Test("clearFinishedDevReady empties the list when nothing is waiting")
    func finishedOnlyClearsFully() {
        let s = NotchState()
        s.enqueueDevReady([DevReadyAlert(id: "a", title: "one"), DevReadyAlert(id: "b", title: "two")])
        s.clearFinishedDevReady()
        #expect(s.devReadyAlerts.isEmpty)
    }
}

/// The case `bundleId` + project title cannot see: two agent sessions on the
/// same repo in the same terminal app. Before the hook passed `session_id`, one
/// session's question replaced the other's and either one finishing retired both.
@MainActor @Suite("waiting peeks keyed on session id")
struct WaitingSessionIdentityTests {
    private func waiting(_ msg: String, session: String? = nil,
                         bundle: String = "com.cmuxterm.app",
                         project: String = "NotchPill") -> DevReadyAlert {
        DevReadyAlert(title: project, bundleId: bundle, kind: .waiting,
                      message: msg, sessionId: session)
    }

    @Test("two sessions in one project and one terminal app coexist")
    func distinctSessionsCoexist() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-b"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.map(\.message) == ["Allow Bash?", "Allow Write?"])
    }

    @Test("a second question from the same session still replaces the first")
    func sameSessionReplaces() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-a"))
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.count == 1)
        #expect(waits.first?.message == "Allow Write?")
    }

    @Test("session id outranks the project title")
    func sessionIdBeatsTitle() {
        // A session that changes directory reports a different project title but
        // is still the same blocked session — one peek, not two.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1", session: "sess-a", project: "NotchPill"))
        s.enqueueWaiting(waiting("q2", session: "sess-a", project: "fleetmap"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }

    @Test("a finished ping retires only its own session's waiting peek")
    func finishedRetiresOwnSessionOnly() {
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueWaiting(waiting("Allow Write?", session: "sess-b"))
        s.enqueueDevReady([DevReadyAlert(title: "NotchPill", bundleId: "com.cmuxterm.app",
                                         sessionId: "sess-a")])
        let waits = s.devReadyAlerts.filter { $0.kind == .waiting }
        #expect(waits.map(\.message) == ["Allow Write?"])
    }

    @Test("signals with no session id keep the bundleId + title behaviour")
    func legacyFallback() {
        // An older hook script, or anything calling notify-notchpill.sh directly.
        let s = NotchState()
        s.enqueueWaiting(waiting("q1"))
        s.enqueueWaiting(waiting("q2"))
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.count == 1)
    }

    @Test("a session-less signal falls back rather than orphaning a peek")
    func mixedFallsBack() {
        // Deliberate: treating these as different sessions would leave a waiting
        // peek nothing can ever supersede, still offering to answer a dead question.
        let s = NotchState()
        s.enqueueWaiting(waiting("Allow Bash?", session: "sess-a"))
        s.enqueueDevReady([DevReadyAlert(title: "NotchPill", bundleId: "com.cmuxterm.app")])
        #expect(s.devReadyAlerts.filter { $0.kind == .waiting }.isEmpty)
    }

    @Test("session id round-trips through both signal transports")
    func decoding() throws {
        let data = Data("""
        {"id":"a1","title":"NotchPill","kind":"waiting","message":"Allow Bash?","sessionId":"sess-a"}
        """.utf8)
        #expect(try #require(DevReadyAlert.parse(from: data)).sessionId == "sess-a")

        let posted = DevReadyAlert.parse(userInfo: ["title": "NotchPill", "sessionId": "sess-a"])
        #expect(posted?.sessionId == "sess-a")
    }

    @Test("absent or blank session ids read as no session")
    func blankIsAbsent() {
        // The shell writers omit the key, but a caller passing "" must not make
        // every session-less signal match every other one on an empty string.
        let data = Data(#"{"id":"a1","title":"NotchPill","sessionId":"   "}"#.utf8)
        #expect(DevReadyAlert.parse(from: data)?.sessionId == nil)
        #expect(DevReadyAlert(title: "NotchPill", sessionId: "").sessionId == nil)
        #expect(DevReadyAlert(title: "NotchPill").sessionId == nil)
    }
}

@Suite("DevReadyDedup routing")
struct DevReadyDedupTests {
    @Test("a repeated finished ping inside the window is suppressed")
    func finishedSuppressed() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(a) == true)
    }
    @Test("a finished ping past the window is allowed again")
    func finishedExpires() {
        var dedup = DevReadyDedup()
        let now = Date()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a, now: now) == false)
        #expect(dedup.shouldSuppress(a, now: now.addingTimeInterval(13)) == false)
    }
    @Test("waiting alerts bypass the fingerprint dedup entirely")
    func waitingBypasses() {
        // Every question in a session shares the project|branch fingerprint —
        // "permission to use Bash" then "permission to use Write" 5s later would
        // be dropped, and the agent would hang with nothing on screen.
        var dedup = DevReadyDedup()
        let q1 = DevReadyAlert(title: "proj", subtitle: "waiting · main",
                               kind: .waiting, message: "use Bash?")
        let q2 = DevReadyAlert(title: "proj", subtitle: "waiting · main",
                               kind: .waiting, message: "use Write?")
        #expect(dedup.shouldSuppress(q1) == false)
        #expect(dedup.shouldSuppress(q2) == false)
    }
    @Test("a waiting alert does not poison the finished window")
    func waitingNotRecorded() {
        var dedup = DevReadyDedup()
        let waiting = DevReadyAlert(title: "proj", subtitle: "s", kind: .waiting)
        let finished = DevReadyAlert(title: "proj", subtitle: "s")
        #expect(dedup.shouldSuppress(waiting) == false)
        #expect(dedup.shouldSuppress(finished) == false)
    }
    // REGRESSION: Cursor can run Claude Code as its backend, so one turn fired
    // Cursor's hook *and* the spawned `claude` process's Stop hook a second
    // later. Both reported honestly — the Claude hook correctly named Cursor as
    // the host app — and the pair read as a Claude session never started.
    @Test("one turn in one app is one peek, even from two agents")
    func crossAgentSameHostCollapses() {
        var dedup = DevReadyDedup()
        let cursor = DevReadyAlert(title: "Question for you", subtitle: "regenerate the memo?",
                                   source: "Cursor", agent: "cursor",
                                   bundleId: "com.todesktop.230313mzl4w4u92")
        let claude = DevReadyAlert(title: "bid-no-bid", subtitle: "finished · main",
                                   source: "Cursor", agent: "claude-code",
                                   bundleId: "com.todesktop.230313mzl4w4u92",
                                   sessionId: "1573ad8b")
        #expect(dedup.shouldSuppress(cursor) == false)   // the specific one wins
        #expect(dedup.shouldSuppress(claude) == true)
    }

    // The collapse must not swallow real concurrent work: two Claude Code
    // sessions in one terminal are two turns, which is the entire reason peeks
    // are keyed on the session id.
    @Test("two sessions of the same agent in one terminal both get through")
    func sameAgentSameHostBothPeek() {
        var dedup = DevReadyDedup()
        let one = DevReadyAlert(title: "NotchPill", subtitle: "finished · main",
                                source: "cmux", agent: "claude-code",
                                bundleId: "com.cmuxterm.app", sessionId: "aaa")
        let two = DevReadyAlert(title: "murmur-app", subtitle: "finished · main",
                                source: "cmux", agent: "claude-code",
                                bundleId: "com.cmuxterm.app", sessionId: "bbb")
        #expect(dedup.shouldSuppress(one) == false)
        #expect(dedup.shouldSuppress(two) == false)
    }

    @Test("a later turn in the same app is not collapsed")
    func hostWindowExpires() {
        var dedup = DevReadyDedup()
        let now = Date()
        let cursor = DevReadyAlert(title: "Question for you", subtitle: "a",
                                   source: "Cursor", agent: "cursor", bundleId: "com.cursor")
        let claude = DevReadyAlert(title: "proj", subtitle: "finished · main",
                                   source: "Cursor", agent: "claude-code", bundleId: "com.cursor")
        #expect(dedup.shouldSuppress(cursor, now: now) == false)
        #expect(dedup.shouldSuppress(claude, now: now.addingTimeInterval(6)) == false)
    }

    // A peek with no host app (the transcript watcher emits none) has nothing to
    // relate it to anything else, so it must never be collapsed.
    @Test("peeks without a host app are unaffected")
    func noBundleUnaffected() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj-a", subtitle: "finished", agent: "claude-code")
        let b = DevReadyAlert(title: "proj-b", subtitle: "finished", agent: "codex")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == false)
    }

    @Test("two sessions on the same branch both get through")
    func distinctSessionsNotSuppressed() {
        // project|branch is byte-identical for both. Suppressing the second is
        // not just a missing peek: the ping never reaches enqueueDevReady, so
        // that session's waiting peek keeps its live answer buttons.
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main", sessionId: "sess-a")
        let b = DevReadyAlert(title: "proj", subtitle: "finished · main", sessionId: "sess-b")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == false)
        #expect(dedup.shouldSuppress(a) == true)   // still a true double-fire
    }
    @Test("session-less pings keep the title|subtitle window")
    func legacySuppressionUnchanged() {
        var dedup = DevReadyDedup()
        let a = DevReadyAlert(title: "proj", subtitle: "finished · main")
        let b = DevReadyAlert(title: "proj", subtitle: "finished · main")
        #expect(dedup.shouldSuppress(a) == false)
        #expect(dedup.shouldSuppress(b) == true)
    }
}

@Suite("stale waiting signals")
struct StaleWaitingTests {
    private func waiting(ageSeconds: TimeInterval?) -> DevReadyAlert {
        DevReadyAlert(title: "proj", bundleId: "com.apple.Terminal", kind: .waiting,
                      message: "Allow Bash?",
                      createdAt: ageSeconds.map { Date().timeIntervalSince1970 - $0 })
    }
    @Test("a waiting signal older than the TTL is demoted to finished")
    func staleDemoted() {
        // Queued at 2pm while NotchPill was closed, delivered at 6pm: the answer
        // buttons would type `y⏎` into a terminal back at a shell prompt.
        let demoted = DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: 4 * 3600))
        #expect(demoted.kind == .finished)
        #expect(demoted.message == "Allow Bash?")   // still shown, just not answerable
    }
    @Test("a fresh waiting signal stays waiting")
    func freshKept() {
        #expect(DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: 10)).kind == .waiting)
    }
    @Test("a missing createdAt is treated as not stale")
    func missingTimestamp() {
        #expect(DevReadyProvider.demotingStaleWaiting(waiting(ageSeconds: nil)).kind == .waiting)
    }
    @Test("a finished alert is never touched")
    func finishedUntouched() {
        let old = DevReadyAlert(title: "proj", createdAt: 1)
        #expect(DevReadyProvider.demotingStaleWaiting(old).kind == .finished)
    }
    @Test("createdAt decodes from a number, a numeric string, or not at all")
    func createdAtDecoding() {
        let num = #"{"id":"a","title":"p","createdAt":1750000000}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: num)?.createdAt == 1_750_000_000)
        let str = #"{"id":"a","title":"p","createdAt":"1750000000"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: str)?.createdAt == 1_750_000_000)
        // Malformed / missing must never drop the alert.
        let bad = #"{"id":"a","title":"p","createdAt":"not-a-number"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: bad)?.createdAt == nil)
        #expect(DevReadyAlert.parse(from: bad)?.title == "p")
        let none = #"{"id":"a","title":"p"}"#.data(using: .utf8)!
        #expect(DevReadyAlert.parse(from: none)?.createdAt == nil)
        // userInfo path too.
        #expect(DevReadyAlert.parse(userInfo: ["title": "p", "createdAt": 1_750_000_000])?
            .createdAt == 1_750_000_000)
        #expect(DevReadyAlert.parse(userInfo: ["title": "p", "createdAt": "bogus"])?.createdAt == nil)
    }
}

// MARK: - AgentAnswer

@Suite("AgentAnswer")
struct AgentAnswerTests {
    @Test("keystrokes map correctly")
    func keystrokes() {
        #expect(AgentAnswer.yes.keystroke == "y")
        #expect(AgentAnswer.no.keystroke == "n")
        #expect(AgentAnswer.digit(2).keystroke == "2")
    }
    @Test("labels")
    func labels() {
        #expect(AgentAnswer.yes.label == "Yes")
        #expect(AgentAnswer.digit(3).label == "3")
    }
    @Test("standard set is Yes/No/1/2/3")
    func standard() {
        #expect(AgentAnswer.standardSet == [.yes, .no, .digit(1), .digit(2), .digit(3)])
    }
}

/// The hookless watchers. Both bugs that reached the user in 1.8.x lived in this
/// logic and neither had a test, so every case below is either a regression or
/// a shape taken from a real transcript on disk.
@Suite("transcript turn detection")
struct TranscriptTurnTests {
    private func tail(_ lines: [String]) -> String { lines.joined(separator: "\n") }

    @Test("Codex live session names its newest user request")
    func codexUsesNewestPrompt() {
        let transcript = tail([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Draft the release notes"}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"I will do that"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Fix the Codex live-agent text"}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Fix the Codex live-agent text")
    }

    @Test("Codex current transcript shape names its newest user request")
    func codexUsesResponseItemPrompt() {
        let transcript = tail([
            #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"Make the title meaningful"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"agent_message","message":"I will do that"}}"#,
            #"{"type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"Fix the one-letter Codex title"}]}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Fix the one-letter Codex title")
    }

    @Test("Codex approval handoffs use an activity label, not protocol text")
    func codexApprovalHandoff() {
        let handoff = "The following is the Codex agent history added since your last approval assessment."
        let transcript = tail([
            #"{"type":"event_msg","payload":{"type":"user_message","message":"Draft the release notes"}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(handoff)"}}"#
        ])
        #expect(AgentSessionScanner.codexLastPrompt(in: transcript)
                == "Draft the release notes")

        #expect(AgentSessionScanner.codexLastPrompt(in:
            #"{"type":"event_msg","payload":{"type":"user_message","message":"\#(handoff)"}}"#)
                == "Reviewing a permission request")
    }

    @Test("Codex local rate-limit record exposes a real quota and reset")
    func codexQuota() {
        let transcript = #"{"timestamp":"2026-07-31T17:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"primary":{"used_percent":42.4,"resets_at":1786130351},"secondary":{"used_percent":9.2,"resets_at":1783357722},"credits":{"balance":"123.45"}}}}"#
        let quota = AgentSessionScanner.codexQuota(in: transcript)
        #expect(quota?.usedPercent == 42)
        #expect(quota?.resetsAt == Date(timeIntervalSince1970: 1_786_130_351))
        #expect(quota?.weeklyPercent == 9)
        #expect(quota?.weeklyResetsAt == Date(timeIntervalSince1970: 1_783_357_722))
        #expect(quota?.creditsLabel == "123.45 credits balance")
        #expect(quota?.updatedAt == ISO8601DateFormatter().date(from: "2026-07-31T17:00:00Z"))
    }

    @Test("Codex oversized session metadata still exposes its working directory")
    func codexOversizedMetadataHasWorkingDirectory() {
        let prefix = #"{"payload":{"cwd":"/Users/me/Project","base_instructions":""#
        let text = prefix + String(repeating: "x", count: 40_000)
        #expect(AgentSessionScanner.firstValue(in: text, key: "cwd") == "/Users/me/Project")
    }

    @Test("an assistant message ends the turn")
    func assistantEnds() {
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#
        ])))
    }

    @Test("REGRESSION: a message you just sent is not a finished turn")
    func userDoesNotEnd() {
        // 1.8.x peeked "finished" the moment the user pressed Return, because it
        // fired on any write that went quiet without looking at what was written.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"user","message":{"role":"user"}}"#
        ])))
    }

    @Test("bookkeeping records trailing a turn don't mask it")
    func bookkeepingSkipped() {
        // Claude Code writes these after the assistant message; treating them as
        // the last word would silently suppress every peek.
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"assistant","message":{"role":"assistant"}}"#,
            #"{"type":"attachment"}"#,
            #"{"type":"file-history-snapshot"}"#
        ])))
    }

    @Test("bookkeeping after a user message still isn't a finished turn")
    func bookkeepingAfterUser() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"user","message":{"role":"user"}}"#,
            #"{"type":"file-history-snapshot"}"#
        ])))
    }

    @Test("REGRESSION: Codex nests its record under `payload`")
    func codexPayloadShape() {
        // 1.8.0 only read top-level keys, so every Codex session was silently
        // dropped — no peek, nothing logged.
        #expect(AgentTranscriptProvider.turnEnded(inTail:
            #"{"timestamp":"t","type":"response_item","payload":{"type":"agent_message"}}"#))
        #expect(!AgentTranscriptProvider.turnEnded(inTail:
            #"{"timestamp":"t","type":"response_item","payload":{"type":"user_message"}}"#))
    }

    /// The exact tail of a real Codex transcript: after the assistant record
    /// come a token usage record, a token count event and a `task_complete`
    /// event. None of those were "assistant", so the turn end was masked and
    /// Codex never peeked "finished" through the no-hook path.
    @Test("REGRESSION: Codex's trailing lifecycle records don't mask the turn")
    func codexTaskCompleteTail() {
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
            #"{"type":"token_usage_record","payload":{"turn_id":"t","usage":{}}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#,
            #"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t","last_agent_message":"Done."}}"#
        ])))
    }

    @Test("a Codex turn that has started but not completed is not finished")
    func codexTaskStarted() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant"}}"#,
            #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"t2"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#
        ])))
        // The user's message is what starts a turn; an event after it doesn't
        // turn it into a finished one.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"response_item","payload":{"type":"message","role":"user"}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#
        ])))
    }

    /// REGRESSION: Codex writes an assistant `message`, pauses, then runs tools.
    /// Treating that pause as "finished" re-armed the dismiss timer for the
    /// whole turn, so the done peek never cleared the way Claude's does.
    @Test("REGRESSION: a Codex assistant message mid-loop is not finished")
    func codexAssistantMessageIsNotTurnEnd() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"response_item","payload":{"type":"message","role":"user"}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"assistant","content":[]}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count","info":{}}}"#
        ])))
        // Quiet after a tool result is still mid-turn.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: tail([
            #"{"type":"response_item","payload":{"type":"message","role":"assistant"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"bash"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call_output","output":"ok"}}"#,
            #"{"type":"event_msg","payload":{"type":"token_count"}}"#
        ])))
    }

    @Test("an unrecognised record is not evidence of a finished turn")
    func unknownRecord() {
        // Better a missed peek than one fired at nothing.
        #expect(!AgentTranscriptProvider.turnEnded(inTail: #"{"type":"something-new"}"#))
    }

    @Test("garbage and empty tails are safe")
    func malformed() {
        #expect(!AgentTranscriptProvider.turnEnded(inTail: ""))
        #expect(!AgentTranscriptProvider.turnEnded(inTail: "not json at all"))
        // A tail sliced mid-line must not throw away the whole decision.
        #expect(AgentTranscriptProvider.turnEnded(inTail: tail([
            #"ssage":{"role":"user"}}"#,
            #"{"type":"assistant","message":{"role":"assistant"}}"#
        ])))
    }

    /// A stand-in filesystem, so naming is tested against a fixed tree instead
    /// of whatever happens to exist on the machine running the tests.
    private static let tree: Set<String> = [
        "/Users", "/Users/me", "/Users/me/Projects", "/Users/me/Projects/NotchPill",
        "/Users/me/bid-no-bid", "/Users/me/Projects/cv-prep"
    ]
    private func name(_ dir: String) -> String? {
        AgentTranscriptProvider.claudeProjectName(
            fromDirectory: dir, home: "/Users/me", exists: { Self.tree.contains($0) })
    }

    @Test("project name comes from the encoded working directory")
    func projectNaming() {
        #expect(name("-Users-me-Projects-NotchPill") == "NotchPill")
        #expect(AgentTranscriptProvider.claudeProjectName(fromDirectory: "") == nil)
    }

    @Test("Codex transcript notifications never use the generated w workspace as a title")
    func codexNotificationTitleUsesUsefulFallback() {
        #expect(AgentTranscriptProvider.codexFinishedTitle(project: "w", task: "continue")
            == "Codex finished")
        #expect(AgentTranscriptProvider.codexFinishedTitle(
            project: "w", task: "Fix the one-letter Codex notification title"
        ) == "Fix the one-letter Codex notification title")
        #expect(AgentTranscriptProvider.codexFinishedTitle(project: "NotchPill", task: nil)
            == "NotchPill")
    }

    // REGRESSION: a session started in the home directory peeked as the account
    // name ("shawngeorgie"), which reads like a project nobody has.
    @Test("the home directory is named Home, not the account")
    func homeDirectoryNaming() {
        #expect(name("-Users-me") == "Home")
        #expect(AgentTranscriptProvider.displayName(forPath: "/Users/me", home: "/Users/me") == "Home")
    }

    // REGRESSION: splitting on "-" and taking the last segment turned
    // `bid-no-bid` into `bid`. Only the filesystem can resolve the ambiguity.
    @Test("dashes in a folder name survive the round trip")
    func dashedProjectNaming() {
        #expect(name("-Users-me-bid-no-bid") == "bid-no-bid")
        #expect(name("-Users-me-Projects-cv-prep") == "cv-prep")
        #expect(AgentTranscriptProvider.claudePath(
            fromDirectory: "-Users-me-bid-no-bid",
            exists: { Self.tree.contains($0) }) == "/Users/me/bid-no-bid")
    }

    @Test("a deleted directory still yields its best-effort name")
    func vanishedProjectNaming() {
        // Nothing below /Users/me matches, so the remainder is kept verbatim
        // rather than the peek losing its label entirely.
        #expect(name("-Users-me-gone-away") == "gone-away")
    }
}

// MARK: - Hover sequencing

@MainActor
@Suite("Notch hover sequencing")
struct NotchHoverSequencingTests {
    private func settle(_ extra: TimeInterval = 0.1) async throws {
        try await Task.sleep(for: .seconds(NotchState.hoverAnimationDuration + extra))
    }

    @Test("hover duration covers the surface spring's settling")
    func hoverDurationCoversSpring() {
        // Collapse finalisation removes the expanded tree at this instant; if
        // it fired earlier the spring's tail would be cut off mid-motion.
        #expect(NotchState.hoverAnimationDuration >= NotchMotion.surfaceSettleDuration)
    }

    @Test("the window's deferred shrink waits for the hover and peek animations")
    func shrinkDelayCoversAnimations() {
        let state = NotchState()
        #expect(state.windowShrinkDelay >= NotchState.hoverAnimationDuration)
        #expect(state.windowShrinkDelay >= state.devReadyMotionDuration)
        #expect(state.windowShrinkDelay >= NotchMotion.surfaceSettleDuration)
    }

    @Test("a completed collapse releases the expanded tree")
    func collapseFinalises() async throws {
        let state = NotchState()
        state.setExpanded(true)
        try await settle()
        state.setExpanded(false)
        #expect(state.isCollapsing)
        #expect(!state.isExpanded)
        try await settle()
        #expect(!state.isCollapsing)
        #expect(state.expansionProgress == 0)
    }

    @Test("re-hovering mid-collapse cancels the pending finalisation")
    func reHoverCancelsCollapse() async throws {
        let state = NotchState()
        state.setExpanded(true)
        try await settle()
        state.setExpanded(false)
        try await Task.sleep(for: .seconds(NotchState.hoverAnimationDuration * 0.4))
        state.setExpanded(true)
        #expect(!state.isCollapsing)
        // Past the original finalisation deadline: it must not have fired.
        try await settle()
        #expect(state.isExpanded)
        #expect(!state.isCollapsing)
        #expect(state.expansionProgress == 1)
    }

    @Test("leaving again after a reversal collapses cleanly")
    func collapseAfterReversal() async throws {
        let state = NotchState()
        state.setExpanded(true)
        try await settle()
        state.setExpanded(false)
        state.setExpanded(true)
        state.setExpanded(false)
        #expect(state.isCollapsing)
        try await settle()
        #expect(!state.isCollapsing)
        #expect(!state.isExpanded)
        #expect(state.expansionProgress == 0)
    }

    @Test("out-and-in before the first frame never leaves a stale open target")
    func outBeforeOpenLands() async throws {
        let state = NotchState()
        state.setExpanded(true)
        state.setExpanded(false)
        try await settle()
        #expect(!state.isExpanded)
        #expect(!state.isCollapsing)
        #expect(state.expansionProgress == 0)
    }
}
