import AppKit
import SwiftUI

/// NSHostingView that only participates in hit-testing over the interactive pill.
/// Prevents the full-size SwiftUI surface from swallowing clicks meant for browser tabs.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    /// Screen-coordinate point test — return true only where pill controls should receive clicks.
    var acceptsScreenPoint: (NSPoint) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return nil }
        let screenPoint = window.convertToScreen(NSRect(origin: point, size: .zero)).origin
        guard acceptsScreenPoint(screenPoint) else { return nil }
        return super.hitTest(point)
    }
}
