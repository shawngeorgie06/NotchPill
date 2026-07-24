import Foundation

/// Listens for "task finished" signals from terminals, IDEs, and shell hooks.
///
/// Two delivery paths:
/// - Drop a JSON file in `~/.notchpill/signals/*.json` (polled).
/// - Post a distributed notification named `DevReadyAlert.notificationName`.
@MainActor
final class DevReadyProvider {
    var onDevReady: ((DevReadyAlert) -> Void)?

    private let signalDirectory: URL
    private var pollTimer: Timer?
    private var distributedObserver: NSObjectProtocol?
    private var processedFiles = Set<String>()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        signalDirectory = home.appendingPathComponent(".notchpill/signals", isDirectory: true)
    }

    func start() {
        try? FileManager.default.createDirectory(at: signalDirectory, withIntermediateDirectories: true)

        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: DevReadyAlert.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let alert = DevReadyAlert.parse(userInfo: notification.userInfo ?? [:]) else { return }
            // Live path — a notification can only arrive while the app is running,
            // so this is a no-op in practice; applied for uniformity.
            self?.onDevReady?(Self.demotingStaleWaiting(alert))
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanSignalFiles() }
        }
    }

    /// A `.waiting` signal older than this no longer describes a live question.
    /// Signals queued while NotchPill wasn't running can be hours old; in Phase 1
    /// a stale one was a cosmetic ghost peek, but a waiting peek carries live
    /// answer buttons, so tapping one would focus a terminal that is back at a
    /// shell prompt and type `y⏎` into it.
    nonisolated static let waitingStaleAfter: TimeInterval = 300

    /// Demotes an aged `.waiting` alert to `.finished`: still shown (you probably
    /// want to know the agent asked), but with no answer buttons. Alerts with no
    /// usable `createdAt` are treated as fresh — a missing timestamp must not
    /// silently disable the feature.
    nonisolated static func demotingStaleWaiting(_ alert: DevReadyAlert,
                                                 now: Date = Date()) -> DevReadyAlert {
        guard alert.kind == .waiting,
              let age = alert.age(at: now),
              age > waitingStaleAfter else { return alert }
        var demoted = alert
        demoted.kind = .finished
        return demoted
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
    }

    private func scanSignalFiles() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: signalDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in files where url.pathExtension.lowercased() == "json" {
            let name = url.lastPathComponent
            guard !processedFiles.contains(name) else { continue }
            processedFiles.insert(name)
            defer { try? FileManager.default.removeItem(at: url) }

            guard let data = try? Data(contentsOf: url),
                  let alert = DevReadyAlert.parse(from: data) else { continue }
            onDevReady?(Self.demotingStaleWaiting(alert))
        }
    }
}
