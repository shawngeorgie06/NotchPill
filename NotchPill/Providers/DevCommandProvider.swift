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
    private var watcher: DispatchSourceFileSystemObject?
    private var isScanning = false
    private var refreshPending = false
    private var scanGeneration = 0
    private var isRunning = false
    private var orphanEndDates: [String: Date] = [:]
    private var dismissedIDs = Set<String>()
    private let completedRetention: TimeInterval = 30 * 60
    private let orphanGrace: TimeInterval = 10

    init(directory: URL = PrivateStore.root.appendingPathComponent("commands", isDirectory: true)) {
        self.directory = directory
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        PrivateStore.makeDirectory(directory)
        let descriptor = open(directory.path, O_EVTONLY)
        if descriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .attrib],
                queue: DispatchQueue.global(qos: .utility)
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.refreshAsync() }
            }
            source.setCancelHandler { close(descriptor) }
            watcher = source
            source.resume()
        }
        // A directory event reports writes, not elapsed time. Recheck at a
        // low rate so vanished process IDs and old completed rows expire even
        // when no command writes another snapshot. It also covers directory
        // replacement or a vnode watcher that stops delivering events.
        let poll = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshAsync() }
        }
        RunLoop.main.add(poll, forMode: .common)
        timer = poll
        refreshAsync()
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        watcher?.cancel()
        watcher = nil
        scanGeneration += 1
        isScanning = false
        refreshPending = false
        orphanEndDates.removeAll()
        commands = []
        onUpdate?([])
    }

    /// Dismisses one visible activity and removes its snapshot so it does not
    /// return on the next poll. IDs are constrained to the filenames already
    /// present in the provider's validated snapshot list.
    func dismiss(id: String) {
        guard commands.contains(where: { $0.id == id }),
              !id.isEmpty,
              !id.contains("/"),
              !id.contains("\\") else { return }
        let file = directory.appendingPathComponent(id).appendingPathExtension("json")
        dismissedIDs.insert(id)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: file)
        }
        orphanEndDates[id] = nil
        let updated = commands.filter { $0.id != id }
        guard updated != commands else { return }
        commands = updated
        onUpdate?(updated)
    }

    /// Internal seam for focused tests and an immediate refresh after a demo.
    func refresh(now: Date = Date()) {
        apply(Self.scan(directory: directory, now: now,
                        orphanGrace: orphanGrace, completedRetention: completedRetention,
                        orphanEndDates: orphanEndDates), now: now)
    }

    private func refreshAsync(now: Date = Date()) {
        guard isRunning else { return }
        guard !isScanning else { refreshPending = true; return }
        isScanning = true
        let generation = scanGeneration
        let directory = self.directory
        let orphanGrace = self.orphanGrace
        let completedRetention = self.completedRetention
        let orphanEndDates = self.orphanEndDates
        Task { [weak self] in
            let latest = await Task.detached(priority: .utility) {
                Self.scan(directory: directory, now: now,
                          orphanGrace: orphanGrace, completedRetention: completedRetention,
                          orphanEndDates: orphanEndDates)
            }.value
            guard let self, self.scanGeneration == generation else { return }
            self.apply(latest, now: now)
            self.isScanning = false
            if self.refreshPending {
                self.refreshPending = false
                self.refreshAsync()
            }
        }
    }

    private func apply(_ snapshots: [DevCommand], now: Date) {
        var latest = snapshots.filter { !dismissedIDs.contains($0.id) }
        for index in latest.indices {
            let command = latest[index]
            if command.state == .failed, command.processId != nil, command.exitCode == nil {
                let ended = orphanEndDates[command.id] ?? command.endedAt ?? now
                orphanEndDates[command.id] = ended
                latest[index].endedAt = ended
            } else {
                orphanEndDates[command.id] = nil
            }
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

    private nonisolated static func scan(directory: URL, now: Date,
                                         orphanGrace: TimeInterval,
                                         completedRetention: TimeInterval,
                                         orphanEndDates: [String: Date]) -> [DevCommand] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var latest: [DevCommand] = []
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  var command = try? JSONDecoder().decode(DevCommand.self, from: data),
                  !command.id.isEmpty,
                  file.deletingPathExtension().lastPathComponent == command.id else { continue }
            if (command.state == .running || command.state == .waiting),
               command.processId != nil,
               now.timeIntervalSince(command.updatedAt) > orphanGrace,
               !isAlive(command.processId) {
                command.state = .failed
                command.endedAt = orphanEndDates[command.id] ?? now
                command.exitCode = nil
            }
            if command.state != .running && command.state != .waiting,
               now.timeIntervalSince(orphanEndDates[command.id]
                   ?? command.endedAt ?? command.updatedAt) > completedRetention {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            latest.append(command)
        }
        return latest
    }

    private nonisolated static func isAlive(_ pid: Int32?) -> Bool {
        guard let pid, pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
}
