import CoreGraphics
import Foundation

/// Decides whether hot-zone key shortcuts (Space / arrows) should be live.
///
/// Geometry alone is not enough. The pill grows when a peek arrives, and a
/// cursor that the zone expanded *underneath* has not asked for anything — but
/// the old rule armed on containment, so a peek landing under a parked pointer
/// swallowed the next Space. Someone typing in a browser lost the space bar
/// mid-sentence and sent play/pause to whatever was playing instead, and had to
/// dismiss the peek to get it back.
///
/// Movement is the consent signal: the shortcuts arm once the pointer *moves*
/// while inside the zone, and stay armed until it leaves. Hovering the notch
/// still arms on the first tick, because arriving there is itself movement.
struct ShortcutArming: Equatable {
    private(set) var isArmed = false
    private var lastPoint: CGPoint?

    /// - Returns: whether shortcuts should fire for a key pressed right now.
    @discardableResult
    mutating func update(point: CGPoint, inZone: Bool) -> Bool {
        defer { lastPoint = point }
        guard inZone else {
            isArmed = false
            return false
        }
        if let lastPoint, lastPoint != point {
            isArmed = true
        }
        return isArmed
    }

    /// Leaving the zone — or the pill going away — disarms. Kept separate from
    /// `update` so callers with no pointer sample can still reset.
    mutating func disarm() {
        isArmed = false
        lastPoint = nil
    }
}
