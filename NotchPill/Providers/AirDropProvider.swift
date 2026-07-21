import Foundation

/// AirDrop transfer status.
///
/// There is no public, reliable API to observe live AirDrop transfer progress
/// for other apps. `sharingd` exposes nothing supported, and scraping private
/// state would be brittle and could surface stale or fabricated data. Per the
/// product requirement, when status cannot be read reliably we OMIT the tile
/// rather than show fake data — so this provider always reports nil and the
/// AirDrop tile never renders. It exists as a seam: if a supported API appears,
/// implement it here and the tile lights up automatically.
final class AirDropProvider {
    var onUpdate: ((String?) -> Void)?

    func start() {
        onUpdate?(nil)
    }

    func stop() {}
}
