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

/// Continuous-curvature ("squircle") corners, as `RoundedRectangle(style:
/// .continuous)` and Apple's own island draw them.
///
/// A circular arc meets a straight edge with a sudden jump in curvature, which
/// the eye reads as a faint flat spot where the corner starts. A continuous
/// corner reaches further along each edge and eases in, so the silhouette
/// looks like one smooth object — most visible on a black shape on OLED.
///
/// One cubic per corner is an approximation, not true G2: with both handles
/// on their edges it still starts with some curvature (about half a circle's
/// at these constants), so the jump is softened rather than removed. Apple's
/// own `.continuous` style is used where a whole rounded rect is wanted.
enum NotchCorner {
    /// How much further along each edge a continuous corner reaches than the
    /// circular arc of the same radius would.
    static let reach: CGFloat = 1.2
    /// Where the cubic's control handles sit, as a fraction of the reach
    /// measured from the corner point. Tuned so the 45-degree point lands
    /// near Apple's continuous corner rather than near a circle's.
    static let handle: CGFloat = 0.356

    /// Distance the corner occupies along each edge for `radius`, never more
    /// than `limit` so two corners on one edge cannot overlap.
    static func extent(radius: CGFloat, limit: CGFloat) -> CGFloat {
        max(0, min(radius * reach, limit))
    }
}

private extension Path {
    /// Turns from the edge ending at `start` onto the edge leaving `end`, where
    /// `corner` is the point the two edges would meet at if they were square.
    /// Both handles lie along their own edge, so the join is tangent-continuous
    /// with whatever straight line precedes and follows it.
    mutating func addContinuousCorner(start: CGPoint, corner: CGPoint, end: CGPoint) {
        let f = NotchCorner.handle
        addCurve(to: end,
                 control1: CGPoint(x: corner.x + (start.x - corner.x) * f,
                                   y: corner.y + (start.y - corner.y) * f),
                 control2: CGPoint(x: corner.x + (end.x - corner.x) * f,
                                   y: corner.y + (end.y - corner.y) * f))
    }
}

/// A rectangle with square top corners (flush against the bezel) and rounded
/// bottom corners — the shape of the physical notch, growing into the pill.
struct NotchShape: InsettableShape {
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
    /// How far the outline is pulled inside the frame. Not animated: it is a
    /// constant of the stroke that asks for it (`strokeBorder`), never of a
    /// transition.
    private var insetAmount: CGFloat = 0

    init(bottomRadius: CGFloat, topRadius: CGFloat = 0) {
        self.bottomRadius = bottomRadius
        self.topRadius = topRadius
    }

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, topRadius) }
        set { bottomRadius = newValue.first; topRadius = newValue.second }
    }

    /// An inside stroke needs the outline itself pulled in, so the whole line
    /// lands on the black fill instead of half of it anti-aliasing against the
    /// wallpaper. Radii shrink with it so the inset outline stays parallel to
    /// the original.
    func inset(by amount: CGFloat) -> NotchShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard rect.width > 0, rect.height > 0 else { return Path() }
        let limit = min(rect.width, rect.height) / 2
        let r = NotchCorner.extent(radius: max(0, bottomRadius - insetAmount), limit: limit)
        let t = NotchCorner.extent(radius: max(0, topRadius - insetAmount), limit: limit)
        guard t <= 0 else { return roundedPath(in: rect, top: t, bottom: r) }
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addContinuousCorner(start: CGPoint(x: rect.maxX, y: rect.maxY - r),
                                 corner: CGPoint(x: rect.maxX, y: rect.maxY),
                                 end: CGPoint(x: rect.maxX - r, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addContinuousCorner(start: CGPoint(x: rect.minX + r, y: rect.maxY),
                                 corner: CGPoint(x: rect.minX, y: rect.maxY),
                                 end: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.closeSubpath()
        return path
    }

    /// Independently rounded top and bottom, for the no-notch case. `top` and
    /// `bottom` are corner extents (see `NotchCorner.extent`), not radii.
    private func roundedPath(in rect: CGRect, top: CGFloat, bottom: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + top, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.addContinuousCorner(start: CGPoint(x: rect.maxX - top, y: rect.minY),
                                 corner: CGPoint(x: rect.maxX, y: rect.minY),
                                 end: CGPoint(x: rect.maxX, y: rect.minY + top))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - bottom))
        path.addContinuousCorner(start: CGPoint(x: rect.maxX, y: rect.maxY - bottom),
                                 corner: CGPoint(x: rect.maxX, y: rect.maxY),
                                 end: CGPoint(x: rect.maxX - bottom, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bottom, y: rect.maxY))
        path.addContinuousCorner(start: CGPoint(x: rect.minX + bottom, y: rect.maxY),
                                 corner: CGPoint(x: rect.minX, y: rect.maxY),
                                 end: CGPoint(x: rect.minX, y: rect.maxY - bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + top))
        path.addContinuousCorner(start: CGPoint(x: rect.minX, y: rect.minY + top),
                                 corner: CGPoint(x: rect.minX, y: rect.minY),
                                 end: CGPoint(x: rect.minX + top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

/// A surface attached to the actual hardware notch. Expanded cards grow
/// around the full cutout; the compact chip surface retains shoulders below
/// the hardware. Both modes share the same progress-driven outline and rim.
struct ExpandedNotchShape: InsettableShape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var bottomRadius: CGFloat = 18
    /// Interpolates from the hardware origin (0) to the finished card (1).
    var progress: CGFloat = 1
    /// When false, no neck and no shoulders: the surface is a plain rounded
    /// capsule hanging below the menu bar. See `freeFloatingPath`.
    var hasPhysicalNotch: Bool = true
    /// See `NotchShape.insetAmount`.
    private var insetAmount: CGFloat = 0
    /// Expanded cards grow from the whole hardware silhouette; compact chips
    /// retain the shallow shoulder surface below it.
    var wrapsHardwareNotch: Bool = false

    /// Largest extent of either half of a shoulder. The shoulder is a concave
    /// curve off the notch's vertical edge, then a convex one onto the side of
    /// the surface; at this size the pair reads as one soft flare rather than
    /// the pinched S a 9pt-deep single cubic made across a wide pill.
    static let shoulderReach: CGFloat = 14
    /// Shared with the content clearance budget; the finished surface reaches
    /// its full width after this neck and both halves of the shoulder.
    static let neckDepth: CGFloat = 3
    static let floatingGap: CGFloat = 4

    init(notchWidth: CGFloat, notchHeight: CGFloat, bottomRadius: CGFloat = 18,
         progress: CGFloat = 1, hasPhysicalNotch: Bool = true,
         wrapsHardwareNotch: Bool = false) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.bottomRadius = bottomRadius
        self.progress = progress
        self.hasPhysicalNotch = hasPhysicalNotch
        self.wrapsHardwareNotch = wrapsHardwareNotch
    }

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>>> {
        get { AnimatablePair(notchWidth, AnimatablePair(notchHeight, AnimatablePair(bottomRadius, progress))) }
        set {
            notchWidth = newValue.first
            notchHeight = newValue.second.first
            bottomRadius = newValue.second.second.first
            progress = newValue.second.second.second
        }
    }

    /// The neck and the sides move in by the inset, and the top edge moves
    /// *down* by it, so an inside stroke never reaches above the hardware
    /// notch's lower edge.
    func inset(by amount: CGFloat) -> ExpandedNotchShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let width = max(0, rect.width)
        let height = max(0, rect.height)
        guard width > 0, height > 0 else { return Path() }

        let physicalHeight = min(max(0, notchHeight), height)
        let physicalWidth = min(max(0, notchWidth), width)
        let expansion = min(1, max(0, progress))
        if hasPhysicalNotch && wrapsHardwareNotch {
            // The starting rectangle is the real notch, including its side
            // walls. Width and bottom travel use the same progress, so no
            // narrow neck holds the sides in place while the bottom drops.
            let surfaceWidth = physicalWidth + (width - physicalWidth) * expansion
            let surfaceHeight = physicalHeight + (height - physicalHeight) * expansion
            let box = CGRect(x: rect.midX - surfaceWidth / 2, y: rect.minY,
                             width: surfaceWidth, height: surfaceHeight)
                .insetBy(dx: insetAmount, dy: insetAmount)
            guard box.width > 0, box.height > 0 else { return Path() }
            let radius = min(max(0, 10 + (bottomRadius - 10) * expansion - insetAmount),
                             min(box.width, box.height) / 2)
            return NotchShape(bottomRadius: radius, topRadius: 0).path(in: box)
        }
        let availableBodyHeight = max(0, height - physicalHeight)
        let outerBodyHeight = availableBodyHeight * expansion
        guard outerBodyHeight > 0.5 else {
            return Path()
        }

        // No cutout to grow out of: draw something that is meant to float.
        if !hasPhysicalNotch {
            return freeFloatingPath(rect: rect, top: rect.minY + physicalHeight,
                                    bottom: rect.minY + physicalHeight + outerBodyHeight,
                                    expansion: expansion,
                                    fullWidth: width, neckWidth: physicalWidth)
        }

        // Grow downward first, then widen. This avoids the broad horizontal
        // flash that makes a hover surface look like a panel appearing below
        // the notch instead of an expansion of it.
        let widthProgress = expansion * (0.5 + 0.5 * expansion)
        let outerSurfaceWidth = physicalWidth + (width - physicalWidth) * widthProgress

        // The outline is sized from the full rect, *then* pulled in by the
        // inset. Insetting the rect first and growing inside that shrinks the
        // body by the inset times `progress`, not by the inset, so below half
        // expansion the inside stroke's bottom edge sat outside the fill.
        let inset = insetAmount
        let notchLeft = rect.midX - max(0, physicalWidth / 2 - inset)
        let notchRight = rect.midX + max(0, physicalWidth / 2 - inset)
        let hardwareBottom = rect.minY + physicalHeight + inset
        let bodyHeight = outerBodyHeight - 2 * inset
        guard bodyHeight > 0 else { return Path() }
        let surfaceBottom = hardwareBottom + bodyHeight
        let surfaceWidth = max(0, outerSurfaceWidth - 2 * inset)
        let surfaceLeft = rect.midX - surfaceWidth / 2
        let surfaceRight = rect.midX + surfaceWidth / 2

        // Start at the lower edge of the *real* notch, hold that width for a
        // small neck, then flare out and down. The overlay never paints a fake
        // copy of the hardware cutout above this point.
        let neckDepth = min(Self.neckDepth, bodyHeight * 0.18)
        let shoulderStart = hardwareBottom + neckDepth
        let radius = min(max(0, bottomRadius * expansion - inset),
                         min(surfaceWidth, bodyHeight) / 2)
        let corner = NotchCorner.extent(radius: radius, limit: min(surfaceWidth, bodyHeight) / 2)
        // Each half of the shoulder is bounded by the horizontal room (half the
        // flare, so the two curves can meet but never cross) and by the
        // vertical room left above the bottom corner. Both halves share one
        // size, so at every `progress` the join with the neck and with the
        // side are tangent-continuous: straight lines in, curves that start
        // along them, no kink where a cubic met a vertical edge.
        let flare = surfaceRight - notchRight
        let verticalRoom = max(0, bodyHeight - neckDepth - corner)
        let reach = max(0, min(Self.shoulderReach, flare / 2, verticalRoom / 2))
        let shoulderBottom = shoulderStart + 2 * reach

        var path = Path()
        path.move(to: CGPoint(x: notchLeft, y: hardwareBottom))
        path.addLine(to: CGPoint(x: notchRight, y: hardwareBottom))
        path.addLine(to: CGPoint(x: notchRight, y: shoulderStart))
        path.addContinuousCorner(start: CGPoint(x: notchRight, y: shoulderStart),
                                 corner: CGPoint(x: notchRight, y: shoulderStart + reach),
                                 end: CGPoint(x: notchRight + reach, y: shoulderStart + reach))
        path.addLine(to: CGPoint(x: surfaceRight - reach, y: shoulderStart + reach))
        path.addContinuousCorner(start: CGPoint(x: surfaceRight - reach, y: shoulderStart + reach),
                                 corner: CGPoint(x: surfaceRight, y: shoulderStart + reach),
                                 end: CGPoint(x: surfaceRight, y: shoulderBottom))
        path.addLine(to: CGPoint(x: surfaceRight, y: surfaceBottom - corner))
        path.addContinuousCorner(start: CGPoint(x: surfaceRight, y: surfaceBottom - corner),
                                 corner: CGPoint(x: surfaceRight, y: surfaceBottom),
                                 end: CGPoint(x: surfaceRight - corner, y: surfaceBottom))
        path.addLine(to: CGPoint(x: surfaceLeft + corner, y: surfaceBottom))
        path.addContinuousCorner(start: CGPoint(x: surfaceLeft + corner, y: surfaceBottom),
                                 corner: CGPoint(x: surfaceLeft, y: surfaceBottom),
                                 end: CGPoint(x: surfaceLeft, y: surfaceBottom - corner))
        path.addLine(to: CGPoint(x: surfaceLeft, y: shoulderBottom))
        path.addContinuousCorner(start: CGPoint(x: surfaceLeft, y: shoulderBottom),
                                 corner: CGPoint(x: surfaceLeft, y: shoulderStart + reach),
                                 end: CGPoint(x: surfaceLeft + reach, y: shoulderStart + reach))
        path.addLine(to: CGPoint(x: notchLeft - reach, y: shoulderStart + reach))
        path.addContinuousCorner(start: CGPoint(x: notchLeft - reach, y: shoulderStart + reach),
                                 corner: CGPoint(x: notchLeft, y: shoulderStart + reach),
                                 end: CGPoint(x: notchLeft, y: shoulderStart))
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
        let gap = Self.floatingGap * expansion
        let boxTop = top + gap
        let boxHeight = max(0, bottom - boxTop)
        guard boxHeight > 0.5, surfaceWidth > 0.5 else { return Path() }
        let box = CGRect(x: rect.midX - surfaceWidth / 2, y: boxTop,
                         width: surfaceWidth, height: boxHeight)
            .insetBy(dx: insetAmount, dy: insetAmount)
        guard box.width > 0, box.height > 0 else { return Path() }
        let radius = min(max(0, bottomRadius - insetAmount), min(box.width, box.height) / 2)
        return Path(roundedRect: box, cornerRadius: radius, style: .continuous)
    }
}
