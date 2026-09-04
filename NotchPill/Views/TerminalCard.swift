import AppKit
import SwiftUI

/// Takes every key press while the terminal card has focus.
///
/// SwiftUI's `TextField` is the wrong tool: a shell needs the arrows, tab,
/// escape and the control codes, and a text field eats all of them for its own
/// editing and focus behaviour. An `NSView` that is simply first responder gets
/// them raw, which is what a terminal has always needed.
struct TerminalKeyCatcher: NSViewRepresentable {
    var isFocused: Bool
    var onKey: (NSEvent) -> Bool
    var onFocusChange: (Bool) -> Void

    final class CatcherView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        var onFocusChange: ((Bool) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { onFocusChange?(true); return true }
        override func resignFirstResponder() -> Bool { onFocusChange?(false); return true }

        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }

        /// ⌘V has to paste into the shell rather than into whatever is behind
        /// the pill, and ⌘C interrupts, matching every other terminal.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard event.modifierFlags.contains(.command),
                  window?.firstResponder === self else { return false }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v":
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                guard !text.isEmpty else { return true }
                // Bracketed paste, so a shell that supports it treats a
                // multi-line paste as text rather than as commands to run.
                TerminalStore.shared.send("\u{1B}[200~" + text + "\u{1B}[201~")
                return true
            case "c":
                TerminalStore.shared.interrupt()
                return true
            default:
                return false
            }
        }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onKey = onKey
        view.onFocusChange = onFocusChange
        guard let window = view.window else { return }
        if isFocused, window.firstResponder !== view {
            window.makeFirstResponder(view)
        } else if !isFocused, window.firstResponder === view {
            window.makeFirstResponder(nil)
        }
    }
}

/// Catches the scroll wheel — and the click — over the grid.
///
/// SwiftUI has no scroll-wheel gesture on macOS, so this has to be an
/// `NSView`. Since one is here anyway it also takes the click, because an
/// `NSView` sitting over the card would otherwise swallow the tap gesture that
/// used to focus the terminal.
struct TerminalScrollCatcher: NSViewRepresentable {
    var onScroll: (Int) -> Void
    var onClick: () -> Void

    final class CatcherView: NSView {
        var onScroll: ((Int) -> Void)?
        var onClick: (() -> Void)?

        /// The key catcher owns the keyboard; this view must never take it
        /// away by becoming first responder on a click.
        override var acceptsFirstResponder: Bool { false }

        /// Wheel notches and trackpad swipes arrive in wildly different
        /// magnitudes, so deltas accumulate and a line is emitted per step
        /// rather than mapping one event to one line.
        private var accumulated: CGFloat = 0
        private static let pointsPerLine: CGFloat = 11

        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY
            let lines = Int((accumulated / Self.pointsPerLine).rounded(.towardZero))
            guard lines != 0 else { return }
            accumulated -= CGFloat(lines) * Self.pointsPerLine
            onScroll?(lines)
        }

        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.onScroll = onScroll
        view.onClick = onClick
    }
}

/// The grid, drawn.
///
/// This observes `TerminalStore` itself rather than being handed lines through
/// the notch's content snapshot, and that is the whole performance story. Shell
/// output used to travel through `relayoutTriggers`, so every frame ran an
/// animated relayout of the entire overlay — 30 a second, while the card's
/// height is a constant that could not possibly have changed. Owning the
/// observation here confines a redraw to this subtree.
///
/// One `Text` per run of cells sharing an attribute rather than one per cell:
/// a 58-column card is 348 views a frame otherwise, and at 60fps that is felt.
struct TerminalGridView: View {
    @ObservedObject private var store = TerminalStore.shared
    var isFocused: Bool
    var fontSize: CGFloat = 9
    var lineHeight: CGFloat = 11

    private let foreground = Color.white.opacity(0.92)
    private let background = Color.black.opacity(0.35)

    var body: some View {
        let grid = store.emulator
        let view = grid.viewport(scrolledBack: store.scrollOffset)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(view.lines.enumerated()), id: \.offset) { index, row in
                line(row, isCursorRow: index == view.cursorRow, cursorVisible: grid.cursorVisible)
                    .frame(height: lineHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Only while scrolled back, so the live card carries no extra chrome.
        .overlay(alignment: .topTrailing) {
            if store.scrollOffset > 0 {
                Text("↑\(store.scrollOffset)")
                    .font(.system(size: fontSize * 0.8, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 3)
                    .background(Color.black.opacity(0.45), in: Capsule())
            }
        }
        // Text arriving is not a state change worth interpolating. Without
        // this the card inherits whatever animation the surrounding relayout
        // is running and every character cross-fades into place, which reads
        // as lag rather than as motion.
        .animation(nil, value: store.revision)
        .transaction { $0.animation = nil }
    }

    private func line(_ row: [TerminalEmulator.Cell], isCursorRow: Bool,
                      cursorVisible: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(runs(in: row).enumerated()), id: \.offset) { _, run in
                Text(run.text)
                    .font(.system(size: fontSize, weight: run.attributes.bold ? .semibold : .regular,
                                  design: .monospaced))
                    .italic(run.attributes.italic)
                    .underline(run.attributes.underline)
                    .foregroundStyle(colors(run.attributes).foreground)
                    .background(colors(run.attributes).background ?? .clear)
            }
            if isCursorRow, cursorVisible, isFocused {
                cursor
            }
            Spacer(minLength: 0)
        }
    }

    private var cursor: some View {
        Rectangle()
            .fill(foreground)
            .frame(width: fontSize * 0.62, height: lineHeight - 2)
            .opacity(0.75)
    }

    private func colors(_ attributes: TerminalEmulator.Attributes)
        -> (foreground: Color, background: Color?) {
        TerminalPalette.resolve(attributes, defaultForeground: foreground,
                                defaultBackground: background)
    }

    private struct Run {
        var text: String
        var attributes: TerminalEmulator.Attributes
    }

    /// Coalesces neighbouring cells that share an attribute into one span.
    /// Trailing blanks are dropped: they carry no colour worth drawing and
    /// would otherwise be a run of 50 spaces on every line.
    private func runs(in row: [TerminalEmulator.Cell]) -> [Run] {
        var trimmed = row[...]
        while let last = trimmed.last, last.character == " ",
              last.attributes.background == .default {
            trimmed = trimmed.dropLast()
        }
        var result: [Run] = []
        for cell in trimmed {
            if var previous = result.last, previous.attributes == cell.attributes {
                previous.text.append(cell.character)
                result[result.count - 1] = previous
            } else {
                result.append(Run(text: String(cell.character), attributes: cell.attributes))
            }
        }
        return result
    }
}
