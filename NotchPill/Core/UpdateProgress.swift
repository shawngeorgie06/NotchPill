import Foundation

/// Live state of an in-app update, rendered as a progress peek in the notch.
struct UpdateProgress: Equatable {
    enum Phase: Equatable { case downloading, verifying, installing, relaunching, failed }

    var version: String
    var phase: Phase
    var fraction: Double   // 0...1, meaningful during .downloading

    var title: String { "Updating to \(version)" }

    /// Whether the bar should render as an indeterminate shimmer vs a filled fraction.
    var isIndeterminate: Bool { phase != .downloading }

    var statusText: String {
        switch phase {
        case .downloading: return "Downloading… \(Int((fraction * 100).rounded()))%"
        case .verifying:   return "Verifying signature…"
        case .installing:  return "Installing…"
        case .relaunching: return "Relaunching…"
        case .failed:      return "Update failed"
        }
    }
}

/// Shared, observable update progress. `UpdateInstaller` writes here; the notch
/// controller mirrors it into `NotchState` so the overlay shows a live bar.
@MainActor
final class UpdateProgressStore: ObservableObject {
    static let shared = UpdateProgressStore()

    @Published private(set) var progress: UpdateProgress?

    func begin(version: String) {
        progress = UpdateProgress(version: version, phase: .downloading, fraction: 0)
    }

    func setDownload(fraction: Double) {
        guard var p = progress else { return }
        p.phase = .downloading
        p.fraction = min(max(fraction, 0), 1)
        progress = p
    }

    func setPhase(_ phase: UpdateProgress.Phase) {
        guard var p = progress else { return }
        p.phase = phase
        progress = p
    }

    func clear() { progress = nil }
}
