import SwiftUI

/// Physical dimensions the SwiftUI layer needs to match the hardware notch and
/// size the expanded pill.
struct NotchMetrics: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// The content design canvas — tiles are laid out at this full size, then the
    /// whole expanded pill is uniformly shrunk by `scale` for display.
    var designExpandedWidth: CGFloat
    var designExpandedHeight: CGFloat
    /// Uniform shrink applied to the expanded pill and its content (1.0 = none).
    var scale: CGFloat
    /// Extra gap (render points) between the notch and the content.
    var topGap: CGFloat = 0
    /// The user's size preference alone (1.0 = default), separate from `scale`,
    /// which already has it multiplied in. Layout needs the two apart: shrinking
    /// the pill should *not* shrink the type by the same amount, and it should
    /// drop cards rather than cram them.
    var userScale: CGFloat = 1
    /// False on a display with no cutout, where the pill must be drawn as a
    /// deliberate floating capsule rather than as an extension of hardware
    /// that does not exist.
    var hasPhysicalNotch: Bool = true
    /// Width of the screen the pill lives on, so a peek that needs room can ask
    /// for it without guessing how much room exists. Zero when unknown, which
    /// callers treat as "stay inside the usual expanded width".
    var screenWidth: CGFloat = 0

    /// Rendered (post-shrink) pill dimensions below the notch.
    var expandedWidth: CGFloat { designExpandedWidth * scale }
    var expandedHeight: CGFloat { designExpandedHeight * scale }

    var designContentSize: CGSize { CGSize(width: designExpandedWidth, height: designExpandedHeight) }
    var collapsedSize: CGSize { CGSize(width: notchWidth, height: notchHeight) }

    /// Legacy chip-count estimate (tests). Prefer `NotchContentLayout.collapsedSize`.
    func collapsedPreviewSize(chipCount: Int) -> CGSize {
        guard chipCount > 0 else { return collapsedSize }
        let rowHeight: CGFloat = 34
        let perChip: CGFloat = 108
        let width = min(expandedWidth, max(notchWidth + 24, 24 + CGFloat(chipCount) * perChip))
        return CGSize(width: width, height: notchHeight + rowHeight)
    }
}

/// A rectangle with square top corners (flush against the bezel) and rounded
/// bottom corners — the shape of the physical notch, growing into the pill.
struct NotchShape: Shape {
    var bottomRadius: CGFloat
    /// Rounding for the top corners.
    ///
    /// Zero on notched hardware, and that is the whole point of the shape: the
    /// square top edge is flush against the bezel, tucked inside the physical
    /// cutout, so the pill and the notch read as one object.
    ///
    /// On a display with **no** cutout there is nothing for those corners to
    /// hide inside. The identical path then draws a flat-topped black slab
    /// butting into open wallpaper below the menu bar — reported, accurately,
    /// as the UI "hanging in free space". Rounding them turns the same surface
    /// into a deliberate floating island.
    var topRadius: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let r = min(bottomRadius, limit)
        let t = min(topRadius, limit)
        guard t <= 0 else { return roundedPath(in: rect, top: t, bottom: r) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addArc(center: CGPoint(x: rect.maxX - r, y: rect.maxY - r),
                    radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + r, y: rect.maxY - r),
                    radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.closeSubpath()
        return path
    }

    /// Independently rounded top and bottom, for the no-notch case.
    private func roundedPath(in rect: CGRect, top: CGFloat, bottom: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addArc(center: CGPoint(x: rect.maxX - top, y: rect.minY + top),
                    radius: top, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addArc(center: CGPoint(x: rect.maxX - bottom, y: rect.maxY - bottom),
                    radius: bottom, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addArc(center: CGPoint(x: rect.minX + bottom, y: rect.maxY - bottom),
                    radius: bottom, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addArc(center: CGPoint(x: rect.minX + top, y: rect.minY + top),
                    radius: top, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
        path.closeSubpath()
        return path
    }
}

/// A surface attached to the *actual* hardware notch. The overlay deliberately
/// draws nothing in the notch's own rectangle: macOS already supplies that
/// black cutout. Its path begins at the lower edge of the cutout and flows into
/// the floating island below, so there is only one notch on screen.
struct ExpandedNotchShape: Shape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var bottomRadius: CGFloat = 18
    /// Interpolates the island from the hardware notch's lower edge (0) to the
    /// finished floating pill (1).
    var progress: CGFloat = 1
    /// When false, no neck and no shoulders: the surface is a plain rounded
    /// capsule hanging below the menu bar. See `freeFloatingPath`.
    var hasPhysicalNotch: Bool = true

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(notchWidth, AnimatablePair(notchHeight, AnimatablePair(bottomRadius, progress))) }
        set {
            notchWidth = newValue.first
            notchHeight = newValue.second.first
            bottomRadius = newValue.second.second.first
            progress = newValue.second.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let width = max(0, rect.width)
        let height = max(0, rect.height)
        guard width > 0, height > 0 else { return Path() }

        let physicalHeight = min(max(0, notchHeight), height)
        let physicalWidth = min(max(0, notchWidth), width)
        let expansion = min(1, max(0, progress))
        let notchLeft = rect.midX - physicalWidth / 2
        let notchRight = rect.midX + physicalWidth / 2
        let hardwareBottom = rect.minY + physicalHeight
        let availableBodyHeight = max(0, height - physicalHeight)
        let bodyHeight = availableBodyHeight * expansion
        guard bodyHeight > 0.5 else {
            return Path()
        }
        let surfaceBottom = hardwareBottom + bodyHeight

        // No cutout to grow out of: draw something that is meant to float.
        if !hasPhysicalNotch {
            return freeFloatingPath(rect: rect, top: hardwareBottom,
                                    bottom: surfaceBottom, expansion: expansion,
                                    fullWidth: width, neckWidth: physicalWidth)
        }

        // Grow downward first, then widen. This avoids the broad horizontal
        // flash that makes a hover surface look like a panel appearing below
        // the notch instead of an expansion of it.
        let widthProgress = expansion * (0.5 + 0.5 * expansion)
        let surfaceWidth = physicalWidth + (width - physicalWidth) * widthProgress
        let surfaceLeft = rect.midX - surfaceWidth / 2
        let surfaceRight = rect.midX + surfaceWidth / 2

        // Start at the lower edge of the *real* notch, hold that width for a
        // small neck, then grow down and out. The overlay never paints a fake
        // copy of the hardware cutout above this point.
        let neckDepth = min(3, bodyHeight * 0.18)
        let shoulderDepth = min(9, max(0, bodyHeight - neckDepth) * 0.42)
        let shoulderStart = hardwareBottom + neckDepth
        let shoulderBottom = min(surfaceBottom, shoulderStart + shoulderDepth)
        let radius = min(bottomRadius * expansion, min(surfaceWidth, bodyHeight) / 2)

        var path = Path()
        path.move(to: CGPoint(x: notchLeft, y: hardwareBottom))
        path.addLine(to: CGPoint(x: notchRight, y: hardwareBottom))
        path.addLine(to: CGPoint(x: notchRight, y: shoulderStart))
        path.addCurve(
            to: CGPoint(x: surfaceRight, y: shoulderBottom),
            control1: CGPoint(x: notchRight, y: shoulderStart + shoulderDepth * 0.32),
            control2: CGPoint(x: surfaceRight, y: shoulderBottom - shoulderDepth * 0.28)
        )
        path.addLine(to: CGPoint(x: surfaceRight, y: surfaceBottom - radius))
        path.addArc(
            center: CGPoint(x: surfaceRight - radius, y: surfaceBottom - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: surfaceLeft + radius, y: surfaceBottom))
        path.addArc(
            center: CGPoint(x: surfaceLeft + radius, y: surfaceBottom - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: surfaceLeft, y: shoulderBottom))
        path.addCurve(
            to: CGPoint(x: notchLeft, y: shoulderStart),
            control1: CGPoint(x: surfaceLeft, y: shoulderBottom - shoulderDepth * 0.28),
            control2: CGPoint(x: notchLeft, y: shoulderStart + shoulderDepth * 0.32)
        )
        path.closeSubpath()
        return path
    }

    /// The pill on a display with no notch: rounded on all four corners,
    /// hanging just below the menu bar.
    ///
    /// The notched path above starts at the cutout's lower edge with square top
    /// corners and never paints above it, because on that hardware the black
    /// above is the notch itself and the two read as one object. Run the same
    /// path where there is no notch and those square corners butt into open
    /// wallpaper — a slab with a flat top hanging in mid-air, which is the
    /// "floating, not attached" report. Rounding the top and letting it sit
    /// clear of the menu bar makes it read as a deliberate island instead.
    private func freeFloatingPath(rect: CGRect, top: CGFloat, bottom: CGFloat,
                                  expansion: CGFloat, fullWidth: CGFloat,
                                  neckWidth: CGFloat) -> Path {
        // Same grow-down-then-out feel as the notched pill, so the hover reads
        // the same on both kinds of display.
        let widthProgress = expansion * (0.5 + 0.5 * expansion)
        let surfaceWidth = neckWidth + (fullWidth - neckWidth) * widthProgress
        // A small breath under the menu bar. Flush against it would look like a
        // failed attempt to attach to something.
        let gap: CGFloat = 4 * expansion
        let boxTop = top + gap
        let boxHeight = max(0, bottom - boxTop)
        guard boxHeight > 0.5, surfaceWidth > 0.5 else { return Path() }
        let box = CGRect(x: rect.midX - surfaceWidth / 2, y: boxTop,
                         width: surfaceWidth, height: boxHeight)
        let radius = min(bottomRadius, min(box.width, box.height) / 2)
        return Path(roundedRect: box, cornerRadius: radius)
    }
}
