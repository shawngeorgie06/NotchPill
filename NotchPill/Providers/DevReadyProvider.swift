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
            self?.onDevReady?(alert)
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scanSignalFiles() }
        }
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
            onDevReady?(alert)
        }
    }
}
