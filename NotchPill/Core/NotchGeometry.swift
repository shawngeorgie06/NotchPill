import AppKit

/// Resolves the physical notch rectangle on a built-in display, in AppKit
/// global (bottom-left origin) coordinates, and derives collapsed/expanded
/// overlay frames from it.
struct NotchGeometry {
    /// The screen that owns the notch (built-in display with a top safe-area inset).
    let screen: NSScreen
    /// Notch rectangle in global screen coordinates (matches the black cutout).
    let notchRect: CGRect

    // Expanded overlay *design* dimensions (before shrink). The pill hangs below
    // the notch, wider than it. `expandedScale` shrinks the whole pill uniformly.
    static let expandedWidth: CGFloat = 680
    static let expandedHeight: CGFloat = 140
    static let expandedScale: CGFloat = 0.65
    // Extra horizontal slack around the pill so the hosting window can host the
    // full expanded pill even when the notch is narrow.
    static let horizontalPadding: CGFloat = 40

    /// Finds the built-in notched screen, if the current hardware/arrangement has one.
    static func current() -> NotchGeometry? {
        for screen in NSScreen.screens {
            guard screen.safeAreaInsets.top > 0 else { continue }
            guard isBuiltIn(screen) else { continue }
            guard let rect = notchRect(for: screen) else { continue }
            return NotchGeometry(screen: screen, notchRect: rect)
        }
        return nil
    }

    /// True when the screen is the internal display (as opposed to an external
    /// monitor that might also report a safe-area inset).
    static func isBuiltIn(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    /// Computes the notch rect from the two auxiliary top areas that flank it.
    private static func notchRect(for screen: NSScreen) -> CGRect? {
        let frame = screen.frame
        let notchHeight = screen.safeAreaInsets.top
        guard notchHeight > 0 else { return nil }

        // The areas to the left/right of the notch. Their gap is the notch width.
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let notchLeftX = frame.minX + left.width
            let notchRightX = frame.maxX - right.width
            let width = notchRightX - notchLeftX
            if width > 0 {
                return CGRect(x: notchLeftX,
                              y: frame.maxY - notchHeight,
                              width: width,
                              height: notchHeight)
            }
        }

        // Fallback: assume a centered notch of a typical width.
        let assumedWidth: CGFloat = 200
        return CGRect(x: frame.midX - assumedWidth / 2,
                      y: frame.maxY - notchHeight,
                      width: assumedWidth,
                      height: notchHeight)
    }

    /// The window that hosts the overlay. Sized to fit the fully expanded pill,
    /// centered horizontally on the notch, its top edge flush with the screen top.
    var windowFrame: CGRect {
        let renderWidth = Self.expandedWidth * Self.expandedScale
        let renderHeight = Self.expandedHeight * Self.expandedScale
        let width = max(renderWidth + Self.horizontalPadding * 2,
                        notchRect.width + Self.horizontalPadding * 2)
        let height = renderHeight + notchRect.height
        let midX = notchRect.midX
        return CGRect(x: midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height)
    }

    /// The collapsed notch rect expressed in the window's local coordinate space.
    func notchRectInWindow(_ windowFrame: CGRect) -> CGRect {
        CGRect(x: notchRect.minX - windowFrame.minX,
               y: notchRect.minY - windowFrame.minY,
               width: notchRect.width,
               height: notchRect.height)
    }
}
