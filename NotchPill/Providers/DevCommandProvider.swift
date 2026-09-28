import Foundation
import Darwin

/// Reads per-command snapshots written atomically by the command wrapper and
/// the developer CLI.
/// Each invocation has its own file, so simultaneous builds cannot overwrite
/// each other. Snapshots also survive an app restart.
@MainActor
final class DevCommandProvider {
    var onUpdate: (([DevCommand]) -> Void)?
    private(set) var commands: [DevCommand] = []

    private let directory: URL
    private var timer: Timer?
    private var orphanEndDates: [String: Date] = [:]
    private let completedRetention: TimeInterval = 30 * 60
    private let orphanGrace: TimeInterval = 10

    init(directory: URL = PrivateStore.root.appendingPathComponent("commands", isDirectory: true)) {
        self.directory = directory
    }

    func start() {
        guard timer == nil else { return }
        PrivateStore.makeDirectory(directory)
        let poll = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        orphanEndDates.removeAll()
        commands = []
        onUpdate?([])
    }

    /// Internal seam for focused tests and an immediate refresh after a demo.
    func refresh(now: Date = Date()) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        var latest: [DevCommand] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var command = try? JSONDecoder().decode(DevCommand.self, from: data),
                  !command.id.isEmpty,
                  file.deletingPathExtension().lastPathComponent == command.id else { continue }

            // Wrapper snapshots carry a PID and can be checked for a vanished
            // process. Script-posted activities have no PID and remain active
            // until their owner posts a result or removes them.
            if (command.state == .running || command.state == .waiting),
               command.processId != nil,
               now.timeIntervalSince(command.updatedAt) > orphanGrace,
               !Self.isAlive(command.processId) {
                command.state = .failed
                let ended = orphanEndDates[command.id] ?? now
                orphanEndDates[command.id] = ended
                command.endedAt = ended
                // A vanished wrapper has no reliable exit status.
                command.exitCode = nil
            } else {
                orphanEndDates[command.id] = nil
            }
            if command.state != .running && command.state != .waiting,
               now.timeIntervalSince(command.endedAt ?? command.updatedAt) > completedRetention {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            latest.append(command)
        }
        latest.sort {
            let lhsActive = $0.state == .running || $0.state == .waiting
            let rhsActive = $1.state == .running || $1.state == .waiting
            if lhsActive != rhsActive { return lhsActive }
            if $0.state == .waiting && $1.state == .running { return true }
            if $0.state == .running && $1.state == .waiting { return false }
            return $0.updatedAt > $1.updatedAt
        }
        let seen = Set(latest.map(\.id))
        orphanEndDates = orphanEndDates.filter { seen.contains($0.key) }
        if latest != commands {
            commands = latest
            onUpdate?(latest)
        }
    }

    private nonisolated static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
