import AppKit
import SwiftUI
import Testing
@testable import NotchPill

@MainActor @Suite("Whole-notch expansion and usage fit")
struct NotchExpansionAndUsageFitTests {
    @Test("the sides widen at hardware height as the bottom descends")
    func wholeNotchOrigin() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 260)
        for progress in [CGFloat(0), 0.1, 0.25, 0.5, 1] {
            let shape = ExpandedNotchShape(notchWidth: 185, notchHeight: 32,
                                           progress: progress, wrapsHardwareNotch: true)
            let path = shape.path(in: rect)
            let bounds = path.boundingRect
            #expect(abs(bounds.width - (185 + 215 * progress)) < 0.01)
            #expect(abs(bounds.height - (32 + 228 * progress)) < 0.01)
            #expect(bounds.minY == 0)
            if progress > 0 {
                #expect(path.contains(CGPoint(x: 200 - 92.5 - 80 * progress, y: 12)))
                #expect(path.contains(CGPoint(x: 200 + 92.5 + 80 * progress, y: 12)))
            }
            let stroke = shape.inset(by: 0.25).path(in: rect).boundingRect
            #expect(bounds.contains(stroke))
        }
    }

    @Test("oversized usage summaries retain their last row without any scroll view")
    func completeUsageFits() throws {
        for height in [CGFloat(100), 168, 240] {
            let content = UsageCardFit {
                VStack(spacing: 0) {
                    Color.white.frame(height: 280)
                    Color.green.frame(height: 20)
                }
            }.frame(width: 240, height: height)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: height),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.setFrameSize(CGSize(width: 240, height: height))
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            func containsScroll(_ view: NSView) -> Bool {
                view is NSScrollView || view.subviews.contains(where: containsScroll)
            }
            #expect(!containsScroll(host))
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            // The green final row must be visible at the bottom of every canvas.
            let color = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2,
                                                    y: bitmap.pixelsHigh - 4)?.usingColorSpace(.deviceRGB))
            #expect(color.greenComponent > color.redComponent + 0.2)
            window.close()
        }
    }
}
