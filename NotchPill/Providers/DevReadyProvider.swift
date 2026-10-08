import Foundation
import Darwin

/// Listens for "task finished" signals from terminals, IDEs, and shell hooks.
/// Distributed notifications deliver immediately; file signals are scanned on
/// a utility queue and watched with a directory vnode notification, with a
/// slow poll as a fallback for filesystems that do not report vnode changes.
final class DevReadyProvider {
    var onDevReady: ((DevReadyAlert) -> Void)?

    private let signalDirectory: URL
    private let fileQueue = DispatchQueue(label: "app.notchpill.dev-ready-signals", qos: .utility)
    private var signalWatch: DispatchSourceFileSystemObject?
    private var fallbackPoll: DispatchSourceTimer?
    private var distributedObserver: NSObjectProtocol?
    private var started = false
    private var generation = 0
    private let lifecycleLock = NSLock()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        signalDirectory = home.appendingPathComponent(".notchpill/signals", isDirectory: true)
    }

    func start() {
        lifecycleLock.lock()
        guard !started else { lifecycleLock.unlock(); return }
        started = true
        generation &+= 1
        let run = generation
        lifecycleLock.unlock()
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: DevReadyAlert.notificationName,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, self.isCurrent(run),
                  let alert = DevReadyAlert.parse(userInfo: notification.userInfo ?? [:]) else { return }
            self.onDevReady?(Self.demotingStaleWaiting(alert))
        }

        let directory = signalDirectory
        fileQueue.async { [weak self] in
            guard let self, self.isCurrent(run) else { return }
            PrivateStore.makeDirectory(directory)
            self.installWatch(at: directory, generation: run)
            self.scanSignalFiles(at: directory, generation: run)
        }
    }

    /// A `.waiting` signal older than this no longer describes a live question.
    nonisolated static let waitingStaleAfter: TimeInterval = 300

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
        lifecycleLock.lock()
        guard started else { lifecycleLock.unlock(); return }
        started = false
        generation &+= 1
        lifecycleLock.unlock()
        if let distributedObserver {
            DistributedNotificationCenter.default().removeObserver(distributedObserver)
        }
        distributedObserver = nil
        fileQueue.async { [weak self] in
            self?.signalWatch?.cancel()
            self?.signalWatch = nil
            self?.fallbackPoll?.cancel()
            self?.fallbackPoll = nil
        }
    }

    private func installWatch(at directory: URL, generation: Int) {
        guard isCurrent(generation) else { return }
        let fd = open(directory.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
                queue: fileQueue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, self.isCurrent(generation) else { return }
                let events = source?.data ?? []
                self.scanSignalFiles(at: directory, generation: generation)
                if events.contains(.rename) || events.contains(.delete) || events.contains(.revoke) {
                    self.recoverWatch(at: directory, generation: generation)
                }
            }
            source.setCancelHandler { close(fd) }
            guard isCurrent(generation) else {
                source.resume()
                source.cancel()
                return
            }
            signalWatch = source
            source.resume()
            // Reconcile occasionally even with a healthy watch. This catches
            // lost/coalesced vnode events without returning to the old fast poll.
            installPoll(at: directory, generation: generation, interval: 10)
            IntegrationHealthStore.report("devReady", state: .ready)
            return
        }

        installPoll(at: directory, generation: generation, interval: 2)
    }

    private func installPoll(at directory: URL, generation: Int, interval: TimeInterval) {
        let timer = DispatchSource.makeTimerSource(queue: fileQueue)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.scanSignalFiles(at: directory, generation: generation) }
        guard isCurrent(generation) else {
            timer.resume()
            timer.cancel()
            return
        }
        fallbackPoll = timer
        timer.resume()
        IntegrationHealthStore.report("devReady", state: .ready)
    }

    private func recoverWatch(at directory: URL, generation: Int) {
        guard isCurrent(generation) else { return }
        signalWatch?.cancel()
        signalWatch = nil
        fallbackPoll?.cancel()
        fallbackPoll = nil
        PrivateStore.makeDirectory(directory)
        installWatch(at: directory, generation: generation)
    }

    private func scanSignalFiles(at directory: URL, generation: Int) {
        guard isCurrent(generation) else { return }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in files where url.pathExtension.lowercased() == "json" {
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let alert = DevReadyAlert.parse(from: data) else { continue }
            let value = Self.demotingStaleWaiting(alert)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(generation) else { return }
                self.onDevReady?(value)
            }
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        return started && self.generation == generation
    }
}
