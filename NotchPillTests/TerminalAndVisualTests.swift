import Testing
import Foundation
import Combine
import CoreAudio
import AppKit
import SwiftUI
@testable import NotchPill

@Suite("Expanded card visual fixtures")
struct ExpandedCardVisualFixtureTests {
    @Test("an alert takes over the root surface while media artwork remains loaded")
    func notificationSuppressesMediaBackdrop() {
        let media = NowPlaying(title: "Fixture", artist: "Artist", isPlaying: true,
                               artwork: NSImage(size: NSSize(width: 12, height: 12)))
        let activities: [ExpandedActivity] = [.media(media)]
        let mediaBackdrop = MediaBackdropSelection.resolve(
            isExpanded: true, isCollapsing: false,
            hasDevReadyAlerts: false, hasReplyCompose: false,
            hasUpdateProgress: false, activities: activities, selectedPage: 0)
        let notificationBackdrop = MediaBackdropSelection.resolve(
            isExpanded: true, isCollapsing: false,
            hasDevReadyAlerts: true, hasReplyCompose: false,
            hasUpdateProgress: false, activities: activities, selectedPage: 0)
        #expect(mediaBackdrop?.artwork != nil)
        #expect(notificationBackdrop == nil)
    }

    @MainActor
    @Test("media and notification fixtures render on each display canvas")
    func fixtureCanvasesRender() throws {
        let fixtureDirectory = ProcessInfo.processInfo.environment["NOTCHPILL_VISUAL_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0) }
        if let fixtureDirectory {
            try FileManager.default.createDirectory(at: fixtureDirectory,
                                                   withIntermediateDirectories: true)
        }
        var imagesBySurface: [VisualFixtureHarness.Surface: [CGImage]] = [:]
        for display in VisualFixtureHarness.Display.allCases {
            var images: [CGImage] = []
            for compareWave1 in [false, true] {
                for surface in VisualFixtureHarness.Surface.allCases {
                    // Native scroll views need an AppKit host to paint their viewport.
                    // ImageRenderer alone omits that area even when layout succeeds.
                    let fixture = VisualFixtureHarness(surface: surface, reduceMotion: true, display: display,
                                                       compareWave1Shoulders: compareWave1)
                    let host = NSHostingView(rootView: fixture)
                    let size = host.fittingSize
                    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                          styleMask: .borderless, backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = host
                    host.setFrameSize(size)
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    // Allow onAppear-driven content reveals to settle before capture.
                    // Reduce Motion uses a 10ms animation; a synchronous bitmap
                    // otherwise records empty agent rows and quota meters.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                    host.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    defer { window.close() }
                    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    let image = try #require(bitmap.cgImage)
                    #expect(image.width > 0)
                    #expect(image.height > 0)
                    if compareWave1 { imagesBySurface[surface, default: []].append(image) }
                    if let fixtureDirectory {
                        let rep = NSBitmapImageRep(cgImage: image)
                        let data = try #require(rep.representation(using: .png, properties: [:]))
                        let name = "\(compareWave1 ? "" : "legacy-")\(display.rawValue)-\(surface.rawValue).png"
                        try data.write(to: fixtureDirectory.appendingPathComponent(name),
                                       options: .atomic)
                    }
                    if compareWave1 { images.append(image) }
                }
            }
            #expect(images.count == VisualFixtureHarness.Surface.allCases.count)
            if images.count == VisualFixtureHarness.Surface.allCases.count {
                // The long text must clip inside the same fixed deck canvas as media.
                #expect(images[0].width == images[2].width)
                #expect(images[0].height == images[2].height)
            }
        }
        for images in imagesBySurface.values {
            #expect(images.count == VisualFixtureHarness.Display.allCases.count)
            #expect(images.allSatisfy { $0.width > 0 && $0.height > 0 })
        }
    }
}

@Suite("Card order lists only what is switched on")
struct EnabledCardOrderTests {
    private let order = ["agents", "shelf", "volume", "battery", "clock"]
    private func enabled(_ kind: String) -> Bool { kind != "battery" }

    /// A dragged row is a position in the *visible* list, not in the full
    /// order, so the move has to be mapped back before it is stored.
    @Test func movingAVisibleRowReordersTheFullOrder() {
        let visible = order.filter(enabled)
        guard let volume = visible.firstIndex(of: "volume") else { return #expect(Bool(false)) }
        let moved = CardOrdering.moving(IndexSet(integer: volume), to: 0,
                                        in: order, isEnabled: enabled)
        #expect(moved.filter(enabled).first == "volume")
    }

    /// Switching a card off must not lose its place: the slot is held, so
    /// turning it back on returns it where it was rather than to the end.
    @Test func disabledKindsKeepTheirSlot() {
        let moved = CardOrdering.moving(IndexSet(integer: 2), to: 0,
                                        in: order, isEnabled: enabled)
        #expect(moved.count == order.count)
        #expect(Set(moved) == Set(order))
        #expect(moved.firstIndex(of: "battery") == order.firstIndex(of: "battery"))
    }

    @Test func anEmptyVisibleSubsetIsLeftAlone() {
        #expect(CardOrdering.moving(IndexSet(integer: 0), to: 0,
                                    in: order, isEnabled: { _ in false }) == order)
    }
}

@Suite("Terminal emulator")
struct TerminalEmulatorTests {
    private func emulator(columns: Int = 20, rows: Int = 4,
                          _ text: String) -> TerminalEmulator {
        var term = TerminalEmulator(columns: columns, rows: rows)
        term.feed(Array(text.utf8))
        return term
    }

    @Test func plainTextLandsOnTheFirstRow() {
        #expect(emulator("hello").visibleLines.first == "hello")
    }

    @Test func newlineMovesDownAndCarriageReturnGoesHome() {
        let term = emulator("one\r\ntwo")
        #expect(term.visibleLines[0] == "one")
        #expect(term.visibleLines[1] == "two")
    }

    /// A bare `\n` from a PTY is a line feed, not a new line: the shell sends
    /// `\r\n`. Moving to column 0 on `\n` alone would hide a missing `\r`.
    @Test func lineFeedKeepsTheColumn() {
        let term = emulator("abc\nd")
        #expect(term.visibleLines[1] == "   d")
    }

    /// A line that exactly fills the width must not leave a blank row behind
    /// it — the wrap is deferred until there is another character to place.
    @Test func wrapIsDeferredUntilTheNextCharacter() {
        var term = TerminalEmulator(columns: 4, rows: 3)
        term.feed(Array("abcd".utf8))
        #expect(term.cursorRow == 0)
        term.feed(Array("e".utf8))
        #expect(term.cursorRow == 1)
        #expect(term.visibleLines[0] == "abcd")
        #expect(term.visibleLines[1] == "e")
    }

    @Test func backspaceOverwritesRatherThanDeletes() {
        let term = emulator("ab\u{08}c")
        #expect(term.visibleLines[0] == "ac")
    }

    @Test func tabsAdvanceToTheNextStop() {
        let term = emulator("a\tb")
        #expect(term.visibleLines[0] == "a       b")
    }

    // MARK: - Colour

    @Test func sgrSetsAndResetsForeground() {
        var term = TerminalEmulator(columns: 10, rows: 2)
        term.feed(Array("\u{1B}[31mR\u{1B}[0mP".utf8))
        #expect(term.screen[0][0].attributes.foreground == .indexed(1))
        #expect(term.screen[0][1].attributes.foreground == .default)
    }

    @Test func brightForegroundsMapIntoTheUpperHalfOfThePalette() {
        var term = TerminalEmulator(columns: 4, rows: 2)
        term.feed(Array("\u{1B}[92mg".utf8))
        #expect(term.screen[0][0].attributes.foreground == .indexed(10))
    }

    @Test func twoFiftySixColourAndTrueColourAreBothRead() {
        #expect(TerminalEmulator.extendedColor([38, 5, 214], from: 0).0 == .indexed(214))
        #expect(TerminalEmulator.extendedColor([38, 2, 10, 20, 30], from: 0).0 == .rgb(10, 20, 30))
        // A truncated sequence must not read past the end of the list.
        #expect(TerminalEmulator.extendedColor([38, 2, 10], from: 0).0 == nil)
    }

    @Test func boldAndInverseSurviveOnTheCell() {
        var term = TerminalEmulator(columns: 4, rows: 2)
        term.feed(Array("\u{1B}[1;7mx".utf8))
        #expect(term.screen[0][0].attributes.bold)
        #expect(term.screen[0][0].attributes.inverse)
    }

    // MARK: - Cursor and erase

    @Test func absolutePositioningIsOneBased() {
        var term = TerminalEmulator(columns: 10, rows: 4)
        term.feed(Array("\u{1B}[3;5mX".utf8))   // an SGR, not a move
        term.feed(Array("\u{1B}[3;5HX".utf8))
        #expect(term.cursorRow == 2)
        #expect(term.visibleLines[2] == "    X")
    }

    @Test func eraseToEndOfLineClearsOnlyWhatFollows() {
        var term = TerminalEmulator(columns: 10, rows: 2)
        term.feed(Array("abcdef\u{1B}[1;4H\u{1B}[K".utf8))
        #expect(term.visibleLines[0] == "abc")
    }

    @Test func eraseDisplayClearsEverythingAndKeepsHistoryUnlessAsked() {
        var term = TerminalEmulator(columns: 6, rows: 2)
        term.feed(Array("one\r\ntwo\r\nthree".utf8))     // pushes "one" into scrollback
        #expect(!term.scrollback.isEmpty)
        term.feed(Array("\u{1B}[2J".utf8))
        #expect(term.visibleLines.filter { !$0.isEmpty }.isEmpty)
        #expect(!term.scrollback.isEmpty, "2J clears the screen, not the history")
        term.feed(Array("\u{1B}[3J".utf8))
        #expect(term.scrollback.isEmpty, "3J is the one that drops history")
    }

    @Test func deleteAndInsertCharactersShiftTheRestOfTheLine() {
        var term = TerminalEmulator(columns: 8, rows: 2)
        term.feed(Array("abcdef\u{1B}[1;2H\u{1B}[2P".utf8))
        #expect(term.visibleLines[0] == "adef")
        term.feed(Array("\u{1B}[1;2H\u{1B}[1@".utf8))
        #expect(term.visibleLines[0] == "a def")
    }

    // MARK: - Scrolling

    @Test func outputPastTheBottomScrollsIntoHistory() {
        var term = TerminalEmulator(columns: 6, rows: 2)
        term.feed(Array("1\r\n2\r\n3".utf8))
        #expect(term.visibleLines == ["2", "3"])
        #expect(term.scrollback.count == 1)
        #expect(String(term.scrollback[0].map(\.character)).hasPrefix("1"))
    }

    /// Output is card-only and truncated by design; the cap is what keeps a
    /// runaway command from growing memory without bound.
    @Test func historyIsCappedAtTheDocumentedLimit() {
        var term = TerminalEmulator(columns: 4, rows: 2)
        for index in 0..<(TerminalEmulator.scrollbackLimit + 50) {
            term.feed(Array("\(index % 10)\r\n".utf8))
        }
        #expect(term.scrollback.count == TerminalEmulator.scrollbackLimit)
    }

    /// A progress bar redraws inside a scroll region every frame. Those lines
    /// are not history, and keeping them would bury the real output.
    @Test func aScrollRegionDoesNotFillHistory() {
        var term = TerminalEmulator(columns: 6, rows: 4)
        term.feed(Array("\u{1B}[2;4r".utf8))
        for _ in 0..<20 { term.feed(Array("x\r\n".utf8)) }
        #expect(term.scrollback.isEmpty)
    }

    @Test func reverseIndexAtTheTopScrollsDown() {
        var term = TerminalEmulator(columns: 6, rows: 3)
        term.feed(Array("a\r\nb".utf8))
        term.feed(Array("\u{1B}[1;1H\u{1B}M".utf8))
        #expect(term.visibleLines[1] == "a")
    }

    // MARK: - Alternate screen

    @Test func theAlternateScreenHandsTheShellBackUntouched() {
        var term = TerminalEmulator(columns: 8, rows: 3)
        term.feed(Array("shell".utf8))
        term.feed(Array("\u{1B}[?1049h".utf8))
        #expect(term.isAlternateScreen)
        term.feed(Array("fullscreen".utf8))
        #expect(term.visibleLines[0] != "shell")
        term.feed(Array("\u{1B}[?1049l".utf8))
        #expect(!term.isAlternateScreen)
        #expect(term.visibleLines[0] == "shell")
    }

    @Test func cursorVisibilityFollowsDECTCEM() {
        var term = TerminalEmulator(columns: 4, rows: 2)
        term.feed(Array("\u{1B}[?25l".utf8))
        #expect(!term.cursorVisible)
        term.feed(Array("\u{1B}[?25h".utf8))
        #expect(term.cursorVisible)
    }

    // MARK: - Sequences we only need to swallow

    /// An unrecognised sequence has to vanish, not print. A stray `[?2004h`
    /// across a six-line card is worse than a feature quietly unsupported.
    @Test func unknownSequencesLeaveNothingOnScreen() {
        #expect(emulator("\u{1B}[?2004ha\u{1B}[>4;2mb").visibleLines[0] == "ab")
    }

    @Test func operatingSystemCommandsAreConsumedWhicheverTerminatorIsUsed() {
        #expect(emulator("\u{1B}]0;a title\u{07}ok").visibleLines[0] == "ok")
        #expect(emulator("\u{1B}]0;a title\u{1B}\\ok").visibleLines[0] == "ok")
    }

    // MARK: - Chunk boundaries

    /// A PTY read lands mid-character often enough that decoding each chunk on
    /// its own visibly corrupts any non-ASCII output.
    @Test func aCharacterSplitAcrossTwoReadsIsNotCorrupted() {
        var term = TerminalEmulator(columns: 8, rows: 2)
        let bytes = Array("é".utf8)
        term.feed([bytes[0]])
        term.feed([bytes[1]])
        #expect(term.visibleLines[0] == "é")
    }

    @Test func anEscapeSequenceSplitAcrossReadsStillApplies() {
        var term = TerminalEmulator(columns: 8, rows: 2)
        term.feed(Array("\u{1B}[3".utf8))
        term.feed(Array("1mR".utf8))
        #expect(term.screen[0][0].attributes.foreground == .indexed(1))
    }

    @Test func decodeReportsThePartialTailSeparately() {
        let bytes = Array("aé".utf8)
        let (text, tail) = TerminalEmulator.decode(Array(bytes.dropLast()))
        #expect(text == "a")
        #expect(tail.count == 1)
    }

    // MARK: - Resize

    /// Growing the card should reveal what just happened, not what happened
    /// first, so the bottom of the output is what stays put.
    @Test func resizingKeepsTheBottomOfTheOutput() {
        var term = TerminalEmulator(columns: 6, rows: 2)
        term.feed(Array("1\r\n2\r\n3\r\n4".utf8))
        #expect(term.visibleLines == ["3", "4"])
        term.resize(columns: 6, rows: 4)
        #expect(term.visibleLines.suffix(2) == ["3", "4"])
        term.resize(columns: 6, rows: 2)
        #expect(term.visibleLines == ["3", "4"])
    }

    @Test func resizingNarrowerDoesNotLeaveRaggedRows() {
        var term = TerminalEmulator(columns: 10, rows: 2)
        term.feed(Array("abcdefghij".utf8))
        term.resize(columns: 4, rows: 2)
        #expect(term.screen.filter { $0.count != 4 }.isEmpty)
    }
}

/// Keep unrelated PTY tests serial; concurrency is exercised explicitly below.
@MainActor
@Suite("PTY session", .serialized)
struct PTYSessionTests {
    @Test func theEnvironmentAdvertisesAColourTerminalAndALocale() {
        let env = PTYSession.environment(from: [:])
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["PAGER"] == "cat")
    }

    @Test func anExistingLocaleIsLeftAlone() {
        #expect(PTYSession.environment(from: ["LANG": "de_DE.UTF-8"])["LANG"] == "de_DE.UTF-8")
    }

    @Test func theShellFollowsTheEnvironmentWithAMacOSDefault() {
        #expect(PTYSession.loginShell().hasPrefix("/"))
    }

    /// Both the standard descriptors and /dev/tty must refer to a terminal.
    @Test func theChildGetsARealControllingTerminal() async {
        let output = await runShell("/usr/bin/tty; if [ -t 0 ] && [ -t 1 ] && [ -t 2 ] && (: </dev/tty); then printf 'controlling-%s\\n' terminal; fi")
        #expect(output.contains("/dev/ttys"), "got: \(output)")
        #expect(output.contains("controlling-terminal"), "got: \(output)")
    }

    @Test func aCommandRunsAndItsOutputComesBack() async {
        let output = await runShell("printf 'notchpill-%s\\n' ok")
        #expect(output.contains("notchpill-ok"), "got: \(output)")
    }

    @Test func theShellIsToldHowWideTheCardIs() async {
        let output = await runShell("/usr/bin/tput cols", columns: 37)
        #expect(output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "37" },
                "got: \(output)")
    }

    @Test func thePreparedEnvironmentReachesTheChild() async {
        let inherited = ProcessInfo.processInfo.environment
        let output = await runShell("printf 'TERM=%s\\nCOLORTERM=%s\\nPAGER=%s\\nGIT_PAGER=%s\\nLANG=%s\\nHOME=%s\\n' \"$TERM\" \"$COLORTERM\" \"$PAGER\" \"$GIT_PAGER\" \"$LANG\" \"$HOME\"", columns: 256)
        for entry in ["TERM=xterm-256color", "COLORTERM=truecolor", "PAGER=cat", "GIT_PAGER=cat",
                      "LANG=" + (inherited["LANG"] ?? "en_US.UTF-8"),
                      "HOME=" + (inherited["HOME"] ?? "")] {
            #expect(output.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == entry },
                    "missing \(entry); got: \(output)")
        }
    }

    @Test func theRequestedDirectoryReachesTheChild() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchPill PTY \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = await runShell("pwd -P", columns: 256, directory: directory.path)
        #expect(output.contains(directory.resolvingSymlinksInPath().path), "got: \(output)")
    }

    @Test func theShellKeepsItsLoginArgument() async {
        let output = await runShell("printf 'argv0=%s\\n' \"$0\"")
        #expect(output.contains("argv0=-sh"), "got: \(output)")
    }

    @Test func exitingTheShellReportsTheExit() async {
        #expect(await runUntilExit(shell: "/bin/sh", command: "exit\n") != nil)
    }

    @Test func anExecFailureExitsInsteadOfHanging() async {
        // start succeeds at forkpty; the nonexistent executable then reaches
        // the child's _exit path. PTYSession currently reports raw wait status
        // or zero when EOF wins the race, so check delivery rather than a code.
        #expect(await runUntilExit(shell: "/notchpill-nonexistent-\(UUID().uuidString)") != nil)
    }

    @Test func concurrentLaunchesEachReturnTheirOwnOutput() async {
        await withTaskGroup(of: (Int, String).self) { group in
            for index in 0..<6 {
                group.addTask {
                    let output = await runShell("printf 'concurrent-%s\\n' \(index)")
                    return (index, output)
                }
            }
            for await (index, output) in group {
                #expect(output.contains("concurrent-\(index)"), "got: \(output)")
            }
        }
    }

    private func runUntilExit(shell: String, command: String? = nil) async -> Int32? {
        let session = PTYSession()
        defer { session.stop() }
        var status: Int32?
        session.onExit = { status = $0 }
        let started = session.start(columns: 40, rows: 6, shell: shell)
        #expect(started)
        guard started else { return nil }
        if let command { session.write(command) }
        let deadline = ContinuousClock.now + .seconds(6)
        while status == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!session.isRunning, "the child must terminate within the deadline")
        return status
    }

    /// Clear the prompt, disable echo, and use a split completion marker so
    /// echoed input cannot satisfy output assertions. Input can be queued
    /// before the shell starts.
    private func runShell(_ command: String, columns: Int = 60,
                          directory: String? = nil) async -> String {
        let session = PTYSession()
        defer { session.stop() }
        let collected = Collected()
        session.onOutput = { bytes in collected.append(bytes) }
        let started = session.start(columns: columns, rows: 12, directory: directory, shell: "/bin/sh")
        #expect(started)
        guard started else { return "" }
        session.write("PS1=; stty -echo\n" + command + "\nprintf '\\n__notchpill_pty_%s__\\n' done\n")
        let deadline = ContinuousClock.now + .seconds(6)
        while !collected.hasCompletion && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(collected.hasCompletion, "shell did not complete: \(collected.text(columns: columns))")
        return collected.text(columns: columns)
    }

    /// Replay PTY bytes through the same emulator used by the card.
    private final class Collected {
        private var bytes: [UInt8] = []
        func append(_ chunk: [UInt8]) { bytes += chunk }
        var hasCompletion: Bool {
            String(decoding: bytes, as: UTF8.self).contains("__notchpill_pty_done__")
        }
        func text(columns: Int) -> String {
            var term = TerminalEmulator(columns: columns, rows: 80)
            term.feed(bytes)
            return (term.scrollback.map { String($0.map(\.character)) } + term.visibleLines)
                .joined(separator: "\n")
        }
    }
}

@MainActor
@Suite("Terminal key encoding")
struct TerminalKeyEncodingTests {
    private func encode(_ keyCode: UInt16, _ characters: String = "",
                        _ modifiers: NSEvent.ModifierFlags = []) -> [UInt8]? {
        TerminalStore.encode(keyCode: keyCode, characters: characters, modifiers: modifiers)
    }

    @Test func plainCharactersGoThroughAsThemselves() {
        #expect(encode(0, "a") == Array("a".utf8))
    }

    @Test func returnIsCarriageReturnNotNewline() {
        // A PTY line discipline turns CR into NL; sending NL directly is what
        // makes a shell see a blank line instead of running the command.
        #expect(encode(36) == [0x0D])
    }

    /// Tab has to reach the shell for completion. A text field would have
    /// consumed it to move focus, which is why the card uses a raw responder.
    @Test func tabReachesTheShellForCompletion() {
        #expect(encode(48) == [0x09])
    }

    @Test func arrowsSendCursorSequencesForHistory() {
        #expect(encode(126) == Array("\u{1B}[A".utf8))
        #expect(encode(125) == Array("\u{1B}[B".utf8))
        #expect(encode(124) == Array("\u{1B}[C".utf8))
        #expect(encode(123) == Array("\u{1B}[D".utf8))
    }

    @Test func deleteSendsBackspaceNotForwardDelete() {
        #expect(encode(51) == [0x7F])
        #expect(encode(117) == Array("\u{1B}[3~".utf8))
    }

    @Test func controlLettersBecomeTheirControlCodes() {
        #expect(encode(0, "c", .control) == [0x03])   // interrupt
        #expect(encode(0, "d", .control) == [0x04])   // end of file
        #expect(encode(0, "l", .control) == [0x0C])   // clear
        // Case must not change the code: ⌃⇧C is still ⌃C.
        #expect(encode(0, "C", .control) == [0x03])
    }

    /// Word motion in a shell is meta-prefixed, and macOS gives that to ⌥.
    @Test func optionIsMetaPrefixed() {
        #expect(encode(0, "b", .option) == [0x1B] + Array("b".utf8))
    }

    /// ⌘ belongs to the app — copy, paste, quit — and must never reach the
    /// shell, or ⌘Q would type "q" instead of quitting.
    @Test func commandIsLeftToTheApp() {
        #expect(encode(0, "q", .command) == nil)
        #expect(encode(36, "", .command) == nil)
    }
}

@Suite("Terminal palette")
struct TerminalPaletteTests {
    /// The xterm cube and grey ramp are computed rather than tabulated —
    /// 240 hand-written constants is 240 chances to be wrong — so the corners
    /// are what prove the arithmetic.
    @Test func theColourCubeLandsOnItsKnownCorners() {
        // 16 is the cube's black corner, 231 its white one.
        let black = TerminalPalette.components(forIndex: 16)
        #expect(black.r == 0 && black.g == 0 && black.b == 0)
        let white = TerminalPalette.components(forIndex: 231)
        #expect(white.r == 1 && white.g == 1 && white.b == 1)
        // 196 is pure red in the cube.
        let red = TerminalPalette.components(forIndex: 196)
        #expect(red.r == 1 && red.g == 0 && red.b == 0)
    }

    @Test func theGreyRampIsMonotonic() {
        let ramp = (232...255).map { TerminalPalette.components(forIndex: UInt8($0)).r }
        #expect(zip(ramp, ramp.dropFirst()).filter { $0 >= $1 }.isEmpty)
        #expect(ramp.first! > 0)
        #expect(ramp.last! < 1)
    }

    @Test func theFirstSixteenAreTheNamedColours() {
        #expect(TerminalPalette.base.count == 16)
        // Black is lifted deliberately: on the pill's dark surface a true
        // black cell is an invisible one.
        #expect(TerminalPalette.components(forIndex: 0).r > 0.15)
    }

    @MainActor
    @Test func inverseSwapsForegroundAndBackground() {
        var attributes = TerminalEmulator.Attributes()
        attributes.foreground = .indexed(1)
        attributes.inverse = true
        let resolved = TerminalPalette.resolve(attributes, defaultForeground: .white,
                                               defaultBackground: .black)
        #expect(resolved.background != nil, "inverse has to paint a background")
    }

    @MainActor
    @Test func concealedTextIsDrawnInvisibly() {
        var attributes = TerminalEmulator.Attributes()
        attributes.hidden = true
        let resolved = TerminalPalette.resolve(attributes, defaultForeground: .white,
                                               defaultBackground: .black)
        #expect(resolved.foreground == Color.black)
    }
}

@MainActor
@Suite("Terminal store", .serialized)
struct TerminalStoreTests {
    /// The whole chain the card depends on: a real shell starts, its output
    /// reaches the emulator, and a snapshot carries it out as drawable lines.
    @Test func aCommandTypedIntoTheStoreShowsUpInTheSnapshot() async {
        let store = TerminalStore.shared
        store.stop()
        defer { store.stop() }

        store.start()
        #expect(store.isLive)
        try? await Task.sleep(nanoseconds: 700_000_000)
        store.send("echo notchpill-store-ok\n")

        var text = ""
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            text = (store.emulator.scrollback.map { String($0.map(\.character)) }
                    + store.emulator.visibleLines).joined(separator: "\n")
            if text.contains("notchpill-store-ok") { break }
        }
        #expect(text.contains("notchpill-store-ok"), "got: \(text)")
        #expect(store.snapshot.lines.count == TerminalStore.rows)
        #expect(store.snapshot.revision > 0, "output has to bump the revision or nothing redraws")
    }

    /// The card is a value the deck compares. Without a revision bump the
    /// content key never changes and the shell's output never reaches screen.
    /// Output must *not* move the content key. The grid view observes the store
    /// and redraws itself; moving the key made the deck run an animated card
    /// transition for every frame the shell printed, which is what made the
    /// whole overlay — buttons and cursor included — feel slow.
    @Test func outputAloneDoesNotMoveTheContentKey() {
        var snapshot = TerminalSnapshot(revision: 1)
        let before = ExpandedActivity.terminal(snapshot).contentKey
        snapshot.revision = 2
        #expect(ExpandedActivity.terminal(snapshot).contentKey == before)
    }

    /// Six rows are visible and 200 are kept, so the card has to be able to
    /// look back at the ones that scrolled off.
    @Test func theViewportWalksBackThroughScrollback() {
        var term = TerminalEmulator(columns: 10, rows: 3)
        for n in 1...8 { term.feed(Array("line\(n)\r\n".utf8)) }
        #expect(term.scrollbackDepth > 0)
        let live = term.viewport(scrolledBack: 0)
        #expect(String(live.lines[0].map(\.character)).hasPrefix("line7"))
        #expect(live.cursorRow != nil)

        let back = term.viewport(scrolledBack: 2)
        #expect(String(back.lines[0].map(\.character)).hasPrefix("line5"))
        #expect(back.lines.count == live.lines.count)
        // The cursor is at the bottom; drawing it in history would be a lie.
        #expect(back.cursorRow == nil)
    }

    /// Past the end of what is kept, and before the live bottom, the viewport
    /// has to stop rather than index off either edge.
    @Test func theViewportClampsAtBothEnds() {
        var term = TerminalEmulator(columns: 10, rows: 3)
        for n in 1...8 { term.feed(Array("line\(n)\r\n".utf8)) }
        let deepest = term.viewport(scrolledBack: term.scrollbackDepth)
        #expect(term.viewport(scrolledBack: 9999).lines.map { $0.map(\.character) }
                == deepest.lines.map { $0.map(\.character) })
        #expect(term.viewport(scrolledBack: -5).cursorRow != nil)
    }

    /// A full-screen program owns the whole viewport; the shell's history
    /// behind it is not its to show.
    @Test func thereIsNoScrollbackOnTheAlternateScreen() {
        var term = TerminalEmulator(columns: 10, rows: 3)
        for n in 1...8 { term.feed(Array("line\(n)\r\n".utf8)) }
        #expect(term.scrollbackDepth > 0)
        term.feed(Array("\u{1B}[?1049h".utf8))
        #expect(term.scrollbackDepth == 0)
        term.feed(Array("\u{1B}[?1049l".utf8))
        #expect(term.scrollbackDepth > 0)
    }

    /// Focus and exit do change how the card is drawn, so they must move it.
    @Test func focusAndExitMoveTheContentKey() {
        let live = ExpandedActivity.terminal(TerminalSnapshot()).contentKey
        var focused = TerminalSnapshot(); focused.isFocused = true
        var exited = TerminalSnapshot(); exited.exitStatus = 0
        #expect(ExpandedActivity.terminal(focused).contentKey != live)
        #expect(ExpandedActivity.terminal(exited).contentKey != live)
    }

    /// ...but the *identity* must not move, or every line of output would
    /// destroy the card and slide the deck sideways as if a new card arrived.
    @Test func theCardIdentityStaysPutWhileOutputScrolls() {
        #expect(ExpandedActivity.terminal(TerminalSnapshot(revision: 1)).id
                == ExpandedActivity.terminal(TerminalSnapshot(revision: 99)).id)
    }

    /// A card holding keyboard focus must never be trimmed out from under the
    /// person typing into it.
    @Test func aFocusedTerminalLeadsTheDeck() {
        let deck = ExpandedActivityBuilder.activities(
            nowPlaying: nil, nextEvent: nil, appSwitchHint: nil, frontmostApp: nil,
            systemVolume: nil, timer: nil, systemStats: nil, battery: nil,
            showMedia: false, showActiveApp: false, showVolume: false, showClock: true,
            showCalendar: false, showTimer: false, showSystemStats: false,
            showBattery: false, showShelf: false,
            terminal: TerminalSnapshot(isFocused: true, revision: 1))
        #expect(deck.first?.kind == "terminal")
    }
}

// MARK: - Notch theme

@Suite("NotchMotion")
struct NotchMotionTests {
    @Test("every token collapses to the reduce-motion floor")
    func reduceMotionFloor() {
        // The floor is not "something short" — it is the exact value the rest
        // of the overlay already uses, so a card animating at 10ms next to one
        // animating at 12ms cannot happen.
        let floor = Animation.linear(duration: 0.01)
        #expect(NotchMotion.enter(reduceMotion: true) == floor)
        #expect(NotchMotion.settle(reduceMotion: true) == floor)
        #expect(NotchMotion.page(reduceMotion: true) == floor)
        #expect(NotchMotion.paint(reduceMotion: true) == floor)
        #expect(NotchMotion.exit(reduceMotion: true) == floor)
    }

    @Test("tokens are distinct from the floor when motion is allowed")
    func motionAllowed() {
        let floor = Animation.linear(duration: 0.01)
        #expect(NotchMotion.enter(reduceMotion: false) != floor)
        #expect(NotchMotion.settle(reduceMotion: false) != floor)
        #expect(NotchMotion.page(reduceMotion: false) != floor)
        #expect(NotchMotion.paint(reduceMotion: false) != floor)
        #expect(NotchMotion.exit(reduceMotion: false) != floor)
    }

    @Test("the named tokens are distinct from each other")
    func tokensDiffer() {
        // Shared curves under different names would be a lie in the source: a
        // reader would think `page` had been tuned when it had not.
        let enter = NotchMotion.enter(reduceMotion: false)
        let settle = NotchMotion.settle(reduceMotion: false)
        let page = NotchMotion.page(reduceMotion: false)
        let paint = NotchMotion.paint(reduceMotion: false)
        let exit = NotchMotion.exit(reduceMotion: false)
        #expect(enter != settle)
        #expect(enter != page)
        #expect(enter != paint)
        #expect(enter != exit)
        #expect(settle != page)
        #expect(settle != paint)
        #expect(settle != exit)
        #expect(page != paint)
        #expect(page != exit)
        #expect(paint != exit)
    }
}

@Suite("NotchMotion surface", .serialized)
struct NotchSurfaceMotionTests {
    @Test("the surface spring never overshoots")
    func surfaceDoesNotOvershoot() {
        // Progress above 1 would draw the pill wider than the window that
        // clips it. Critical damping is the only setting that is both
        // interruptible (a spring keeps its velocity) and exactly bounded.
        #expect(NotchMotion.surfaceDamping == 1)
    }

    @Test("the surface animation is SwiftUI's own spring with the documented constants")
    func surfaceIsTheNamedSpring() {
        // Every timing below is read off `surfaceSpring`; that only means
        // anything if it is the curve the view actually animates with.
        #expect(NotchMotion.surface(reduceMotion: false) == Animation.spring(NotchMotion.surfaceSpring))
        #expect(NotchMotion.surface(reduceMotion: false)
                == Animation.spring(response: NotchMotion.surfaceResponse,
                                    dampingFraction: NotchMotion.surfaceDamping))
    }

    @Test("the settle duration leaves under half a point of travel, from rest or mid-reversal")
    func settleCoversTheTail() {
        // Everything keyed to "the animation is over" (collapse finalisation,
        // the window's deferred shrink) reads this one number. Measured on
        // SwiftUI's `Spring`, not a closed form of it, over the widest travel
        // (a caption peek is ~1058pt; 1100 leaves margin).
        let spring = NotchMotion.surfaceSpring
        let settle = NotchMotion.surfaceSettleDuration
        let widestTravel = 1100.0
        #expect((1 - spring.value(target: 1.0, time: settle)) * widestTravel < 0.5)
        // A leave that interrupts an opening starts with velocity pointing the
        // wrong way, and finalisation is timed from that leave. Try every
        // point of the opening to interrupt at.
        var worst = 0.0
        for step in 1...80 {
            let t = Double(step) * 0.005
            let position = spring.value(target: 1.0, time: t)
            let velocity = spring.velocity(target: 1.0, time: t)
            let landing = position + spring.value(target: -position, initialVelocity: velocity, time: settle)
            worst = max(worst, abs(landing))
        }
        #expect(worst * widestTravel < 0.5)
    }

    @Test("the reveal window is read off the real spring")
    func revealWindowMatchesSpring() {
        let spring = NotchMotion.surfaceSpring
        let start = NotchMotion.surfaceTime(reaching: Double(NotchMotion.revealStart))
        let end = NotchMotion.surfaceTime(reaching: Double(NotchMotion.revealEnd))
        #expect(abs(spring.value(target: 1.0, time: start) - Double(NotchMotion.revealStart)) < 0.001)
        #expect(abs(spring.value(target: 1.0, time: end) - Double(NotchMotion.revealEnd)) < 0.001)
        #expect(start < end)
        #expect(end < NotchMotion.surfaceSettleDuration)
    }

    @Test("the chips leave over the window in which the card arrives")
    func chipsCrossfadeWithReveal() {
        // The card's opacity is a function of surface progress, so it is fully
        // in by `revealEnd`. Chips still fading on the old hover-duration
        // schedule overlapped it with two sets of text for ~0.2s.
        let start = NotchMotion.surfaceTime(reaching: Double(NotchMotion.revealStart))
        let end = NotchMotion.surfaceTime(reaching: Double(NotchMotion.revealEnd))
        #expect(NotchMotion.chipsYield(reduceMotion: false)
                == Animation.easeInOut(duration: end - start).delay(start))
        #expect(NotchMotion.chipsYield(reduceMotion: true) == Animation.linear(duration: 0.01))
        #expect(NotchRootView.chipCrossfade(opening: true, reduceMotion: false)
                == NotchMotion.chipsYield(reduceMotion: false))
        #expect(NotchRootView.chipCrossfade(opening: true, reduceMotion: true)
                == Animation.linear(duration: 0.01))
    }

    /// Records every value SwiftUI renders an animated progress at.
    private struct ProgressProbe: ViewModifier, Animatable {
        let log: ProbeLog
        var progress: CGFloat
        var changesOpacity = true
        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }
        func body(content: Content) -> some View {
            log.samples.append(progress)
            return content.opacity(changesOpacity ? Double(progress) : 1)
        }
    }

    private final class ProbeLog { var samples: [CGFloat] = [] }
    private final class HoverModel: ObservableObject {
        @Published var progress: CGFloat = 1
        @Published var isExpanded = true
        @Published var isCollapsing = false
    }

    private struct ChipReturnHarness: View {
        @ObservedObject var model: HoverModel
        let geometry: ProbeLog
        let reduceMotion: Bool
        var body: some View {
            Color.black
                .overlay {
                    if model.isExpanded || model.isCollapsing {
                        Color(red: 0, green: 1, blue: 0)
                            .modifier(SurfaceReveal(progress: model.progress))
                            .transition(.identity)
                    } else {
                        Color(red: 1, green: 0, blue: 0)
                            .transition(NotchRootView.chipTransition(reduceMotion: reduceMotion))
                    }
                }
                .modifier(ProgressProbe(log: geometry, progress: model.progress, changesOpacity: false))
                .modifier(HoverTransactions(progress: model.progress,
                                            isExpanded: model.isExpanded,
                                            surface: NotchMotion.surface(reduceMotion: reduceMotion),
                                            crossfade: NotchRootView.chipCrossfade(
                                                opening: model.isExpanded, reduceMotion: reduceMotion)))
                .frame(width: 40, height: 40)
        }
    }

    @MainActor
    @Test("collapse completion restores only chips with the configured return curve",
          arguments: [false, true])
    func chipsFadeAfterFinalisation(reduceMotion: Bool) async throws {
        let model = HoverModel()
        model.isExpanded = false
        model.progress = 0
        let geometry = ProbeLog()
        let host = NSHostingView(rootView: ChipReturnHarness(model: model, geometry: geometry,
                                                            reduceMotion: reduceMotion))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        func pixel() throws -> NSColor {
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
            return try #require(color?.usingColorSpace(.sRGB))
        }
        // Older SwiftUI versions animate the initial insertion as well.
        // A 100ms capture can sample the 140ms fade rather than opaque chips.
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Window captures are color managed. Compare to steady-state captures
        // from this same host rather than assuming pure device RGB channels.
        let opaqueChips = try pixel()
        model.isExpanded = true
        model.progress = 1
        try await Task.sleep(for: .seconds(NotchMotion.surfaceSettleDuration + 0.1))
        let opaqueCard = try pixel()
        model.isExpanded = false
        model.isCollapsing = true
        model.progress = 0
        try await Task.sleep(for: .seconds(NotchMotion.surfaceSettleDuration + 0.1))
        let hidden = try pixel()
        #expect(hidden.redComponent < 0.01)
        #expect(hidden.greenComponent < 0.01)
        geometry.samples.removeAll()
        model.isCollapsing = false // Only this flag changes at setExpanded's delayed completion.
        var reds: [CGFloat] = []
        for _ in 0..<22 {
            try await Task.sleep(for: .milliseconds(10))
            let color = try pixel()
            reds.append(color.redComponent / opaqueChips.redComponent)
        }
        let expectedReturnAnimation = reduceMotion
            ? Animation.linear(duration: 0.01) : Animation.easeIn(duration: 0.14)
        #expect(NotchMotion.chipsReturn(reduceMotion: reduceMotion) == expectedReturnAnimation)
        // cacheDisplay captures AppKit's model bitmap, not guaranteed
        // Core Animation presentation frames. Do not infer animation timing
        // from that bitmap; its final state remains a useful rendering check.
        let returned = try pixel()
        #expect(abs(returned.redComponent - opaqueChips.redComponent) < 0.01,
                "returned red \(returned.redComponent), baseline \(opaqueChips.redComponent), samples \(reds)")
        #expect(abs(returned.greenComponent - opaqueChips.greenComponent) < 0.01)
        #expect(geometry.samples.allSatisfy { $0 == 0 }, "finalisation restarted the surface motion")
        #expect(geometry.samples.allSatisfy { NotchMotion.contentOpacity(surfaceProgress: $0) == 0 },
                "the expanded card overlapped returning chips")
        // Re-enter while the insertion fade is running: the normal opening
        // handoff must still remove chips without a delayed return later.
        model.isCollapsing = true
        try await Task.sleep(for: .milliseconds(50))
        model.isCollapsing = false
        try await Task.sleep(for: .milliseconds(30))
        model.isExpanded = true
        model.progress = 1
        try await Task.sleep(for: .seconds(NotchMotion.surfaceSettleDuration + 0.1))
        let reopened = try pixel()
        #expect(abs(reopened.redComponent - opaqueCard.redComponent) < 0.01)
        #expect(abs(reopened.greenComponent - opaqueCard.greenComponent) < 0.01)
    }

    private struct HoverHarness: View {
        @ObservedObject var model: HoverModel
        let reference: ProbeLog
        let layered: ProbeLog
        var body: some View {
            HStack {
                Color.black.frame(width: 20, height: 20)
                    .modifier(ProgressProbe(log: reference, progress: model.progress))
                    .animation(NotchMotion.surface(reduceMotion: false), value: model.progress)
                Color.black.frame(width: 20, height: 20)
                    .modifier(ProgressProbe(log: layered, progress: model.progress))
                    .modifier(HoverTransactions(progress: model.progress,
                                                isExpanded: model.isExpanded,
                                                surface: NotchMotion.surface(reduceMotion: false),
                                                crossfade: .easeIn(duration: 0.14)))
            }
        }
    }

    @MainActor
    @Test("a collapse animates on the surface spring even though the cross-fade flag flips with it")
    func collapseKeepsTheSurfaceSpring() async throws {
        // `setExpanded(false)` flips `isExpanded` and `expansionProgress` in one
        // transaction. If the cross-fade won, the surface would shrink on a
        // 0.14s ease-in and the spring would only ever drive the opening.
        let model = HoverModel()
        let reference = ProbeLog()
        let layered = ProbeLog()
        let host = NSHostingView(rootView: HoverHarness(model: model, reference: reference, layered: layered))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 80, height: 40),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        reference.samples.removeAll()
        layered.samples.removeAll()
        model.isExpanded = false
        model.progress = 0
        try await Task.sleep(for: .seconds(NotchMotion.surfaceSettleDuration + 0.1))
        let inFlight = reference.samples.filter { $0 > 0.001 && $0 < 0.999 }
        try #require(inFlight.count >= 3, "the animation never ticked, so nothing was compared")
        #expect(layered.samples.count == reference.samples.count)
        for (a, b) in zip(layered.samples, reference.samples) {
            #expect(abs(a - b) < 0.0001)
        }
    }

    @Test("content is hidden while the surface is still narrow and full once it is open")
    func revealEnds() {
        #expect(NotchMotion.contentOpacity(surfaceProgress: 0) == 0)
        #expect(NotchMotion.contentOpacity(surfaceProgress: NotchMotion.revealStart) == 0)
        #expect(NotchMotion.contentOpacity(surfaceProgress: NotchMotion.revealEnd) == 1)
        #expect(NotchMotion.contentOpacity(surfaceProgress: 1) == 1)
        // Defensive: a retargeted spring can be sampled a hair outside 0...1.
        #expect(NotchMotion.contentOpacity(surfaceProgress: -0.1) == 0)
        #expect(NotchMotion.contentOpacity(surfaceProgress: 1.1) == 1)
    }

    @Test("content opacity is a monotonic function of surface progress alone")
    func revealIsMonotonic() {
        // A function of progress only has no direction: a reversal mid-flight
        // walks back along the same curve instead of restarting a delayed fade.
        var previous = 0.0
        for step in 0...100 {
            let value = NotchMotion.contentOpacity(surfaceProgress: CGFloat(step) / 100)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("Reduce Motion keeps the shared floor for the surface")
    func surfaceReduceMotion() {
        #expect(NotchMotion.surface(reduceMotion: true) == Animation.linear(duration: 0.01))
        #expect(NotchMotion.surface(reduceMotion: false) != Animation.linear(duration: 0.01))
    }
}

@Suite("Notch token scales")
struct NotchTokenScaleTests {
    @Test("no scale contains a duplicate value")
    func noDuplicates() {
        // Two names for one number is how a scale rots: the next person picks
        // whichever reads better and the two drift apart at the first edit.
        #expect(Set(NotchSpace.all).count == NotchSpace.all.count)
        #expect(Set(NotchType.all).count == NotchType.all.count)
        #expect(Set(NotchOpacity.all).count == NotchOpacity.all.count)
    }

    @Test("spacing steps ascend")
    func spacingAscends() {
        let steps: [CGFloat] = [NotchSpace.tight, NotchSpace.snug,
                                NotchSpace.base, NotchSpace.roomy, NotchSpace.section]
        #expect(steps == steps.sorted())
    }

    @Test("type roles descend from display to caption")
    func typeDescends() {
        #expect(NotchType.hero > NotchType.display)
        #expect(NotchType.display > NotchType.title)
        #expect(NotchType.title > NotchType.body)
        #expect(NotchType.body > NotchType.caption)
    }

    /// Arrival motion has to stay under the threshold where it reads as
    /// choreography: three staggered tiles inside a fifth of a second, a rise
    /// no bigger than a snug gap, a swell you notice but that does not move
    /// the neighbouring tile.
    @Test("arrival motion is felt, not watched")
    func motionStaysSmall() {
        #expect(NotchMotion.stagger * 3 < 0.2)
        #expect(NotchMotion.rise <= NotchSpace.snug)
        #expect(NotchMotion.bump > 1)
        #expect((NotchMotion.bump - 1) * NotchSpace.tile < NotchSpace.base)
        // Press is the mirror of bump: the same distance the other way.
        #expect(NotchMotion.press < 1)
        #expect(abs((1 - NotchMotion.press) - (NotchMotion.bump - 1)) < 0.0001)
        // Page and paint travel less than a snug gap / a few percent of size.
        #expect(NotchMotion.pageScale > NotchMotion.press)
        #expect(NotchMotion.pageScale < 1)
        #expect(NotchMotion.paintScale > NotchMotion.press)
        #expect(NotchMotion.paintScale < NotchMotion.pageScale)
    }

    /// The header mark is a glyph's backing, not a tap target: it must sit
    /// inside a title line, and the bar must be visible on a tile.
    @Test("the header mark fits a title line and the bar is no hairline")
    func markAndBar() {
        #expect(NotchSpace.mark < NotchSpace.well)
        #expect(NotchSpace.mark > NotchType.title)
        #expect(NotchSpace.bar > NotchSpace.snug)
        #expect(NotchSpace.bar < NotchSpace.base)
    }

    @Test("opacity roles descend from primary to hairline")
    func opacityDescends() {
        #expect(NotchOpacity.primary > NotchOpacity.secondary)
        #expect(NotchOpacity.secondary > NotchOpacity.tertiary)
        #expect(NotchOpacity.tertiary > NotchOpacity.hairline)
    }

    @Test("the gutter clears the status dot")
    func gutterClearsDot() {
        // The dot is 5pt. A gutter narrower than the thing it holds would put
        // the text lines' shared left edge inside the dot.
        #expect(NotchSpace.gutter > 5)
    }

    @Test("radius roles are distinct and the tile is rounder than its well")
    func radii() {
        #expect(Set(NotchRadius.all).count == NotchRadius.all.count)
        #expect(NotchRadius.tile > NotchRadius.card)
        #expect(NotchRadius.tile >= 16)
        #expect(NotchRadius.card > NotchRadius.well)
    }

    @Test("chrome opacities sit between hairline and tertiary")
    func chromeOpacities() {
        // A well fill brighter than a separator would make every tile a box
        // again; a rim brighter than tertiary text would outrank the copy.
        #expect(NotchOpacity.wellFill < NotchOpacity.hairline)
        #expect(NotchOpacity.hairline < NotchOpacity.highlight)
        #expect(NotchOpacity.highlight < NotchOpacity.rim)
        #expect(NotchOpacity.rim < NotchOpacity.tertiary)
        // The band is the one surface meant to be louder than text on it is
        // not — but it still yields to the primary copy beside it.
        // The glow must stay under the text it sits behind, and over a mere
        // highlight, or it is either a wash or invisible.
        #expect(NotchOpacity.glow < NotchOpacity.secondary)
        #expect(NotchOpacity.glow > NotchOpacity.highlight)
        #expect(NotchOpacity.band > NotchOpacity.secondary)
        #expect(NotchOpacity.band < NotchOpacity.primary)
        // The badge darkens the band without hiding it.
        #expect(NotchOpacity.badge > NotchOpacity.rim)
        #expect(NotchOpacity.badge < NotchOpacity.secondary)
    }

    @Test("a tile is wide enough for its well and padding")
    func tileHoldsWell() {
        #expect(NotchSpace.hero > NotchSpace.well)
        #expect(NotchSpace.hero < NotchSpace.tile)
        #expect(NotchSpace.tile > NotchSpace.well + NotchSpace.base * 2)
        #expect(NotchSpace.all.contains(NotchSpace.well))
        #expect(NotchSpace.all.contains(NotchSpace.tile))
    }
}

@Suite("AgentRowMetadata")
struct AgentRowMetadataTests {
    private func session(startedAt: Date? = nil,
                         contextTokens: Int? = nil,
                         model: String? = nil,
                         effort: String? = nil,
                         permissionMode: String? = nil) -> AgentSession {
        var s = AgentSession(id: "s", agent: "claude-code", project: "NotchPill",
                             state: .working, lastActivity: Date())
        s.startedAt = startedAt
        s.contextTokens = contextTokens
        s.model = model
        s.effort = effort
        s.permissionMode = permissionMode
        return s
    }

    @Test("a bare session has no metadata line")
    func empty() {
        let meta = AgentRowMetadata(session())
        #expect(meta.text == nil)
        #expect(meta.badge == nil)
        #expect(meta.isContextTight == false)
    }

    @Test("facts join in a fixed order")
    func ordering() throws {
        // Runtime first because it is true of every session; effort last
        // because it modifies the model beside it. A stable order is what lets
        // the eye skip the line entirely on rows it does not care about.
        let meta = AgentRowMetadata(session(startedAt: Date().addingTimeInterval(-3600),
                                            contextTokens: 20_000,
                                            model: "claude-opus-5",
                                            effort: "low"))
        let text = try #require(meta.text)
        let runtimeIndex = try #require(text.range(of: "running"))
        let contextIndex = try #require(text.range(of: "ctx"))
        let modelIndex = try #require(text.range(of: "Opus"))
        let effortIndex = try #require(text.range(of: "low"))
        #expect(runtimeIndex.lowerBound < contextIndex.lowerBound)
        #expect(contextIndex.lowerBound < modelIndex.lowerBound)
        #expect(modelIndex.lowerBound < effortIndex.lowerBound)
    }

    @Test("a tight context is flagged")
    func tightContext() {
        // 180k of a 200k window is 90%.
        let meta = AgentRowMetadata(session(contextTokens: 180_000, model: "claude-opus-5"))
        #expect(meta.isContextTight == true)
    }

    @Test("a roomy context is not flagged")
    func roomyContext() {
        let meta = AgentRowMetadata(session(contextTokens: 20_000, model: "claude-opus-5"))
        #expect(meta.isContextTight == false)
    }

    @Test("default permission mode draws no badge")
    func defaultPermission() {
        // Everyone already assumes the agent asks. A badge on every row would
        // teach the eye to skip the badge.
        #expect(AgentRowMetadata(session(permissionMode: "default")).badge == nil)
        #expect(AgentRowMetadata(session(permissionMode: nil)).badge == nil)
    }

    @Test("unsupervised modes badge as warnings, plan does not")
    func permissionWarning() {
        let bypass = AgentRowMetadata(session(permissionMode: "bypassPermissions"))
        #expect(bypass.badge == "bypass")
        #expect(bypass.badgeIsWarning == true)

        let plan = AgentRowMetadata(session(permissionMode: "plan"))
        #expect(plan.badge == "plan")
        #expect(plan.badgeIsWarning == false)
    }
}

@Suite("Agent tile marks")
struct AgentTileMarkTests {
    private func session(_ agent: String) -> AgentSession {
        AgentSession(id: agent, agent: agent, project: "p", state: .working, lastActivity: Date())
    }

    @Test("each known agent names the app whose icon can stand for it")
    func iconCandidates() {
        #expect(session("cursor").iconBundleIds == ["com.todesktop.230313mzl4w4u92"])
        #expect(session("claude-code").iconBundleIds.first == "com.anthropic.claudefordesktop")
        #expect(session("codex").iconBundleIds.contains("com.openai.chat"))
    }

    @Test("an agent with no app, or no known agent, offers no icon")
    func noApp() {
        #expect(session("opencode").iconBundleIds.isEmpty)
        #expect(session("opencode").appIcon == nil)
        #expect(session("something-else").iconBundleIds.isEmpty)
        #expect(session("something-else").appIcon == nil)
    }

    @Test("a missing app is a cached miss, not a repeated search")
    func cachesMisses() {
        let cache = AppIconCache()
        #expect(cache.icon(bundleId: "com.example.not-installed-\(UUID().uuidString)") == nil)
        #expect(cache.icon(forAnyOf: ["com.example.nope", "com.example.also-nope"]) == nil)
    }

    @Test("the first installed candidate wins")
    func firstInstalledWins() {
        // Finder is always present; a bogus id ahead of it must not hide it.
        let cache = AppIconCache()
        #expect(cache.icon(forAnyOf: ["com.example.nope", "com.apple.finder"]) != nil)
    }
}

@Suite("AgentShelf")
struct AgentShelfTests {
    private func session(_ id: String, _ state: AgentSession.State) -> AgentSession {
        AgentSession(id: id, agent: "claude-code", project: "p", state: state,
                     lastActivity: Date())
    }

    @Test("an empty shelf has no caption and nowhere to jump")
    func empty() {
        let shelf = AgentShelf([])
        #expect(shelf.caption == nil)
        #expect(shelf.jumpTarget == nil)
    }

    @Test("the caption counts states in a fixed order")
    func caption() {
        // Needs-you first because it is the one you act on; completed last
        // because it is history.
        let shelf = AgentShelf([session("a", .completed(since: Date())),
                                session("b", .idle(since: Date())),
                                session("c", .working),
                                session("d", .waiting(since: nil)),
                                session("e", .working)])
        #expect(shelf.caption == "1 needs you · 2 working · 1 idle · 1 completed")
    }

    @Test("the jump well prefers waiting, then working, then whatever is first")
    func jumpTarget() {
        // One well, so it has to pick. The session blocked on you is the only
        // one that gets worse the longer you take.
        let idle = session("i", .idle(since: Date()))
        let working = session("w", .working)
        let waiting = session("x", .waiting(since: nil))
        #expect(AgentShelf([idle, working, waiting]).jumpTarget?.id == "x")
        #expect(AgentShelf([idle, working]).jumpTarget?.id == "w")
        #expect(AgentShelf([idle]).jumpTarget?.id == "i")
    }
}

@Suite("Fetch Question Parser Tests")
struct FetchQuestionParserTests {
    @Test("parses multi-choice numbered question matching Fetch f140")
    func parsesNumberedChoices() {
        let text = """
        Which approach should we take for the caching layer?
        1. In-memory LRU cache (Recommended)
           Fastest read latency, resets on restart
        2. Redis-backed cache
           Shared across worker nodes
        3. SQLite on disk
           Persistent, slightly higher latency
        """
        let alert = DevReadyAlert(
            title: "demo",
            bundleId: "com.apple.Terminal",
            kind: .waiting,
            message: text,
            deliverySpec: "decision",
            requestId: "req-1"
        )
        let parsed = QuestionParser.parse(alert: alert)
        #expect(parsed != nil)
        guard let p = parsed else { return }
        #expect(p.headline == "Which approach should we take for the caching layer?")
        #expect(p.options.count == 3)
        #expect(p.options[0].keycap == "1")
        #expect(p.options[0].label == "In-memory LRU cache")
        #expect(p.options[0].isRecommended == true)
        #expect(p.options[0].description == "Fastest read latency, resets on restart")

        #expect(p.options[1].keycap == "2")
        #expect(p.options[1].label == "Redis-backed cache")
        #expect(p.options[1].isRecommended == false)
        #expect(p.options[1].description == "Shared across worker nodes")

        #expect(p.options[2].keycap == "3")
        #expect(p.options[2].label == "SQLite on disk")
        #expect(p.options[2].isRecommended == false)
        #expect(p.options[2].description == "Persistent, slightly higher latency")
        #expect(p.hasOther == true)
    }

    @Test("parses permission plans into Approve and Revise")
    func parsesPermissionPlan() {
        let alert = DevReadyAlert(
            title: "demo",
            bundleId: "com.apple.Terminal",
            kind: .waiting,
            message: "Review execution plan",
            deliverySpec: "decision",
            requestId: "req-2",
            permissionPayload: #"{"tool_name":"ExitPlanMode","tool_input":{"plan":"1. Update database\n2. Migrate assets"}}"#
        )
        let parsed = QuestionParser.parse(alert: alert)
        #expect(parsed != nil)
        guard let p = parsed else { return }
        #expect(p.options.count == 2)
        #expect(p.options[0].label == "Approve")
        #expect(p.options[0].keycap == "1")
        #expect(p.options[1].label == "Revise")
        #expect(p.options[1].keycap == "2")
    }

    @Test("parses permission action into Allow and Deny")
    func parsesPermissionAction() {
        let alert = DevReadyAlert(
            title: "demo",
            bundleId: "com.apple.Terminal",
            kind: .waiting,
            message: "Allow terminal execution",
            deliverySpec: "decision",
            requestId: "req-3",
            permissionPayload: #"{"tool_name":"Bash","tool_input":{"command":"rm -rf /tmp/cache"}}"#
        )
        let parsed = QuestionParser.parse(alert: alert)
        #expect(parsed != nil)
        guard let p = parsed else { return }
        #expect(p.options.count == 2)
        #expect(p.options[0].label == "Allow")
        #expect(p.options[0].keycap == "1")
        #expect(p.options[1].label == "Deny")
        #expect(p.options[1].keycap == "2")
    }

    @Test("vendorDisplayName maps known agent binaries")
    func vendorDisplayNames() {
        let claude = AgentSession(id: "1", agent: "claude-code", project: "proj", state: .working, lastActivity: Date())
        #expect(claude.vendorDisplayName == "Claude Code")

        let codex = AgentSession(id: "2", agent: "codex", project: "proj", state: .working, lastActivity: Date())
        #expect(codex.vendorDisplayName == "Codex")

        let cursor = AgentSession(id: "3", agent: "cursor", project: "proj", state: .working, lastActivity: Date())
        #expect(cursor.vendorDisplayName == "Cursor")

        let opencode = AgentSession(id: "4", agent: "opencode", project: "proj", state: .working, lastActivity: Date())
        #expect(opencode.vendorDisplayName == "OpenCode")
    }

    @Test("glanceSecondaryText reflects state and file context")
    func glanceSecondaryTexts() {
        let waiting = AgentSession(id: "1", agent: "claude-code", project: "proj", state: .waiting(since: Date()), lastActivity: Date())
        #expect(waiting.glanceSecondaryText == "Waiting for you")

        var working = AgentSession(id: "2", agent: "claude-code", project: "proj", state: .working, lastActivity: Date())
        working.task = "Refactor models"
        // Task is already the row title; secondary shows project instead.
        #expect(working.glanceSecondaryText == "proj")

        let idle = AgentSession(id: "3", agent: "claude-code", project: "proj", state: .idle(since: Date()), lastActivity: Date())
        #expect(idle.glanceSecondaryText == "proj")
    }

    @Test("plan Revise is a composer, not a verdict keystroke")
    func planReviseOpensComposer() throws {
        let alert = DevReadyAlert(
            title: "demo",
            bundleId: "com.apple.Terminal",
            kind: .waiting,
            message: "Review execution plan",
            deliverySpec: "decision",
            requestId: "req-2",
            permissionPayload: #"{"tool_name":"ExitPlanMode","tool_input":{"plan":"1. Update database\n2. Migrate assets"}}"#
        )
        let parsed = try #require(QuestionParser.parse(alert: alert))
        #expect(parsed.options[0].opensPlanRevision == false)
        #expect(parsed.options[1].opensPlanRevision == true)
        #expect(PermissionDecision.Verdict(parsed.options[1].keystroke) == .ask)
    }
}

@MainActor
@Suite("Fetch Question Answerability Tests")
struct FetchQuestionAnswerabilityTests {
    private func numberedWaitingAlert(bundleId: String?) -> DevReadyAlert {
        DevReadyAlert(
            title: "demo",
            agent: "claude-code",
            bundleId: bundleId,
            kind: .waiting,
            message: """
            Which approach should we take for the caching layer?
            1. In-memory LRU cache (Recommended)
               Fastest read latency, resets on restart
            2. Redis-backed cache
               Shared across worker nodes
            3. SQLite on disk
               Persistent, slightly higher latency
            """
        )
    }

    @Test("numbered AskUser menus are answerable when a terminal can be targeted")
    func numberedMenuIsAnswerable() {
        let targeted = numberedWaitingAlert(bundleId: "com.apple.Terminal")
        #expect(targeted.canAnswerFromNotch(replyEnabled: true))
        #expect(!numberedWaitingAlert(bundleId: nil).canAnswerFromNotch(replyEnabled: true))
        #expect(!targeted.canAnswerFromNotch(replyEnabled: false))
    }

    @Test("waiting height budgets Fetch option rows, not the old capsules")
    func numberedMenuHeightMatchesRows() throws {
        let alert = numberedWaitingAlert(bundleId: "com.apple.Terminal")
        let parsed = try #require(QuestionParser.parse(alert: alert))
        let extra = NotchContentLayout.waitingExtraHeight(alerts: [alert], answerEnabled: true)
        let expected = 6
            + NotchContentLayout.fetchQuestionHeadlineHeight
            + NotchContentLayout.fetchOptionsHeight(parsed, includeOther: true)
        #expect(extra == expected)
        #expect(extra > WaitingLayoutTests.withButtonsExtra)
    }
}

// MARK: - Silhouette geometry

/// Flattens a `Path` into polylines so tests can reason about tangents and
/// extents without depending on how the shape builds its curves.
private func flattened(_ path: Path, stepsPerCurve: Int = 160) -> [CGPoint] {
    var points: [CGPoint] = []
    var current = CGPoint.zero
    path.forEach { element in
        switch element {
        case .move(let p), .line(let p):
            points.append(p); current = p
        case .quadCurve(let p, let c):
            for i in 1...stepsPerCurve {
                let t: CGFloat = CGFloat(i) / CGFloat(stepsPerCurve)
                let u: CGFloat = 1 - t
                let a: CGFloat = u * u
                let b: CGFloat = 2 * u * t
                let d: CGFloat = t * t
                let x: CGFloat = a * current.x + b * c.x + d * p.x
                let y: CGFloat = a * current.y + b * c.y + d * p.y
                points.append(CGPoint(x: x, y: y))
            }
            current = p
        case .curve(let p, let c1, let c2):
            for i in 1...stepsPerCurve {
                let t: CGFloat = CGFloat(i) / CGFloat(stepsPerCurve)
                let u: CGFloat = 1 - t
                let a: CGFloat = u * u * u
                let b: CGFloat = 3 * u * u * t
                let c: CGFloat = 3 * u * t * t
                let d: CGFloat = t * t * t
                let x: CGFloat = a * current.x + b * c1.x + c * c2.x + d * p.x
                let y: CGFloat = a * current.y + b * c1.y + c * c2.y + d * p.y
                points.append(CGPoint(x: x, y: y))
            }
            current = p
        case .closeSubpath:
            break
        }
    }
    return points
}

/// Largest direction change between consecutive segments, ignoring vertices
/// at `skipY` (the deliberately square corners where the surface meets the
/// hardware notch's lower edge).
private func sharpestTurn(_ points: [CGPoint], skipY: CGFloat) -> CGFloat {
    var worst: CGFloat = 0
    let n = points.count
    guard n > 2 else { return 0 }
    for i in 0..<n {
        let a = points[(i + n - 1) % n], b = points[i], c = points[(i + 1) % n]
        if abs(b.y - skipY) < 0.001 { continue }
        let v1 = CGVector(dx: b.x - a.x, dy: b.y - a.y)
        let v2 = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let l1 = hypot(v1.dx, v1.dy), l2 = hypot(v2.dx, v2.dy)
        guard l1 > 1e-6, l2 > 1e-6 else { continue }
        let cosine = max(-1, min(1, (v1.dx * v2.dx + v1.dy * v2.dy) / (l1 * l2)))
        worst = max(worst, acos(cosine))
    }
    return worst
}

@Suite("Notch silhouette geometry")
struct NotchSilhouetteGeometryTests {
    private let rect = CGRect(x: 0, y: 0, width: 400, height: 220)
    private let notchWidth: CGFloat = 180
    private let notchHeight: CGFloat = 32

    private func expanded(_ progress: CGFloat, hasNotch: Bool = true) -> ExpandedNotchShape {
        ExpandedNotchShape(notchWidth: notchWidth, notchHeight: notchHeight,
                           bottomRadius: 22, progress: progress, hasPhysicalNotch: hasNotch)
    }

    @Test("the expanded path never paints above the hardware notch's lower edge")
    func neverAboveHardwareBottom() {
        for step in 1...40 {
            let path = expanded(CGFloat(step) / 40).path(in: rect)
            if path.isEmpty { continue }
            #expect(path.boundingRect.minY >= notchHeight - 0.001)
            #expect(rect.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingRect))
            for p in flattened(path) { #expect(p.y >= notchHeight - 0.001) }
        }
    }

    @Test("progress zero draws nothing")
    func zeroProgressIsEmpty() {
        #expect(expanded(0).path(in: rect).isEmpty)
    }

    @Test("shoulders and corners turn smoothly at every progress")
    func shouldersAreTangentContinuous() {
        for step in 1...50 {
            let path = expanded(CGFloat(step) / 50).path(in: rect)
            if path.isEmpty { continue }
            // 160 samples per curve: a tangent-continuous curve turns a few
            // degrees per sample; a kink where a curve meets a straight edge
            // turns tens of degrees in one.
            let turn = sharpestTurn(flattened(path), skipY: notchHeight)
            #expect(turn < 0.2, "kink of \(turn) rad at progress \(Double(step) / 50)")
        }
    }

    @Test("the bottom corners are continuous-curvature, wider than a circular arc")
    func bottomCornersAreContinuous() {
        let path = expanded(1).path(in: rect)
        let bottom = notchHeight + (rect.height - notchHeight)
        let onBottom = flattened(path).filter { abs($0.y - bottom) < 0.001 }
        let rightmost = onBottom.map(\.x).max() ?? rect.maxX
        // A circular arc of radius 22 leaves the bottom edge exactly 22 from
        // the side; a squircle starts bending farther out.
        #expect(rightmost < rect.maxX - 22 * 1.1)
    }

    @Test("the free-floating pill keeps its bounds and gap")
    func freeFloatingBounds() {
        let path = expanded(1, hasNotch: false).path(in: rect)
        #expect(abs(path.boundingRect.minY - (notchHeight + 4)) < 0.001)
        #expect(abs(path.boundingRect.maxY - rect.maxY) < 0.001)
        #expect(abs(path.boundingRect.width - rect.width) < 0.001)
    }

    @Test("Wave1's ledge requires more clearance than the current tray header inset")
    func wave1HeaderClearance() {
        // A non-media tray starts at notchHeight + 4 + NotchSpace.base,
        // x=NotchSpace.section (ExpandedView.activityCard). The shoulder's
        // flat ledge is notchHeight + 3 + shoulderReach, five points lower.
        // Wiring this into the root unchanged clips real headers at x=20.
        let shape = expanded(1).path(in: rect)
        let header = CGPoint(x: NotchSpace.section,
                             y: notchHeight + 4 + NotchSpace.base)
        #expect(NotchShape(bottomRadius: 22).path(in: rect).contains(header))
        #expect(!shape.contains(header))
        #expect(shape.contains(CGPoint(x: header.x,
                                       y: notchHeight + 3 + ExpandedNotchShape.shoulderReach + 0.5)))
    }

    @Test("NotchShape stays inside its rect with square top corners")
    func notchShapeBounds() {
        let path = NotchShape(bottomRadius: 22).path(in: rect)
        #expect(path.boundingRect == rect)
        #expect(path.contains(CGPoint(x: 1, y: 1)))
        let turn = sharpestTurn(flattened(path), skipY: 0)
        #expect(turn < 0.2)
    }

    @Test("an inset shape stays inside the original and never rises above the seam")
    func insetStaysInside() {
        let full = expanded(1)
        let inner = full.inset(by: 0.25).path(in: rect)
        #expect(full.path(in: rect).boundingRect.insetBy(dx: -0.001, dy: -0.001).contains(inner.boundingRect))
        #expect(inner.boundingRect.minY >= notchHeight)
        let notchShape = NotchShape(bottomRadius: 22).inset(by: 0.25).path(in: rect)
        #expect(rect.contains(notchShape.boundingRect))
    }

    /// `strokeBorder` draws on `inset(by: lineWidth / 2)`, so this is the line
    /// staying on the fill rather than spilling onto the wallpaper. It held at
    /// full expansion but not below half: the body height was scaled from the
    /// already-inset rect, so the inset outline's bottom sat *below* the fill.
    @Test("an inset outline stays inside the fill at every progress")
    func insetStaysInsideWhileGrowing() {
        for hasNotch in [true, false] {
            for step in 1...40 {
                let shape = expanded(CGFloat(step) / 40, hasNotch: hasNotch)
                let outer = shape.path(in: rect)
                let inner = shape.inset(by: 0.25).path(in: rect)
                if outer.isEmpty { continue }
                let o = outer.boundingRect, i = inner.boundingRect
                if inner.isEmpty { continue }
                #expect(i.minX >= o.minX + 0.25 - 0.001, "left at \(step)/40 notch=\(hasNotch)")
                #expect(i.maxX <= o.maxX - 0.25 + 0.001, "right at \(step)/40 notch=\(hasNotch)")
                #expect(i.maxY <= o.maxY - 0.25 + 0.001, "bottom at \(step)/40 notch=\(hasNotch)")
                #expect(i.minY >= o.minY + 0.25 - 0.001, "top at \(step)/40 notch=\(hasNotch)")
            }
        }
    }

    @Test("degenerate sizes stay finite and inside the rect")
    func degenerateInputs() {
        let cases: [(ExpandedNotchShape, CGRect)] = [
            // Notch wider than the frame: no flare, no shoulders.
            (ExpandedNotchShape(notchWidth: 500, notchHeight: 32, progress: 1), rect),
            // Barely taller than the notch.
            (ExpandedNotchShape(notchWidth: 180, notchHeight: 32, progress: 1),
             CGRect(x: 0, y: 0, width: 400, height: 34)),
            // Radius far larger than the room for it.
            (ExpandedNotchShape(notchWidth: 20, notchHeight: 8, bottomRadius: 400, progress: 0.6),
             CGRect(x: 0, y: 0, width: 30, height: 20)),
        ]
        for (shape, frame) in cases {
            for path in [shape.path(in: frame), shape.inset(by: 0.25).path(in: frame)] where !path.isEmpty {
                let points = flattened(path)
                #expect(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
                #expect(frame.insetBy(dx: -0.001, dy: -0.001).contains(path.boundingRect))
                #expect(path.boundingRect.minY >= shape.notchHeight - 0.001)
            }
        }
    }

    // MARK: Rendered rim

    /// Renders `view` at 4x on a transparent canvas and returns a sampler of
    /// premultiplied RGBA at a point-space location.
    @MainActor
    private func render<V: View>(_ view: V, size: CGSize) throws -> (CGFloat, CGFloat) -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 4
        let image = try #require(renderer.cgImage)
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let context = try #require(CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return { x, y in
            // The buffer's first row is the image's top row, as in SwiftUI.
            let px = min(w - 1, max(0, Int(x * 4))), py = min(h - 1, max(0, Int(y * 4)))
            let o = (py * w + px) * 4
            return Array(pixels[o..<o + 4])
        }
    }

    @MainActor
    @Test("the rim is invisible at the notch seam and visible along the bottom")
    func rimFadesAtSeam() throws {
        let size = CGSize(width: rect.width, height: rect.height)
        let sample = try render(ExpandedPillSurface(notchWidth: notchWidth, notchHeight: notchHeight,
                                                    progress: 1), size: size)
        // First device row of the neck's top edge, mid-notch: pure black fill.
        let seam = sample(size.width / 2, notchHeight + 0.1)
        #expect(seam[3] == 255)
        #expect(seam[0] == 0 && seam[1] == 0 && seam[2] == 0, "seam pixel \(seam)")
        // Last device row, mid-pill: the rim, lighter than the fill.
        let bottom = sample(size.width / 2, size.height - 0.1)
        #expect(bottom[0] > 0, "bottom pixel \(bottom)")
    }

    /// The root view used to stroke a second, straddling rim over the media
    /// artwork. The surface now takes the artwork itself and keeps its one
    /// inside rim on top of it.
    @MainActor
    @Test("the pill's rim is drawn over its backdrop")
    func rimSitsOverBackdrop() throws {
        let size = CGSize(width: 300, height: 120)
        let sample = try render(PillSurface(bottomRadius: 22) { Color(red: 1, green: 0, blue: 0) },
                                size: size)
        let middle = sample(150, 60)
        #expect(middle[0] == 255 && middle[1] == 0, "backdrop pixel \(middle)")
        let bottom = sample(150, size.height - 0.1)
        #expect(bottom[1] > 0, "rim missing over the backdrop: \(bottom)")
        // Square top on notched hardware is the seam: no rim there either.
        let top = sample(150, 0.1)
        #expect(top[1] == 0, "rim at the seam: \(top)")
    }

    @MainActor
    @Test("Wave1 artwork respects transparent hardware flanks and has one rim above its backdrop")
    func expandedArtworkRespectsSilhouette() throws {
        let size = CGSize(width: rect.width, height: rect.height)
        let sample = try render(ExpandedPillSurface(notchWidth: notchWidth, notchHeight: notchHeight,
                                                    progress: 1) { Color(red: 1, green: 0, blue: 0) }, size: size)
        #expect(sample(10, notchHeight - 1)[3] == 0)
        #expect(sample(10, notchHeight + 5)[3] == 0)
        let middle = sample(rect.midX, rect.midY)
        #expect(middle[0] == 255 && middle[1] == 0)
        let seam = sample(rect.midX, notchHeight + 0.1)
        #expect(seam[1] == 0, "the rim must disappear beneath the hardware")
        let bottom = sample(rect.midX, rect.maxY - 0.1)
        #expect(bottom[1] > 0, "the rim must remain above media artwork")
    }
}
