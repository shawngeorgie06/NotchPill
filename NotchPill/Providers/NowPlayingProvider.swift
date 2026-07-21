import AppKit

/// Reads now-playing metadata and drives transport commands.
///
/// Primary path: mediaremote-adapter via `/usr/bin/perl` (works on macOS 15.4+
/// where direct MediaRemote calls from signed apps return nil). Falls back to
/// AppleScript for Music/Spotify when the adapter is unavailable.
final class NowPlayingProvider {
    var onUpdate: ((NowPlaying?) -> Void)?

    private let bridge = MediaRemoteBridge()
    private let scriptQueue = DispatchQueue(label: "notchpill.nowplaying.applescript")
    private var lastDelivered: NowPlaying?
    private var compiledScripts: [String: NSAppleScript] = [:]
    private var lastArtworkURL: String?
    private var lastArtworkImage: NSImage?
    private var pollTimer: Timer?

    private static let scriptableBundleIDs: Set<String> = [
        "com.apple.Music",
        "com.spotify.client",
    ]

    private enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5 }

    func start() {
        bridge.onUpdate = { [weak self] np in self?.deliver(np) }
        bridge.start()

        // Poll AppleScript fallback when adapter isn't bundled (e.g. dev without build script).
        startPollTimer()
        pollAppleScriptFallbackIfNeeded()
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        bridge.stop()
    }

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.pollAppleScriptFallbackIfNeeded()
        }
        if let pollTimer {
            RunLoop.main.add(pollTimer, forMode: .common)
        }
    }

    /// Only used when the adapter bundle is missing; Music/Spotify via AppleScript.
    private func pollAppleScriptFallbackIfNeeded() {
        guard bridgeIsUnavailable else { return }
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let np = self.readScriptablePlayer()
            DispatchQueue.main.async { self.deliver(np) }
        }
    }

    private var bridgeIsUnavailable: Bool {
        let resources = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        return !FileManager.default.fileExists(atPath: resources.appendingPathComponent("mediaremote-adapter.pl").path)
    }

    private func deliver(_ np: NowPlaying?) {
        if shouldSkipDelivery(np) { return }
        lastDelivered = np
        onUpdate?(np)
    }

    /// Equatable ignores artwork identity; still push when artwork newly appears or changes.
    private func shouldSkipDelivery(_ np: NowPlaying?) -> Bool {
        guard np == lastDelivered else { return false }
        switch (lastDelivered?.artwork, np?.artwork) {
        case (nil, nil), (.some, .some) where lastDelivered?.artwork === np?.artwork:
            return true
        default:
            return false
        }
    }

    private func readScriptablePlayer() -> NowPlaying? {
        for bundleID in Self.scriptableBundleIDs {
            let isSpotify = (bundleID == "com.spotify.client")
            let appName = isSpotify ? "Spotify" : "Music"
            guard let script = infoScript(for: appName, includeArtworkURL: isSpotify) else { continue }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            guard error == nil, let output = result.stringValue, !output.isEmpty else { continue }
            let parts = output.components(separatedBy: "\n")
            guard parts.count >= 3 else { continue }
            var artwork: NSImage?
            var elapsed: TimeInterval?
            var duration: TimeInterval?
            if parts.count >= 5 {
                elapsed = TimeInterval(parts[3])
                duration = TimeInterval(parts[4])
            }
            let artIndex = isSpotify ? 5 : 3
            if isSpotify, parts.count >= 6, !parts[artIndex].isEmpty {
                artwork = artworkImage(forURLString: parts[artIndex])
            }
            return NowPlaying(
                title: parts[1],
                artist: parts[2],
                isPlaying: parts[0] == "playing",
                artwork: artwork,
                elapsed: elapsed,
                duration: duration,
                playbackRate: parts[0] == "playing" ? 1 : 0,
                timestamp: Date()
            )
        }
        return nil
    }

    private func artworkImage(forURLString urlString: String) -> NSImage? {
        if urlString == lastArtworkURL { return lastArtworkImage }
        guard let url = URL(string: urlString) else { return nil }
        let image = NSImage(contentsOf: url)
        lastArtworkURL = urlString
        lastArtworkImage = image
        return image
    }

    private func infoScript(for appName: String, includeArtworkURL: Bool) -> NSAppleScript? {
        if let cached = compiledScripts[appName] { return cached }
        let artLine = includeArtworkURL ? " & linefeed & (artwork url of current track)" : ""
        let source = """
        tell application "\(appName)"
            set pstate to (player state as text)
            if pstate is "playing" or pstate is "paused" then
                return pstate & linefeed & (name of current track) & linefeed & (artist of current track) & linefeed & (player position) & linefeed & (duration of current track)\(artLine)
            end if
            return ""
        end tell
        """
        guard let script = NSAppleScript(source: source) else { return nil }
        compiledScripts[appName] = script
        return script
    }

    @discardableResult
    private func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return result.stringValue
    }

    // MARK: - Transport commands

    func togglePlayPause() { command(.togglePlayPause, appleScript: "playpause") }
    func next() { command(.next, appleScript: "next track") }
    func previous() { command(.previous, appleScript: "previous track") }

    private func command(_ command: Command, appleScript verb: String) {
        if bridge.send(command: command.rawValue) { return }
        scriptQueue.async { [weak self] in
            guard let self else { return }
            for bundleID in Self.scriptableBundleIDs {
                let appName = (bundleID == "com.spotify.client") ? "Spotify" : "Music"
                if self.runAppleScript("tell application \"\(appName)\" to \(verb)") != nil { break }
            }
        }
    }
}
