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
