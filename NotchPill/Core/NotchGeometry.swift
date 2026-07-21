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
    static let expandedWidth: CGFloat = 720
    static let expandedHeight: CGFloat = 148
    static let expandedScale: CGFloat = 0.58
    /// Extra gap (render points) between the notch and the content, so the top
    /// row sits clear of the notch.
    static let contentTopGap: CGFloat = 10
    // Extra horizontal slack around the pill so the hosting window can host the
    // full expanded pill even when the notch is narrow.
    static let horizontalPadding: CGFloat = 40

    /// Screen-space menu bar strip (full width) — clicks here must reach status items.
    static func menuBarStrip(for screen: NSScreen) -> CGRect {
        let height = max(screen.safeAreaInsets.top, NSStatusBar.system.thickness)
        return CGRect(x: screen.frame.minX,
                      y: screen.frame.maxY - height,
                      width: screen.frame.width,
                      height: height)
    }

    /// Screen rects beside the physical notch where browsers (Chrome, Brave, Safari)
    /// render tabs. Clicks here must always pass through the overlay.
    static func browserFlankRects(for screen: NSScreen) -> [CGRect] {
        let inset = screen.safeAreaInsets.top
        guard inset > 0 else { return [] }

        var rects: [CGRect] = []
        if let left = screen.auxiliaryTopLeftArea, left.width > 1, left.height > 1 {
            rects.append(left)
        }
        if let right = screen.auxiliaryTopRightArea, right.width > 1, right.height > 1 {
            rects.append(right)
        }

        // Fallback when auxiliary areas are unavailable.
        if rects.isEmpty, let notch = notchRect(for: screen) {
            let frame = screen.frame
            let top = frame.maxY - inset
            rects.append(CGRect(x: frame.minX, y: top, width: notch.minX - frame.minX, height: inset))
            rects.append(CGRect(x: notch.maxX, y: top, width: frame.maxX - notch.maxX, height: inset))
        }

        // Unified browser tab bars extend below the menu bar band.
        let tabBarExtension: CGFloat = 52
        return rects.map { rect in
            CGRect(x: rect.minX,
                   y: rect.minY - tabBarExtension,
                   width: rect.width,
                   height: rect.height + tabBarExtension)
        }
    }

    static func browserFlankRects(for geometry: NotchGeometry) -> [CGRect] {
        browserFlankRects(for: geometry.screen)
    }

    static func pointIsInBrowserFlank(_ point: NSPoint, on screen: NSScreen) -> Bool {
        browserFlankRects(for: screen).contains { $0.contains(point) }
    }

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

    /// The window that hosts the overlay. Sized to fit the fully expanded pill when
    /// expanded; shrinks to the visible collapsed pill when not.
    func windowFrame(expanded: Bool, collapsedContentSize: CGSize, expandedContentSize: CGSize) -> CGRect {
        if expanded {
            let pad: CGFloat = 2
            let width = expandedContentSize.width + pad * 2
            let height = expandedContentSize.height + pad
            return CGRect(x: notchRect.midX - width / 2,
                          y: screen.frame.maxY - height,
                          width: width,
                          height: height)
        }
        let pad: CGFloat = 2
        let width = collapsedContentSize.width + pad * 2
        let height = collapsedContentSize.height + pad
        return CGRect(x: notchRect.midX - width / 2,
                      y: screen.frame.maxY - height,
                      width: width,
                      height: height)
    }
}
