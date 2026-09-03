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

/// The grid, drawn.
///
/// One `Text` per run of cells sharing an attribute rather than one per cell:
/// a 58-column card is 348 views a frame otherwise, and at 30fps that is enough
/// to be felt.
struct TerminalGridView: View {
    let snapshot: TerminalSnapshot
    var fontSize: CGFloat = 9
    var lineHeight: CGFloat = 11

    private let foreground = Color.white.opacity(0.92)
    private let background = Color.black.opacity(0.35)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(snapshot.lines.enumerated()), id: \.offset) { index, row in
                line(row, isCursorRow: index == snapshot.cursor.row)
                    .frame(height: lineHeight, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ row: [TerminalEmulator.Cell], isCursorRow: Bool) -> some View {
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
            if isCursorRow, snapshot.cursorVisible, snapshot.isFocused {
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
