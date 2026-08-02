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

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let r = min(bottomRadius, min(rect.width, rect.height) / 2)
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
}

/// The expanded surface is one continuous shape: it begins at the physical
/// notch, then eases out through soft shoulders into the floating pill below.
/// Keeping this as a single path removes the hard horizontal seam that a
/// stacked rectangle-and-pill background produces during hover expansion.
struct ExpandedNotchShape: Shape {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var bottomRadius: CGFloat = 18
    /// Interpolates the whole surface from the hardware notch (0) to the
    /// finished floating pill (1).
    var progress: CGFloat = 1

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
        let availableBodyHeight = max(0, height - physicalHeight)
        let bodyHeight = availableBodyHeight * expansion
        guard bodyHeight > 0.5 else {
            var notch = Path()
            notch.addRect(CGRect(x: notchLeft, y: rect.minY,
                                 width: physicalWidth, height: physicalHeight))
            return notch
        }
        let surfaceBottom = rect.minY + physicalHeight + bodyHeight
        let surfaceWidth = physicalWidth + (width - physicalWidth) * expansion
        let surfaceLeft = rect.midX - surfaceWidth / 2
        let surfaceRight = rect.midX + surfaceWidth / 2

        // Let the surface begin as the physical notch, hold that width for a
        // small neck, then grow down and out. Both height and width follow the
        // same progress value, so it grows from the notch rather than swapping
        // in a finished panel below it.
        let neckDepth = min(3, bodyHeight * 0.18)
        let shoulderDepth = min(9, max(0, bodyHeight - neckDepth) * 0.42)
        let shoulderStart = rect.minY + physicalHeight + neckDepth
        let shoulderBottom = min(surfaceBottom, shoulderStart + shoulderDepth)
        let radius = min(bottomRadius * expansion, min(surfaceWidth, bodyHeight) / 2)

        var path = Path()
        path.move(to: CGPoint(x: notchLeft, y: rect.minY))
        path.addLine(to: CGPoint(x: notchRight, y: rect.minY))
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
}
