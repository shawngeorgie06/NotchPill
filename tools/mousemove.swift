import CoreGraphics
import Foundation

// Moves the hardware cursor and posts a mouse-moved event so NSTrackingArea
// enter/exit fire, to exercise the notch hover path. Args: x y (top-left global).
let args = CommandLine.arguments
guard args.count >= 3, let x = Double(args[1]), let y = Double(args[2]) else {
    FileHandle.standardError.write("usage: mousemove <x> <y>\n".data(using: .utf8)!)
    exit(2)
}
let point = CGPoint(x: x, y: y)
CGWarpMouseCursorPosition(point)
CGAssociateMouseAndMouseCursorPosition(1)
if let move = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left) {
    move.post(tap: .cghidEventTap)
}
print("moved to \(x),\(y)")
