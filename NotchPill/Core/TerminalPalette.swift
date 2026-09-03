import SwiftUI

/// Turns emulator colours into something drawable on the pill.
///
/// The pill is always a dark surface, so the palette is the dark-terminal one
/// rather than the system's: the standard ANSI 16 lifted enough to stay legible
/// at 9pt, then the xterm 6×6×6 cube and its grey ramp computed rather than
/// tabulated, because 240 hand-written constants is 240 chances to be wrong.
enum TerminalPalette {
    /// The first sixteen, in ANSI order. Normal, then bright.
    static let base: [(r: Double, g: Double, b: Double)] = [
        (0.30, 0.32, 0.36),   // black, lifted — pure black is invisible here
        (0.94, 0.38, 0.38),   // red
        (0.44, 0.82, 0.47),   // green
        (0.95, 0.76, 0.36),   // yellow
        (0.44, 0.66, 0.96),   // blue
        (0.80, 0.55, 0.96),   // magenta
        (0.40, 0.82, 0.85),   // cyan
        (0.86, 0.88, 0.92),   // white
        (0.48, 0.51, 0.56),   // bright black
        (1.00, 0.52, 0.52),
        (0.58, 0.90, 0.60),
        (1.00, 0.85, 0.50),
        (0.58, 0.76, 1.00),
        (0.88, 0.68, 1.00),
        (0.56, 0.91, 0.93),
        (1.00, 1.00, 1.00),
    ]

    /// The xterm 256-colour palette: 16 named, a 6×6×6 cube, then a 24-step
    /// grey ramp.
    static func components(forIndex index: UInt8) -> (r: Double, g: Double, b: Double) {
        let value = Int(index)
        if value < 16 { return base[value] }
        if value < 232 {
            let offset = value - 16
            let levels: [Double] = [0, 95, 135, 175, 215, 255].map { $0 / 255.0 }
            return (levels[(offset / 36) % 6], levels[(offset / 6) % 6], levels[offset % 6])
        }
        let grey = (8.0 + Double(value - 232) * 10.0) / 255.0
        return (grey, grey, grey)
    }

    static func color(_ color: TerminalEmulator.Color, fallback: Color) -> Color {
        switch color {
        case .default: return fallback
        case .indexed(let index):
            let (r, g, b) = components(forIndex: index)
            return Color(red: r, green: g, blue: b)
        case .rgb(let r, let g, let b):
            return Color(red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
        }
    }

    /// The pair a cell is actually drawn with, after inverse, dim, and the
    /// concealment SGR have had their say.
    static func resolve(_ attributes: TerminalEmulator.Attributes,
                        defaultForeground: Color,
                        defaultBackground: Color) -> (foreground: Color, background: Color?) {
        var foreground = color(attributes.foreground, fallback: defaultForeground)
        var background = attributes.background == .default
            ? nil : color(attributes.background, fallback: defaultBackground)

        if attributes.inverse {
            let swapped = background ?? defaultBackground
            background = foreground
            foreground = swapped
        }
        if attributes.hidden { foreground = background ?? defaultBackground }
        if attributes.dim { foreground = foreground.opacity(0.55) }
        return (foreground, background)
    }
}
