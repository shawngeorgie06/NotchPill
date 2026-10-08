import AppKit
import Foundation
import Darwin

/// Reads now-playing metadata via the mediaremote-adapter Perl bridge.
/// Direct MediaRemote calls return nil inside signed app bundles on macOS 15.4+;
/// `/usr/bin/perl` is entitled and can load the bundled adapter framework.
final class MediaRemoteBridge {
    var onUpdate: ((NowPlaying?) -> Void)?

    private var streamProcess: Process?
    private var readSource: DispatchSourceRead?
    /// Stream parser state is confined to workQueue. The generation also
    /// prevents a cancelled source from delivering a queued stale event.
    private var activeStreamGeneration: UInt64 = 0
    /// Lifecycle state and this counter are confined to the main thread.
    private var streamGeneration: UInt64 = 0
    private var lineBuffer = Data()
    private var accumulatedPayload: [String: Any] = [:]
    private var cachedArtwork: NSImage?
    private var cachedArtworkKey: String?
    private var cachedArtworkTrackKey: String?
    private let workQueue = DispatchQueue(label: "notchpill.mediaremote.bridge")
    /// Artwork fetches run here, NOT on `workQueue`, so a slow `get` can never
    /// stall the stream reader that shares `workQueue`.
    private let artworkQueue = DispatchQueue(label: "notchpill.mediaremote.artwork")
    /// Track we're currently fetching artwork for (owned by `artworkQueue`).
    private var artworkInFlightKey: String?
    /// Cancels the exact `get` subprocess when playback changes or the bridge
    /// stops; stale queued retries are rejected by artworkInFlightKey.
    private var artworkTask: Task<Void, Never>?
    /// Whether the bridge is meant to be running, as opposed to merely not
    /// running. Without it a restart cannot tell a crash apart from `stop()`
    /// and would resurrect the adapter after a deliberate shutdown.
    private var shouldRun = false
    /// Consecutive restarts, to back off rather than spin. Reset by the first
    /// line the new stream delivers, which is the only proof it works.
    private var restartAttempts = 0
    private static let maxRestartDelay: TimeInterval = 30

    /// Kept as an internal value so tests can exercise child exit and parent
    /// death with harmless synthetic processes.
    nonisolated static let supervisorScript = #"""
parent="$1"; perl="$2"; script="$3"; framework="$4"
"$perl" "$script" "$framework" stream &
child=$!
(
  while kill -0 "$parent" 2>/dev/null; do sleep 1; done
  kill "$child" 2>/dev/null || true
) &
watcher=$!
cleanup() {
  kill "$child" "$watcher" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
}
trap 'cleanup; exit 0' HUP INT TERM
wait "$child"
status=$?
cleanup
exit "$status"
"""#

    private static let logMedia = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_NOWPLAYING"] == "1"

    func start() {
        assert(Thread.isMainThread)
        shouldRun = true
        guard streamProcess == nil else { return }
        guard let paths = bundledPaths() else {
            if Self.logMedia { print("NOWPLAYING: adapter bundle missing") }
            onUpdate?(nil)
            return
        }
        // Keep a small supervisor as the direct child. It owns the Perl stream,
        // forwards its output, and stops that exact child if this app is killed
        // before stop() can run. No process-name matching or global adapter kill
        // is needed, and normal termination of the supervisor also reaps Perl.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", Self.supervisorScript, "notchpill-media-supervisor",
                             String(getpid()), "/usr/bin/perl", paths.script.path, paths.framework.path]
        process.currentDirectoryURL = paths.script.deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] proc in
            if Self.logMedia { print("NOWPLAYING: adapter stream exited \(proc.terminationStatus)") }
            DispatchQueue.main.async { self?.handleStreamTerminated(proc) }
        }

        do {
            try process.run()
        } catch {
            if Self.logMedia { print("NOWPLAYING: adapter launch failed \(error)") }
            onUpdate?(nil)
            return
        }

        streamProcess = process
        streamGeneration &+= 1
        let generation = streamGeneration
        workQueue.async { [weak self] in
            guard let self else { return }
            self.activeStreamGeneration = generation
            self.lineBuffer.removeAll(keepingCapacity: false)
            self.accumulatedPayload.removeAll(keepingCapacity: false)
            self.cachedArtwork = nil
            self.cachedArtworkKey = nil
            self.cachedArtworkTrackKey = nil
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, queue: workQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableOutput(from: pipe.fileHandleForReading, generation: generation)
        }
        source.setCancelHandler {
            try? pipe.fileHandleForReading.close()
        }
        source.resume()
        readSource = source

        if Self.logMedia { print("NOWPLAYING: adapter stream started") }
    }

    func stop() {
        assert(Thread.isMainThread)
        shouldRun = false
        restartAttempts = 0
        streamGeneration &+= 1
        readSource?.cancel()
        readSource = nil
        if let streamProcess, streamProcess.isRunning {
            streamProcess.terminate()
        }
        streamProcess = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            self.activeStreamGeneration = 0
            self.lineBuffer.removeAll(keepingCapacity: false)
            self.accumulatedPayload.removeAll(keepingCapacity: false)
            self.cachedArtwork = nil
            self.cachedArtworkKey = nil
            self.cachedArtworkTrackKey = nil
        }
        artworkQueue.async { [weak self] in
            self?.artworkTask?.cancel()
            self?.artworkTask = nil
            self?.artworkInFlightKey = nil
        }
    }

    @discardableResult
    func send(command: Int) async -> Bool {
        guard let paths = bundledPaths() else { return false }
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [paths.script.path, paths.framework.path, "send", String(command)],
                currentDirectoryURL: paths.script.deletingLastPathComponent(),
                timeout: 5,
                outputLimitBytes: 16 * 1024
            )
            return true
        } catch {
            return false
        }
    }

    /// Bring the adapter back when it dies.
    ///
    /// This used to tear the state down and stop there, which quietly ended
    /// media for the rest of the app's life: the adapter is a separate
    /// `/usr/bin/perl` process, and anything that takes it out — a crash, a
    /// MediaRemote hiccup, the system reaping it across sleep — left the notch
    /// with no source and no way back short of relaunching NotchPill. Nothing
    /// reported it, so it looked like "media just stopped showing".
    ///
    /// Restarting is safe because the stream re-sends the current track the
    /// moment it connects, so a recovered bridge repopulates the card without
    /// waiting for the user to press anything.
    private func handleStreamTerminated(_ process: Process) {
        guard streamProcess === process else { return }
        streamProcess = nil
        streamGeneration &+= 1
        readSource?.cancel()
        readSource = nil
        workQueue.async { [weak self] in
            guard let self else { return }
            self.activeStreamGeneration = 0
            self.lineBuffer.removeAll(keepingCapacity: false)
            self.accumulatedPayload.removeAll(keepingCapacity: false)
        }
        // A deliberate `stop()` must stay stopped.
        guard shouldRun else { return }
        restartAttempts += 1
        // Backed off so a permanently broken adapter — a missing framework, a
        // perl that will not run — costs one process a half-minute instead of
        // a spawn loop for as long as the app is open.
        let delay = Self.restartDelay(attempt: restartAttempts)
        if Self.logMedia {
            print("NOWPLAYING: adapter died, restarting in \(delay)s (attempt \(restartAttempts))")
        }
        LogStore.log("media", "adapter stopped — restarting in \(Int(delay))s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.shouldRun, self.streamProcess == nil else { return }
            self.start()
        }
    }

    /// Seconds to wait before the nth restart: 2, 4, 8, 16, 30, 30…
    ///
    /// Backed off because the failure this recovers from is not always
    /// transient. A missing framework or an unrunnable perl fails identically
    /// every time, and retrying that at full speed would spawn processes for as
    /// long as the app is open. Capped so a bridge that recovers after a long
    /// outage still comes back within half a minute.
    nonisolated static func restartDelay(attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(maxRestartDelay, pow(2, Double(min(attempt, 5))))
    }

    private func readAvailableOutput(from handle: FileHandle, generation: UInt64) {
        guard activeStreamGeneration == generation else { return }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        // Output is the only proof the restarted adapter actually works, so the
        // backoff is cleared here rather than when the process launches — a
        // bridge that starts and dies immediately must keep backing off.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.streamGeneration == generation else { return }
            self.restartAttempts = 0
        }
        lineBuffer.append(chunk)
        while let range = lineBuffer.firstRange(of: Data([0x0A])) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleStreamLine(line, generation: generation)
        }
    }

    private func handleStreamLine(_ line: String, generation: UInt64) {
        guard let data = line.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["type"] as? String == "data",
              let payload = envelope["payload"] as? [String: Any] else { return }

        let isDiff = envelope["diff"] as? Bool ?? false
        if isDiff {
            for (key, value) in payload {
                if value is NSNull { accumulatedPayload.removeValue(forKey: key) }
                else { accumulatedPayload[key] = value }
            }
        } else {
            accumulatedPayload = payload
        }

        let np = parseNowPlaying(accumulatedPayload)
        // Stream diffs omit artwork on a track change; fetch it (with retry) off
        // the stream queue so the title keeps flowing while art loads.
        if let np, np.artwork == nil {
            requestArtwork(forTrackKey: "\(np.title)\u{0}\(np.artist)", generation: generation)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.shouldRun, self.streamGeneration == generation else { return }
            if Self.logMedia, let np {
                let art = np.artwork == nil ? "no art" : "art"
                print("NOWPLAYING: adapter -> \(np.title) / \(np.artist) (\(art))")
            }
            self.onUpdate?(np)
        }
    }

    private func parseNowPlaying(_ payload: [String: Any]) -> NowPlaying? {
        guard let resolved = NowPlayingDisplayResolver.resolve(
            title: payload["title"] as? String,
            artist: payload["artist"] as? String,
            album: payload["album"] as? String,
            mediaType: payload["mediaType"] as? String,
            bundleIdentifier: payload["bundleIdentifier"] as? String
        ) else { return nil }

        let playing = payload["playing"] as? Bool
        let rate = payload["playbackRate"] as? Double
        let isPlaying = playing ?? ((rate ?? 1) > 0)
        let artwork = artwork(from: payload, title: resolved.title, artist: resolved.artist)
        return NowPlaying(
            title: resolved.title,
            artist: resolved.artist,
            isPlaying: isPlaying,
            artwork: artwork,
            elapsed: Self.parseElapsed(payload),
            duration: Self.parseDuration(payload),
            playbackRate: rate ?? 1,
            timestamp: Self.parseTimestamp(payload)
        )
    }

    nonisolated static func parseDuration(_ payload: [String: Any]) -> TimeInterval? {
        if let micros = payload["durationMicros"] as? NSNumber {
            return micros.doubleValue / 1_000_000
        }
        if let seconds = payload["duration"] as? NSNumber {
            return seconds.doubleValue
        }
        return nil
    }

    nonisolated static func parseElapsed(_ payload: [String: Any]) -> TimeInterval? {
        if let micros = payload["elapsedTimeNowMicros"] as? NSNumber {
            return micros.doubleValue / 1_000_000
        }
        if let micros = payload["elapsedTimeMicros"] as? NSNumber {
            return micros.doubleValue / 1_000_000
        }
        if let now = payload["elapsedTimeNow"] as? NSNumber {
            return now.doubleValue
        }
        if let elapsed = payload["elapsedTime"] as? NSNumber {
            return elapsed.doubleValue
        }
        return nil
    }

    nonisolated static func parseTimestamp(_ payload: [String: Any]) -> Date? {
        if let micros = payload["timestampEpochMicros"] as? NSNumber {
            return Date(timeIntervalSince1970: micros.doubleValue / 1_000_000)
        }
        if let ts = payload["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: ts.doubleValue)
        }
        // The adapter sends an ISO 8601 *string*, which the numeric cases above
        // reject — so this returned nil for every real payload. Without a
        // timestamp there is nothing to interpolate from, and the progress bar
        // sat frozen: measured against a browser reporting `elapsedTime: 0` and
        // an unchanging timestamp, which is the position as of when playback
        // last started or seeked. Interpolation is not a refinement here, it is
        // the only thing that can move the bar at all.
        if let raw = payload["timestamp"] as? String {
            return parseISOTimestamp(raw)
        }
        return nil
    }

    /// Accepts both spellings: the plain form the adapter sends today, and the
    /// fractional-seconds form, which the strict parser rejects outright.
    nonisolated static func parseISOTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: trimmed) ?? ISO8601DateFormatter().date(from: trimmed)
    }

    private func artwork(from payload: [String: Any], title: String, artist: String) -> NSImage? {
        let trackKey = "\(title)\0\(artist)"
        if cachedArtworkTrackKey != trackKey {
            cachedArtworkTrackKey = trackKey
            cachedArtwork = nil
            cachedArtworkKey = nil
        }

        if let encoded = payload["artworkData"] as? String, !encoded.isEmpty {
            if encoded == cachedArtworkKey { return cachedArtwork }
            guard let data = Data(base64Encoded: encoded), let image = decodeArtwork(data) else {
                return cachedArtwork
            }
            cachedArtworkKey = encoded
            cachedArtwork = image
            return image
        }

        // Stream diffs sometimes omit artwork briefly; keep the last image for this track.
        return cachedArtwork
    }

    private func decodeArtwork(_ data: Data) -> NSImage? {
        guard let image = NSImage(data: data) else { return nil }
        if image.size.width <= 0 || image.size.height <= 0,
           let rep = image.representations.first {
            image.size = NSSize(width: max(rep.pixelsWide, 1), height: max(rep.pixelsHigh, 1))
        }
        return image
    }

    /// Artwork arrives via a separate `get` (stream diffs omit it on track change).
    /// The player often hasn't populated the new art the instant the title flips,
    /// so retry a few times until it appears — or until the track changes again.
    private func requestArtwork(forTrackKey trackKey: String, generation: UInt64) {
        let token = "\(generation):\(trackKey)"
        artworkQueue.async { [weak self] in
            guard let self else { return }
            guard self.artworkInFlightKey != token else { return } // already fetching this track
            self.artworkTask?.cancel()
            self.artworkTask = nil
            self.artworkInFlightKey = token
            self.fetchArtwork(forTrackKey: trackKey, token: token, generation: generation, attempt: 0)
        }
    }

    /// Runs on `artworkQueue`. Uses the deadlock-safe `ProcessRunner` (the old code
    /// waited on the process before draining a >64 KB artwork pipe, which hung the
    /// shared stream queue after the first track change).
    private func fetchArtwork(forTrackKey trackKey: String, token: String,
                              generation: UInt64, attempt: Int) {
        guard artworkInFlightKey == token else { return } // superseded by a newer track
        guard let paths = bundledPaths() else { artworkInFlightKey = nil; return }

        let maxAttempts = 6
        artworkTask = Task { [weak self] in
            let payload: [String: Any]?
            do {
                let result = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
                    arguments: [paths.script.path, paths.framework.path, "get"],
                    currentDirectoryURL: paths.script.deletingLastPathComponent(),
                    timeout: 8,
                    outputLimitBytes: 2 * 1024 * 1024
                )
                payload = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
            } catch {
                if Task.isCancelled { return }
                payload = nil
            }
            guard !Task.isCancelled else { return }
            guard let self else { return }
            // parseNowPlaying updates the stream's artwork cache, so it must
            // run on the same serial queue as stream parsing.
            self.workQueue.async { [weak self] in
                guard let self, self.activeStreamGeneration == generation,
                      self.cachedArtworkTrackKey == trackKey else { return }
                let np = payload.flatMap { self.parseNowPlaying($0) }
                self.artworkQueue.async { [weak self] in
                    guard let self, self.artworkInFlightKey == token else { return }
                    self.artworkTask = nil
                    if let np, np.artwork != nil, "\(np.title)\u{0}\(np.artist)" == trackKey {
                        self.artworkInFlightKey = nil
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.shouldRun,
                                  self.streamGeneration == generation else { return }
                            self.onUpdate?(np)
                        }
                    } else if attempt + 1 < maxAttempts {
                        self.artworkQueue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
                            self?.fetchArtwork(forTrackKey: trackKey, token: token,
                                               generation: generation, attempt: attempt + 1)
                        }
                    } else {
                        self.artworkInFlightKey = nil
                    }
                }
            }
        }
    }

    private func bundledPaths() -> (script: URL, framework: URL)? {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let script = resources.appendingPathComponent("mediaremote-adapter.pl")
        let framework = resources.appendingPathComponent("MediaRemoteAdapter.framework")
        guard FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(atPath: framework.path) else {
            return nil
        }
        return (script, framework)
    }
}
