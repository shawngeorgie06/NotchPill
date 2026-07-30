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
    static let expandedHeight: CGFloat = 128
    // Uniform shrink of the expanded pill. Raising this expands the pill a little
    // and lifts the width cap that bounds how large the readability/text scale can
    // grow — i.e. bigger, more legible text. NOTE: this affects only the EXPANDED
    // pill; the hover *activation* zone is derived from the physical notch rect and
    // the collapsed size, so it is unchanged by this value.
    static let expandedScale: CGFloat = 0.68
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
        notchRect(inFrame: screen.frame,
                  safeTop: screen.safeAreaInsets.top,
                  left: screen.auxiliaryTopLeftArea,
                  right: screen.auxiliaryTopRightArea)
    }

    /// The rule on its own, so the awkward inputs can be fed to it directly.
    ///
    /// Two things were wrong here, and together they put the pill off to the
    /// right of the screen under a black bar.
    ///
    /// It read the auxiliary areas' *widths* and assumed each was flush to a
    /// screen edge, instead of reading the edges it actually wanted. And it
    /// accepted whatever came out as long as the width was positive — so one
    /// degenerate area (macOS hands back an empty or zero-width one in some
    /// configurations) produced a "notch" running to the right edge of the
    /// display. The pill centres on that rect and is sized from it, which is a
    /// black bar, off to the right, in one step.
    ///
    /// A notch is a small gap near the middle of the top edge. Anything that
    /// is not that is not a measurement, and the centred fallback is better
    /// than a confident wrong answer.
    static func notchRect(inFrame frame: CGRect,
                          safeTop: CGFloat,
                          left: CGRect?,
                          right: CGRect?) -> CGRect? {
        guard safeTop > 0, frame.width > 0 else { return nil }

        if let left, let right,
           left.width > 1, left.height > 1,
           right.width > 1, right.height > 1 {
            // The edges facing the notch — not the widths.
            let width = right.minX - left.maxX
            let candidate = CGRect(x: left.maxX,
                                   y: frame.maxY - safeTop,
                                   width: width,
                                   height: safeTop)
            if isPlausibleNotch(candidate, in: frame) { return candidate }
        }

        // Fallback: assume a centered notch of a typical width.
        let assumedWidth: CGFloat = 200
        return CGRect(x: frame.midX - assumedWidth / 2,
                      y: frame.maxY - safeTop,
                      width: assumedWidth,
                      height: safeTop)
    }

    /// A notch is narrow and sits near the middle. Bounds chosen wide enough to
    /// cover every shipping Mac and narrow enough to reject a bad reading.
    static func isPlausibleNotch(_ rect: CGRect, in frame: CGRect) -> Bool {
        guard rect.width >= 80, rect.width <= 400 else { return false }
        guard rect.width < frame.width / 3 else { return false }
        // Physically centred, give or take a rounding error.
        return abs(rect.midX - frame.midX) <= frame.width * 0.05
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
