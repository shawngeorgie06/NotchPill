import AppKit
import Combine
import Foundation

/// Joins the shell to the card: bytes in from `PTYSession`, a drawable grid
/// out of `TerminalEmulator`, and keystrokes back the other way.
///
/// The shell is started lazily — the first time the card is actually looked at
/// — because a login shell costs a process and a profile read, and most of the
/// time the card is one of seventeen that never comes up.
@MainActor
final class TerminalStore: ObservableObject {
    static let shared = TerminalStore()

    /// Bumped once per coalesced redraw. This is what is published, not the
    /// grid: `emulator` is mutated on every read from the shell, and a
    /// `@Published` struct would republish the whole card for each 4KB chunk.
    @Published private(set) var revision = 0

    private(set) var emulator = TerminalEmulator(columns: TerminalStore.columns,
                                                 rows: TerminalStore.rows)
    /// True once the shell is up. The card shows a hint until then.
    @Published private(set) var isLive = false
    /// Set when the shell exits, so the card can offer to start another.
    @Published private(set) var exitStatus: Int32?
    /// Whether the card currently owns the keyboard.
    @Published private(set) var isFocused = false

    /// The card's grid. Six rows at 340pt is what the deck can give a card
    /// without pushing the page dots off the bottom of the pill.
    static let columns = 58
    static let rows = 6

    private var session: PTYSession?
    /// Output arrives in bursts; redrawing per chunk would republish the grid
    /// dozens of times for one `ls`. Coalescing to a frame turns that into one
    /// redraw, and a redraw is now confined to the grid view rather than
    /// relaying out the whole overlay, so this can afford to run at display
    /// rate instead of half of it.
    private var pendingRedraw = false
    static let redrawInterval: TimeInterval = 1.0 / 60.0

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard session == nil else { return }
        let session = PTYSession()
        session.onOutput = { [weak self] bytes in
            guard let self else { return }
            self.emulator.feed(bytes)
            self.scheduleRedraw()
        }
        session.onExit = { [weak self] status in
            guard let self else { return }
            self.session = nil
            self.isLive = false
            self.exitStatus = status
            self.revision += 1
        }
        let started = session.start(columns: Self.columns, rows: Self.rows,
                                    directory: Self.startingDirectory())
        guard started else {
            LogStore.log("terminal", "forkpty failed; card stays idle")
            return
        }
        self.session = session
        isLive = true
        exitStatus = nil
    }

    func stop() {
        session?.stop()
        session = nil
        isLive = false
        isFocused = false
        emulator = TerminalEmulator(columns: Self.columns, rows: Self.rows)
        exitStatus = nil
        revision += 1
    }

    /// One frame for the card. Built on demand rather than stored, so the grid
    /// is copied once per layout pass instead of once per read.
    var snapshot: TerminalSnapshot {
        TerminalSnapshot(lines: emulator.screen,
                         cursor: (emulator.cursorRow, emulator.cursorColumn),
                         cursorVisible: emulator.cursorVisible,
                         isFocused: isFocused,
                         isLive: isLive,
                         exitStatus: exitStatus,
                         revision: revision)
    }

    /// Throws the shell away and starts a fresh one.
    func restart() {
        stop()
        start()
    }

    /// Where the shell opens. The frontmost Finder window's folder is the one
    /// people mean far more often than `$HOME`, and falling back to home is
    /// never wrong, just less useful.
    static func startingDirectory() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return AppSettings.shared.terminalDirectory.isEmpty
            ? home : (AppSettings.shared.terminalDirectory as NSString).expandingTildeInPath
    }

    // MARK: - Scrollback

    /// How many lines back the card is looking. Zero is live.
    @Published private(set) var scrollOffset = 0

    var scrollbackDepth: Int { emulator.scrollbackDepth }

    /// Wheel notches and trackpad swipes arrive in wildly different
    /// magnitudes, so deltas accumulate and a line is emitted per step.
    private var scrollAccumulator: CGFloat = 0
    private var scrollMonitor: Any?
    private static let pointsPerLine: CGFloat = 11

    /// A local monitor rather than a view.
    ///
    /// The obvious thing — an `NSView` over the grid overriding `scrollWheel` —
    /// does not work here: the pill's hosting view never hit-tests down to it,
    /// so the event reaches `NotchWindow` and stops. A local monitor sees it
    /// there and can consume it by returning nil, which also keeps the scroll
    /// from leaking through to whatever is behind the overlay.
    ///
    /// Only while the card has focus. Unfocused, the wheel over the pill is
    /// not ours to take.
    private func startScrollMonitor() {
        guard scrollMonitor == nil else { return }
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            LogStore.scroll("monitor saw dy=\(event.scrollingDeltaY) focused=\(self.isFocused) window=\(event.window.map { "\(type(of: $0))" } ?? "nil")")
            guard self.isFocused else { return event }
            self.scrollAccumulator += event.scrollingDeltaY
            let lines = Int((self.scrollAccumulator / Self.pointsPerLine).rounded(.towardZero))
            LogStore.scroll("accumulator=\(self.scrollAccumulator) lines=\(lines) depth=\(self.emulator.scrollbackDepth) alt=\(self.emulator.isAlternateScreen)")
            if lines != 0 {
                self.scrollAccumulator -= CGFloat(lines) * Self.pointsPerLine
                self.scroll(by: lines)
            }
            return nil
        }
        LogStore.scroll("monitor installed")
    }

    private func stopScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollAccumulator = 0
    }

    /// Positive scrolls into history, negative back towards the prompt.
    func scroll(by lines: Int) {
        let next = min(max(scrollOffset + lines, 0), emulator.scrollbackDepth)
        LogStore.scroll("scroll(by: \(lines)) offset \(scrollOffset) -> \(next) (depth \(emulator.scrollbackDepth))")
        guard next != scrollOffset else { return }
        scrollOffset = next
    }

    /// Typing means you want to see what you are typing.
    func scrollToBottom() {
        guard scrollOffset != 0 else { return }
        scrollOffset = 0
    }

    private func scheduleRedraw() {
        guard !pendingRedraw else { return }
        pendingRedraw = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.redrawInterval) { [weak self] in
            guard let self else { return }
            self.pendingRedraw = false
            // Scrollback is capped, so lines fall off the top while the card
            // is looking at them; without this the viewport would drift.
            if self.scrollOffset > self.emulator.scrollbackDepth {
                self.scrollOffset = self.emulator.scrollbackDepth
            }
            self.revision += 1
        }
    }

    // MARK: - Input

    func setFocused(_ focused: Bool) {
        guard isFocused != focused else { return }
        isFocused = focused
        LogStore.scroll("setFocused(\(focused))")
        if focused {
            start()
            startScrollMonitor()
        } else {
            stopScrollMonitor()
            scrollToBottom()
        }
    }

    func send(_ text: String) {
        start()
        scrollToBottom()
        session?.write(text)
    }

    /// Translates a key press into what a terminal would put on the wire.
    /// Returns false when the key is not ours, so the pill can keep its own
    /// shortcuts.
    @discardableResult
    func handle(event: NSEvent) -> Bool {
        guard let bytes = Self.encode(event: event) else { return false }
        if bytes == [0x03] {
            session?.interrupt()
            return true
        }
        send(String(decoding: bytes, as: UTF8.self))
        return true
    }

    func interrupt() { session?.interrupt() }

    /// What a key press looks like on the wire.
    ///
    /// Pure so the arrow keys and the control codes are assertions rather than
    /// something discovered by pressing them and watching. Arrows send the
    /// *cursor* form (`ESC O A`) rather than the ANSI form, because that is
    /// what a shell in application-keypad mode expects for history.
    static func encode(keyCode: UInt16, characters: String,
                       modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        if modifiers.contains(.command) { return nil }

        switch keyCode {
        case 126: return Array("\u{1B}[A".utf8)   // up
        case 125: return Array("\u{1B}[B".utf8)   // down
        case 124: return Array("\u{1B}[C".utf8)   // right
        case 123: return Array("\u{1B}[D".utf8)   // left
        case 115: return Array("\u{1B}[H".utf8)   // home
        case 119: return Array("\u{1B}[F".utf8)   // end
        case 116: return Array("\u{1B}[5~".utf8)  // page up
        case 121: return Array("\u{1B}[6~".utf8)  // page down
        case 117: return Array("\u{1B}[3~".utf8)  // forward delete
        case 51: return [0x7F]                    // delete
        case 36, 76: return [0x0D]                // return, enter
        case 48: return [0x09]                    // tab — completion, not focus
        case 53: return [0x1B]                    // escape
        default: break
        }

        if modifiers.contains(.control) {
            // ⌃A…⌃Z and the handful of punctuation controls.
            guard let scalar = characters.unicodeScalars.first else { return nil }
            let lower = Character(scalar).lowercased().unicodeScalars.first!.value
            if (97...122).contains(lower) { return [UInt8(lower - 96)] }
            switch scalar.value {
            case 0x5B, 0x33: return [0x1B]   // ⌃[ , ⌃3
            case 0x5C: return [0x1C]
            case 0x5D: return [0x1D]
            case 0x20, 0x32: return [0x00]   // ⌃space
            default: return nil
            }
        }

        if modifiers.contains(.option) {
            // Meta is ESC-prefixed, which is what ⌥B / ⌥F word-motion needs.
            guard !characters.isEmpty else { return nil }
            return [0x1B] + Array(characters.utf8)
        }

        guard !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 || $0.value == 0x09 })
        else { return nil }
        return Array(characters.utf8)
    }

    static func encode(event: NSEvent) -> [UInt8]? {
        encode(keyCode: event.keyCode,
               characters: event.charactersIgnoringModifiers ?? "",
               modifiers: event.modifierFlags)
    }
}
