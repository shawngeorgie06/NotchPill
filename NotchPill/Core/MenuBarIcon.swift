import AppKit

/// Menu bar template icon: a Mac notch / Dynamic Island pill hanging from the menu bar.
enum MenuBarIcon {
  static func templateImage() -> NSImage {
    let pointSize: CGFloat = 18
    let pixelSize: CGFloat = 36
    let image = NSImage(size: NSSize(width: pixelSize, height: pixelSize), flipped: true) { _ in
      let scale = pixelSize / pointSize
      NSGraphicsContext.current?.imageInterpolation = .high
      NSColor.black.setFill()

      // Menu bar strip across the top.
      let barWidth = 28 * scale
      let barHeight = 2.5 * scale
      let barX = (pixelSize - barWidth) / 2
      let barY: CGFloat = 2.5 * scale
      NSBezierPath(roundedRect: NSRect(x: barX, y: barY, width: barWidth, height: barHeight), xRadius: 0.75 * scale, yRadius: 0.75 * scale).fill()

      // Notch pill — flat top, rounded bottom (same silhouette as NotchShape).
      let pillWidth = 14 * scale
      let pillHeight = 13 * scale
      let pillX = (pixelSize - pillWidth) / 2
      let pillY = barY + barHeight + 1.5 * scale
      notchPath(in: NSRect(x: pillX, y: pillY, width: pillWidth, height: pillHeight), bottomRadius: 4.5 * scale).fill()

      // Live indicator dot (Dynamic Island cue).
      let dotRadius = 2.2 * scale
      let dotCenter = NSPoint(x: pixelSize / 2, y: pillY + pillHeight * 0.58)
      NSBezierPath(ovalIn: NSRect(
        x: dotCenter.x - dotRadius,
        y: dotCenter.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
      )).fill()

      return true
    }
    image.size = NSSize(width: pointSize, height: pointSize)
    image.isTemplate = true
    return image
  }

  /// Matches `NotchShape` — square top, rounded bottom.
  private static func notchPath(in rect: NSRect, bottomRadius: CGFloat) -> NSBezierPath {
    let r = min(bottomRadius, min(rect.width, rect.height) / 2)
    let path = NSBezierPath()
    path.move(to: NSPoint(x: rect.minX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
    path.line(to: NSPoint(x: rect.maxX, y: rect.maxY - r))
    path.appendArc(
      withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r),
      radius: r,
      startAngle: 0,
      endAngle: 90,
      clockwise: true
    )
    path.line(to: NSPoint(x: rect.minX + r, y: rect.maxY))
    path.appendArc(
      withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r),
      radius: r,
      startAngle: 90,
      endAngle: 180,
      clockwise: true
    )
    path.close()
    return path
  }
}
