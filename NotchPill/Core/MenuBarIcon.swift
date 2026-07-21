import AppKit

/// Compact template icon for the menu bar (icon only — no title).
enum MenuBarIcon {
    static func templateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let path = NSBezierPath()
            let w: CGFloat = 10
            let h: CGFloat = 12
            let x = (size.width - w) / 2
            let y = (size.height - h) / 2
            let rect = NSRect(x: x, y: y, width: w, height: h)
            path.appendRoundedRect(rect, xRadius: 5, yRadius: 5)
            NSColor.labelColor.setFill()
            path.fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
