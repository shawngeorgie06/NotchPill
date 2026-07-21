import AppKit
import Foundation

/// Reads now-playing metadata via the mediaremote-adapter Perl bridge.
/// Direct MediaRemote calls return nil inside signed app bundles on macOS 15.4+;
/// `/usr/bin/perl` is entitled and can load the bundled adapter framework.
final class MediaRemoteBridge {
    var onUpdate: ((NowPlaying?) -> Void)?

    private var streamProcess: Process?
    private var stdoutPipe: Pipe?
    private var readSource: DispatchSourceRead?
    private var lineBuffer = Data()
    private var accumulatedPayload: [String: Any] = [:]
    private var cachedArtwork: NSImage?
    private var cachedArtworkKey: String?
    private var cachedArtworkTrackKey: String?
    private var artworkFetchPending = false
    private let workQueue = DispatchQueue(label: "notchpill.mediaremote.bridge")

    private static let logMedia = ProcessInfo.processInfo.environment["NOTCHPILL_LOG_NOWPLAYING"] == "1"

    func start() {
        guard streamProcess == nil else { return }
        guard let paths = bundledPaths() else {
            if Self.logMedia { print("NOWPLAYING: adapter bundle missing") }
            onUpdate?(nil)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [
            paths.script.path,
            paths.framework.path,
            "stream",
        ]
        process.currentDirectoryURL = paths.script.deletingLastPathComponent()

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] proc in
            if Self.logMedia { print("NOWPLAYING: adapter stream exited \(proc.terminationStatus)") }
            DispatchQueue.main.async { self?.handleStreamTerminated() }
        }

        do {
            try process.run()
        } catch {
            if Self.logMedia { print("NOWPLAYING: adapter launch failed \(error)") }
            onUpdate?(nil)
            return
        }

        streamProcess = process
        stdoutPipe = pipe

        let source = DispatchSource.makeReadSource(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, queue: workQueue)
        source.setEventHandler { [weak self] in
            self?.readAvailableOutput()
        }
        source.setCancelHandler { [weak self] in
            try? self?.stdoutPipe?.fileHandleForReading.close()
        }
        source.resume()
        readSource = source

        if Self.logMedia { print("NOWPLAYING: adapter stream started") }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if let streamProcess, streamProcess.isRunning {
            streamProcess.terminate()
        }
        streamProcess = nil
        stdoutPipe = nil
        lineBuffer.removeAll(keepingCapacity: false)
        accumulatedPayload.removeAll(keepingCapacity: false)
        cachedArtwork = nil
        cachedArtworkKey = nil
        cachedArtworkTrackKey = nil
    }

    @discardableResult
    func send(command: Int) -> Bool {
        guard let paths = bundledPaths() else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = [paths.script.path, paths.framework.path, "send", String(command)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func handleStreamTerminated() {
        streamProcess = nil
        readSource?.cancel()
        readSource = nil
        stdoutPipe = nil
    }

    private func readAvailableOutput() {
        guard let handle = stdoutPipe?.fileHandleForReading else { return }
        let chunk = handle.availableData
        guard !chunk.isEmpty else { return }
        lineBuffer.append(chunk)
        while let range = lineBuffer.firstRange(of: Data([0x0A])) {
            let lineData = lineBuffer.subdata(in: lineBuffer.startIndex..<range.lowerBound)
            lineBuffer.removeSubrange(lineBuffer.startIndex...range.lowerBound)
            guard let line = String(data: lineData, encoding: .utf8), !line.isEmpty else { continue }
            handleStreamLine(line)
        }
    }

    private func handleStreamLine(_ line: String) {
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
        if np?.artwork == nil, np != nil {
            fetchArtworkOnce()
        }
        DispatchQueue.main.async { [weak self] in
            if Self.logMedia, let np {
                let art = np.artwork == nil ? "no art" : "art"
                print("NOWPLAYING: adapter -> \(np.title) / \(np.artist) (\(art))")
            }
            self?.onUpdate?(np)
        }
    }

    private func parseNowPlaying(_ payload: [String: Any]) -> NowPlaying? {
        let title = (payload["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (payload["album"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = [title, album].compactMap { $0 }.first { !$0.isEmpty }
        guard let resolvedTitle else { return nil }

        let artist = (payload["artist"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let playing = payload["playing"] as? Bool
        let rate = payload["playbackRate"] as? Double
        let isPlaying = playing ?? ((rate ?? 1) > 0)
        let artwork = artwork(from: payload, title: resolvedTitle, artist: artist)
        return NowPlaying(
            title: resolvedTitle,
            artist: artist,
            isPlaying: isPlaying,
            artwork: artwork,
            elapsed: parseElapsed(payload),
            duration: parseDuration(payload),
            playbackRate: rate ?? 1,
            timestamp: parseTimestamp(payload)
        )
    }

    private func parseDuration(_ payload: [String: Any]) -> TimeInterval? {
        if let micros = payload["durationMicros"] as? NSNumber {
            return micros.doubleValue / 1_000_000
        }
        if let seconds = payload["duration"] as? NSNumber {
            return seconds.doubleValue
        }
        return nil
    }

    private func parseElapsed(_ payload: [String: Any]) -> TimeInterval? {
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

    private func parseTimestamp(_ payload: [String: Any]) -> Date? {
        if let micros = payload["timestampEpochMicros"] as? NSNumber {
            return Date(timeIntervalSince1970: micros.doubleValue / 1_000_000)
        }
        if let ts = payload["timestamp"] as? NSNumber {
            return Date(timeIntervalSince1970: ts.doubleValue)
        }
        return nil
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

    /// Artwork often arrives after title/elapsed in stream diffs; one `get` fills it in.
    private func fetchArtworkOnce() {
        guard !artworkFetchPending else { return }
        artworkFetchPending = true
        workQueue.async { [weak self] in
            defer { self?.artworkFetchPending = false }
            guard let self, let paths = self.bundledPaths() else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            process.arguments = [paths.script.path, paths.framework.path, "get"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            guard (try? process.run()) != nil else { return }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let np = self.parseNowPlaying(payload), np.artwork != nil else { return }
            DispatchQueue.main.async { self.onUpdate?(np) }
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
