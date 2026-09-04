import Foundation

/// A VT100/xterm screen, with no AppKit and no file descriptors in it.
///
/// The PTY hands over bytes; this turns them into a grid you can draw. Keeping
/// it pure is what makes a terminal testable at all — every escape sequence
/// below is a `#expect` rather than something you squint at on screen and hope
/// you saw correctly.
///
/// The subset is deliberate. A card six lines tall is never running `vim`, so
/// the sequences that earn their place are the ones a shell, `ls`, `git`, and a
/// progress bar actually emit: SGR colour, cursor motion, erase, insert/delete,
/// scroll regions, and the alternate screen. Anything unrecognised is consumed
/// and dropped rather than printed as garbage — a stray `[?2004h` across the
/// card is worse than a sequence quietly ignored.
struct TerminalEmulator {

    // MARK: - Cells

    enum Color: Equatable {
        case `default`
        case indexed(UInt8)
        case rgb(UInt8, UInt8, UInt8)
    }

    struct Attributes: Equatable {
        var foreground: Color = .default
        var background: Color = .default
        var bold = false
        var dim = false
        var italic = false
        var underline = false
        var inverse = false
        /// Concealed text (SGR 8). Kept as an attribute rather than dropped at
        /// parse time so a password prompt that unhides itself still works.
        var hidden = false

        static let plain = Attributes()
    }

    struct Cell: Equatable {
        var character: Character = " "
        var attributes: Attributes = .plain

        static let blank = Cell()
    }

    // MARK: - Geometry

    private(set) var columns: Int
    private(set) var rows: Int

    /// The visible grid, `rows` entries of `columns` cells.
    private(set) var screen: [[Cell]]
    /// Lines that have scrolled off the top, oldest first, capped at
    /// `scrollbackLimit`. Output is card-only and truncated by design, so this
    /// is the only place it lives and nothing reaches disk.
    private(set) var scrollback: [[Cell]] = []
    static let scrollbackLimit = 200

    private(set) var cursorRow = 0
    private(set) var cursorColumn = 0
    private(set) var cursorVisible = true

    /// Set when the cursor is parked past the last column. A terminal does not
    /// wrap until the *next* printable character arrives, which is why a line
    /// that exactly fills the width does not leave a blank row behind it.
    private var pendingWrap = false

    private var attributes: Attributes = .plain
    /// DECSTBM. Inclusive, in screen coordinates.
    private var scrollTop = 0
    private var scrollBottom: Int
    private var savedCursor: (row: Int, column: Int, attributes: Attributes)?

    /// The alternate screen (DECSET 1049): full-screen programs draw here and
    /// the shell's scrollback is handed back untouched when they exit.
    private var alternate: (screen: [[Cell]], cursor: (Int, Int))?
    var isAlternateScreen: Bool { alternate != nil }

    init(columns: Int = 60, rows: Int = 6) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
        self.screen = Array(repeating: Array(repeating: Cell.blank, count: self.columns),
                            count: self.rows)
        self.scrollBottom = self.rows - 1
    }

    // MARK: - Parser state

    private enum ParseState: Equatable {
        case ground
        case escape
        /// Collecting the parameter and intermediate bytes of a CSI sequence.
        case csi
        /// Consuming an OSC/DCS/APC string until its terminator.
        case string
    }

    private var state: ParseState = .ground
    private var parameterBytes: [UInt8] = []
    /// Carries the incomplete tail of a multi-byte UTF-8 character between
    /// reads. A PTY read boundary lands mid-character often enough that
    /// decoding each chunk independently visibly corrupts any non-ASCII output.
    private var utf8Tail: [UInt8] = []
    private var decoder = UTF8()

    // MARK: - Feeding

    mutating func feed(_ bytes: [UInt8]) {
        var pending = utf8Tail + bytes
        utf8Tail = []
        var index = 0

        while index < pending.count {
            let byte = pending[index]

            switch state {
            case .string:
                // OSC/DCS run until BEL or ST (ESC \). Neither the title nor a
                // colour query has anywhere to go on a card this size.
                if byte == 0x07 {
                    state = .ground
                } else if byte == 0x1B, index + 1 < pending.count, pending[index + 1] == 0x5C {
                    index += 1
                    state = .ground
                } else if byte == 0x1B, index + 1 >= pending.count {
                    // The terminator may be split across reads.
                    utf8Tail = [byte]
                    return
                }
                index += 1
                continue

            case .escape:
                index += 1
                switch byte {
                case 0x5B: state = .csi; parameterBytes = []          // [
                case 0x5D, 0x50, 0x5F, 0x58: state = .string          // ] P _ X
                case 0x37: saveCursor(); state = .ground              // 7
                case 0x38: restoreCursor(); state = .ground           // 8
                case 0x4D: reverseIndex(); state = .ground            // M
                case 0x44: lineFeed(); state = .ground                // D
                case 0x45: carriageReturn(); lineFeed(); state = .ground // E
                case 0x63: self = TerminalEmulator(columns: columns, rows: rows) // c, RIS
                // Character-set selects take one more byte we do not need.
                case 0x28, 0x29, 0x2A, 0x2B: if index < pending.count { index += 1 }; state = .ground
                default: state = .ground
                }
                continue

            case .csi:
                index += 1
                // Parameters, then intermediates, then one final byte.
                if (0x30...0x3F).contains(byte) || (0x20...0x2F).contains(byte) {
                    // Guard against a hostile or broken stream growing this
                    // without bound; a real sequence is never this long.
                    if parameterBytes.count < 64 { parameterBytes.append(byte) }
                } else {
                    execute(csi: byte)
                    state = .ground
                }
                continue

            case .ground:
                if byte == 0x1B {
                    state = .escape
                    index += 1
                    continue
                }
                if byte < 0x20 || byte == 0x7F {
                    control(byte)
                    index += 1
                    continue
                }
                // A printable run: decode as UTF-8 from here.
                let start = index
                while index < pending.count,
                      pending[index] >= 0x20, pending[index] != 0x7F, pending[index] != 0x1B {
                    index += 1
                }
                let slice = Array(pending[start..<index])
                let (text, tail) = Self.decode(slice)
                for character in text { put(character) }
                if !tail.isEmpty {
                    // Hold the partial character back for the next read, but
                    // only when it really is at the end of everything we have.
                    if index >= pending.count {
                        utf8Tail = tail
                    } else {
                        for character in String(decoding: tail, as: UTF8.self) { put(character) }
                    }
                }
                continue
            }
        }
        pending = []
    }

    mutating func feed(_ data: Data) { feed([UInt8](data)) }

    /// Splits `bytes` into the characters that are complete and the trailing
    /// bytes of one that is not.
    static func decode(_ bytes: [UInt8]) -> (String, [UInt8]) {
        guard !bytes.isEmpty else { return ("", []) }
        // At most 3 bytes of a 4-byte character can be outstanding, and a
        // short read can be nothing *but* that partial character — so keeping
        // everything back has to be one of the options considered.
        for keep in 0...min(3, bytes.count) {
            let head = bytes.count - keep
            let candidate = Array(bytes[0..<head])
            if let text = String(bytes: candidate, encoding: .utf8) {
                return (text, Array(bytes[head...]))
            }
        }
        // Not valid UTF-8 at any split: show replacement characters rather
        // than dropping output entirely.
        return (String(decoding: bytes, as: UTF8.self), [])
    }

    // MARK: - C0

    private mutating func control(_ byte: UInt8) {
        switch byte {
        case 0x08: backspace()
        case 0x09: tab()
        case 0x0A, 0x0B, 0x0C: lineFeed()
        case 0x0D: carriageReturn()
        default: break  // BEL and friends have nothing to draw.
        }
    }

    private mutating func backspace() {
        pendingWrap = false
        cursorColumn = max(0, cursorColumn - 1)
    }

    private mutating func tab() {
        pendingWrap = false
        let next = ((cursorColumn / 8) + 1) * 8
        cursorColumn = min(columns - 1, next)
    }

    private mutating func carriageReturn() {
        pendingWrap = false
        cursorColumn = 0
    }

    private mutating func lineFeed() {
        pendingWrap = false
        if cursorRow == scrollBottom {
            scrollUp(1)
        } else if cursorRow < rows - 1 {
            cursorRow += 1
        }
    }

    private mutating func reverseIndex() {
        pendingWrap = false
        if cursorRow == scrollTop {
            scrollDown(1)
        } else if cursorRow > 0 {
            cursorRow -= 1
        }
    }

    // MARK: - Printing

    private mutating func put(_ character: Character) {
        if pendingWrap {
            carriageReturn()
            lineFeed()
        }
        guard cursorRow < rows, cursorColumn < columns else { return }
        screen[cursorRow][cursorColumn] = Cell(character: character, attributes: attributes)
        if cursorColumn == columns - 1 {
            pendingWrap = true
        } else {
            cursorColumn += 1
        }
    }

    // MARK: - Scrolling

    private mutating func scrollUp(_ count: Int) {
        guard count > 0, scrollTop <= scrollBottom else { return }
        for _ in 0..<count {
            let leaving = screen[scrollTop]
            // Only the real top of an unscrolled screen becomes history. A
            // scroll region is a program redrawing part of the card, and
            // keeping those lines would fill the scrollback with a progress
            // bar's every frame.
            if scrollTop == 0, alternate == nil {
                scrollback.append(leaving)
                if scrollback.count > Self.scrollbackLimit {
                    scrollback.removeFirst(scrollback.count - Self.scrollbackLimit)
                }
            }
            screen.remove(at: scrollTop)
            screen.insert(blankLine(), at: scrollBottom)
        }
    }

    private mutating func scrollDown(_ count: Int) {
        guard count > 0, scrollTop <= scrollBottom else { return }
        for _ in 0..<count {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: scrollTop)
        }
    }

    private func blankLine() -> [Cell] {
        Array(repeating: Cell(character: " ", attributes: .plain), count: columns)
    }

    // MARK: - CSI

    private var parameters: [Int] {
        let text = String(decoding: parameterBytes.filter { !(0x3C...0x3F).contains($0) },
                          as: UTF8.self)
        guard !text.isEmpty else { return [] }
        return text.split(separator: ";", omittingEmptySubsequences: false).map {
            Int($0.split(separator: ":").first.map(String.init) ?? "") ?? 0
        }
    }

    private var isPrivate: Bool { parameterBytes.first.map { (0x3C...0x3F).contains($0) } ?? false }

    private func parameter(_ index: Int, default fallback: Int) -> Int {
        let list = parameters
        guard index < list.count, list[index] != 0 else { return fallback }
        return list[index]
    }

    private mutating func execute(csi final: UInt8) {
        pendingWrap = false
        switch final {
        case 0x41: cursorRow = max(scrollTop, cursorRow - parameter(0, default: 1))     // A
        case 0x42: cursorRow = min(scrollBottom, cursorRow + parameter(0, default: 1))  // B
        case 0x43: cursorColumn = min(columns - 1, cursorColumn + parameter(0, default: 1)) // C
        case 0x44: cursorColumn = max(0, cursorColumn - parameter(0, default: 1))       // D
        case 0x45: cursorColumn = 0; cursorRow = min(rows - 1, cursorRow + parameter(0, default: 1)) // E
        case 0x46: cursorColumn = 0; cursorRow = max(0, cursorRow - parameter(0, default: 1))        // F
        case 0x47: cursorColumn = clampColumn(parameter(0, default: 1) - 1)             // G
        case 0x48, 0x66:                                                                // H, f
            cursorRow = clampRow(parameter(0, default: 1) - 1)
            cursorColumn = clampColumn(parameter(1, default: 1) - 1)
        case 0x4A: eraseInDisplay(parameters.first ?? 0)                                // J
        case 0x4B: eraseInLine(parameters.first ?? 0)                                   // K
        case 0x4C: insertLines(parameter(0, default: 1))                                // L
        case 0x4D: deleteLines(parameter(0, default: 1))                                // M
        case 0x50: deleteCharacters(parameter(0, default: 1))                           // P
        case 0x40: insertCharacters(parameter(0, default: 1))                           // @
        case 0x53: scrollUp(parameter(0, default: 1))                                   // S
        case 0x54: scrollDown(parameter(0, default: 1))                                 // T
        case 0x58: eraseCharacters(parameter(0, default: 1))                            // X
        case 0x64: cursorRow = clampRow(parameter(0, default: 1) - 1)                   // d
        case 0x6D: applySGR(parameters)                                                 // m
        case 0x72:                                                                      // r
            let top = clampRow(parameter(0, default: 1) - 1)
            let bottom = clampRow(parameter(1, default: rows) - 1)
            if top < bottom { scrollTop = top; scrollBottom = bottom }
            cursorRow = scrollTop
            cursorColumn = 0
        case 0x73: saveCursor()                                                         // s
        case 0x75: restoreCursor()                                                      // u
        case 0x68 where isPrivate: setPrivateMode(parameters, on: true)                 // ?h
        case 0x6C where isPrivate: setPrivateMode(parameters, on: false)                // ?l
        default: break
        }
    }

    private func clampRow(_ value: Int) -> Int { min(max(0, value), rows - 1) }
    private func clampColumn(_ value: Int) -> Int { min(max(0, value), columns - 1) }

    private mutating func saveCursor() {
        savedCursor = (cursorRow, cursorColumn, attributes)
    }

    private mutating func restoreCursor() {
        guard let saved = savedCursor else { return }
        cursorRow = clampRow(saved.row)
        cursorColumn = clampColumn(saved.column)
        attributes = saved.attributes
    }

    private mutating func setPrivateMode(_ list: [Int], on: Bool) {
        for mode in list {
            switch mode {
            case 25: cursorVisible = on
            case 47, 1047, 1049: setAlternateScreen(on)
            default: break  // Bracketed paste, mouse tracking: nothing to draw.
            }
        }
    }

    private mutating func setAlternateScreen(_ on: Bool) {
        if on {
            guard alternate == nil else { return }
            alternate = (screen, (cursorRow, cursorColumn))
            screen = Array(repeating: blankLine(), count: rows)
            cursorRow = 0
            cursorColumn = 0
        } else {
            guard let saved = alternate else { return }
            screen = saved.screen
            cursorRow = clampRow(saved.cursor.0)
            cursorColumn = clampColumn(saved.cursor.1)
            alternate = nil
        }
        scrollTop = 0
        scrollBottom = rows - 1
    }

    // MARK: - Erase and edit

    private mutating func eraseInDisplay(_ mode: Int) {
        switch mode {
        case 0:
            eraseInLine(0)
            for row in (cursorRow + 1)..<rows { screen[row] = blankLine() }
        case 1:
            eraseInLine(1)
            for row in 0..<cursorRow { screen[row] = blankLine() }
        case 2, 3:
            for row in 0..<rows { screen[row] = blankLine() }
            if mode == 3 { scrollback.removeAll() }
        default: break
        }
    }

    private mutating func eraseInLine(_ mode: Int) {
        guard cursorRow < rows else { return }
        let blank = Cell(character: " ", attributes: .plain)
        switch mode {
        case 0: for column in cursorColumn..<columns { screen[cursorRow][column] = blank }
        case 1: for column in 0...min(cursorColumn, columns - 1) { screen[cursorRow][column] = blank }
        case 2: screen[cursorRow] = blankLine()
        default: break
        }
    }

    private mutating func eraseCharacters(_ count: Int) {
        guard cursorRow < rows else { return }
        let end = min(columns, cursorColumn + max(1, count))
        guard cursorColumn < end else { return }
        for column in cursorColumn..<end {
            screen[cursorRow][column] = Cell(character: " ", attributes: .plain)
        }
    }

    private mutating func insertCharacters(_ count: Int) {
        guard cursorRow < rows, cursorColumn < columns else { return }
        for _ in 0..<max(1, count) {
            screen[cursorRow].insert(Cell(character: " ", attributes: .plain), at: cursorColumn)
            screen[cursorRow].removeLast()
        }
    }

    private mutating func deleteCharacters(_ count: Int) {
        guard cursorRow < rows, cursorColumn < columns else { return }
        for _ in 0..<max(1, count) {
            screen[cursorRow].remove(at: cursorColumn)
            screen[cursorRow].append(Cell(character: " ", attributes: .plain))
        }
    }

    private mutating func insertLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<max(1, count) {
            screen.remove(at: scrollBottom)
            screen.insert(blankLine(), at: cursorRow)
        }
    }

    private mutating func deleteLines(_ count: Int) {
        guard (scrollTop...scrollBottom).contains(cursorRow) else { return }
        for _ in 0..<max(1, count) {
            screen.remove(at: cursorRow)
            screen.insert(blankLine(), at: scrollBottom)
        }
    }

    // MARK: - SGR

    private mutating func applySGR(_ list: [Int]) {
        guard !list.isEmpty else { attributes = .plain; return }
        var index = 0
        while index < list.count {
            let code = list[index]
            switch code {
            case 0: attributes = .plain
            case 1: attributes.bold = true
            case 2: attributes.dim = true
            case 3: attributes.italic = true
            case 4: attributes.underline = true
            case 7: attributes.inverse = true
            case 8: attributes.hidden = true
            case 22: attributes.bold = false; attributes.dim = false
            case 23: attributes.italic = false
            case 24: attributes.underline = false
            case 27: attributes.inverse = false
            case 28: attributes.hidden = false
            case 30...37: attributes.foreground = .indexed(UInt8(code - 30))
            case 39: attributes.foreground = .default
            case 40...47: attributes.background = .indexed(UInt8(code - 40))
            case 49: attributes.background = .default
            case 90...97: attributes.foreground = .indexed(UInt8(code - 90 + 8))
            case 100...107: attributes.background = .indexed(UInt8(code - 100 + 8))
            case 38, 48:
                let (color, consumed) = Self.extendedColor(list, from: index)
                if let color {
                    if code == 38 { attributes.foreground = color } else { attributes.background = color }
                }
                index += consumed
            default: break
            }
            index += 1
        }
    }

    /// Reads a `38;5;n` or `38;2;r;g;b` colour, returning how many extra
    /// parameters it consumed so the caller can step past them.
    static func extendedColor(_ list: [Int], from index: Int) -> (Color?, Int) {
        guard index + 1 < list.count else { return (nil, 0) }
        switch list[index + 1] {
        case 5:
            guard index + 2 < list.count else { return (nil, 1) }
            return (.indexed(UInt8(clamping: list[index + 2])), 2)
        case 2:
            guard index + 4 < list.count else { return (nil, 1) }
            return (.rgb(UInt8(clamping: list[index + 2]),
                         UInt8(clamping: list[index + 3]),
                         UInt8(clamping: list[index + 4])), 4)
        default:
            return (nil, 1)
        }
    }

    // MARK: - Resize

    /// Resizes the grid, keeping the bottom of the output rather than the top.
    ///
    /// A card that grows should reveal what just happened, not what happened
    /// first — so extra rows are filled from scrollback, and rows removed go
    /// back into it.
    mutating func resize(columns newColumns: Int, rows newRows: Int) {
        let width = max(1, newColumns)
        let height = max(1, newRows)
        guard width != columns || height != rows else { return }

        var lines = scrollback + screen
        for index in lines.indices {
            if lines[index].count > width {
                lines[index] = Array(lines[index].prefix(width))
            } else if lines[index].count < width {
                lines[index] += Array(repeating: Cell(character: " ", attributes: .plain),
                                      count: width - lines[index].count)
            }
        }

        let bottomIndex = scrollback.count + cursorRow
        let visibleStart = max(0, min(lines.count - height, bottomIndex - (height - 1)))
        var visible = Array(lines[visibleStart..<min(lines.count, visibleStart + height)])
        while visible.count < height {
            visible.append(Array(repeating: Cell(character: " ", attributes: .plain), count: width))
        }

        scrollback = Array(lines[0..<visibleStart].suffix(Self.scrollbackLimit))
        screen = visible
        columns = width
        rows = height
        cursorRow = min(max(0, bottomIndex - visibleStart), height - 1)
        cursorColumn = min(cursorColumn, width - 1)
        scrollTop = 0
        scrollBottom = height - 1
        alternate = nil
        pendingWrap = false
    }

    // MARK: - Reading out

    /// The visible screen as plain strings, trailing blanks trimmed.
    var visibleLines: [String] {
        screen.map { row in
            String(row.map(\.character)).replacingOccurrences(
                of: "\\s+$", with: "", options: .regularExpression)
        }
    }

    /// Scrollback plus screen, for a card that scrolls through history.
    var allLines: [[Cell]] { scrollback + screen }

    /// How far back the card could be scrolled right now.
    ///
    /// Zero on the alternate screen: a full-screen program owns the whole
    /// viewport and the history behind it belongs to the shell, not to it, so
    /// scrolling there would show lines that have nothing to do with what is
    /// on screen.
    var scrollbackDepth: Int { alternate == nil ? scrollback.count : 0 }

    /// The window the card draws, `offset` lines back from the live bottom.
    /// A scrolled-back viewport reports no cursor, because the cursor is at
    /// the bottom and drawing it anywhere else would be a lie.
    func viewport(scrolledBack offset: Int) -> (lines: [[Cell]], cursorRow: Int?) {
        let clamped = min(max(offset, 0), scrollbackDepth)
        guard clamped > 0 else { return (screen, cursorRow) }
        let all = scrollback + screen
        let end = max(screen.count, all.count - clamped)
        return (Array(all[(end - screen.count)..<end]), nil)
    }
}
