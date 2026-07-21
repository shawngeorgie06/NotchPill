import AppKit

/// Reads now-playing metadata and drives transport commands.
///
/// Primary path: the private MediaRemote framework (covers Music, Spotify,
/// browsers, etc.). Apple gated `MRMediaRemoteGetNowPlayingInfo` for third-party
/// apps starting in macOS 15.4, so when MediaRemote yields nothing we fall back
/// to querying a *running* Music or Spotify instance via AppleScript. We never
/// launch a player just to read state.
final class NowPlayingProvider {
    var onUpdate: ((NowPlaying?) -> Void)?

    // MediaRemote entry points, resolved at runtime.
    // The handlers are invoked asynchronously on the given queue, so they must
    // be @escaping; Swift bridges them to Objective-C blocks automatically.
    private typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
    private typealias RegisterFn = @convention(c) (DispatchQueue) -> Void
    private typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
    private typealias SendCommandFn = @convention(c) (Int, CFDictionary?) -> Bool

    private var getInfo: GetInfoFn?
    private var register: RegisterFn?
    private var isPlayingFn: IsPlayingFn?
    private var sendCommand: SendCommandFn?
    private var mrHandle: UnsafeMutableRawPointer?

    private var fallbackTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []
    private let scriptQueue = DispatchQueue(label: "notchpill.nowplaying.applescript")
    private var lastDelivered: NowPlaying?
    // Compiled AppleScripts are cached so the fallback poll doesn't recompile on
    // every tick. Accessed only on `scriptQueue`.
    private var compiledScripts: [String: NSAppleScript] = [:]
    // Artwork is cached by URL so we don't re-download every poll. `scriptQueue`.
    private var lastArtworkURL: String?
    private var lastArtworkImage: NSImage?

    // Dictionary keys exported by MediaRemote (their CFString values equal these
    // literal symbol names, so we can index directly).
    private let kTitle = "kMRMediaRemoteNowPlayingInfoTitle"
    private let kArtist = "kMRMediaRemoteNowPlayingInfoArtist"
    private let kArtwork = "kMRMediaRemoteNowPlayingInfoArtworkData"
    private let kPlaybackRate = "kMRMediaRemoteNowPlayingInfoPlaybackRate"

    // MRMediaRemoteCommand values.
    private enum Command: Int { case play = 0, pause = 1, togglePlayPause = 2, next = 4, previous = 5 }

    func start() {
        loadMediaRemote()
        register?(.main)
        // MediaRemote posts to the default center after registration. These
        // notifications are the primary, event-driven update path.
        let center = NotificationCenter.default
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            center.addObserver(self, selector: #selector(mediaRemoteChanged),
                               name: Notification.Name(name), object: nil)
        }

        // The AppleScript fallback has no notifications, so it needs polling —
        // but only while a scriptable player is actually running. We start/stop
        // that timer from workspace launch/quit events instead of polling 24/7.
        let wsCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didActivateApplicationNotification] {
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.updateFallbackPolling()
            }
            workspaceObservers.append(obs)
        }

        poll()
        updateFallbackPolling()
    }

    func stop() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
        NotificationCenter.default.removeObserver(self)
        let wsCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach { wsCenter.removeObserver($0) }
        workspaceObservers.removeAll()
        if let mrHandle { dlclose(mrHandle) }
    }

    @objc private func mediaRemoteChanged() { poll() }

    /// Runs the fallback poll timer only while a scriptable player is up.
    private func updateFallbackPolling() {
        let playerRunning = runningPlayerBundleID() != nil
        if playerRunning, fallbackTimer == nil {
            fallbackTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.poll()
            }
            poll() // reflect the newly launched player immediately
        } else if !playerRunning, fallbackTimer != nil {
            fallbackTimer?.invalidate()
            fallbackTimer = nil
            poll() // let MediaRemote (or emptiness) settle the state
        }
    }

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        mrHandle = handle
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getInfo = unsafeBitCast(sym, to: GetInfoFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications") {
            register = unsafeBitCast(sym, to: RegisterFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
            isPlayingFn = unsafeBitCast(sym, to: IsPlayingFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommand = unsafeBitCast(sym, to: SendCommandFn.self)
        }
    }

    // MARK: - Reading

    private func poll() {
        guard let getInfo else {
            deliverFallback()
            return
        }
        getInfo(.main) { [weak self] info in
            guard let self else { return }
            guard let dict = info as? [String: Any],
                  let title = dict[self.kTitle] as? String, !title.isEmpty else {
                // MediaRemote returned nothing usable (likely gated) — try a
                // running local player instead.
                self.deliverFallback()
                return
            }
            let artist = dict[self.kArtist] as? String ?? ""
            let rate = dict[self.kPlaybackRate] as? Double ?? 1.0
            var artwork: NSImage?
            if let data = dict[self.kArtwork] as? Data { artwork = NSImage(data: data) }
            let np = NowPlaying(title: title, artist: artist, isPlaying: rate > 0, artwork: artwork)
            self.deliver(np)
        }
    }

    /// Queries a running Music/Spotify instance without launching it.
    private func deliverFallback() {
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let np = self.readRunningPlayer()
            DispatchQueue.main.async { self.deliver(np) }
        }
    }

    private func deliver(_ np: NowPlaying?) {
        if np == lastDelivered { return }
        lastDelivered = np
        onUpdate?(np)
    }

    private func runningPlayerBundleID() -> String? {
        let running = NSWorkspace.shared.runningApplications.map { $0.bundleIdentifier }
        for id in ["com.apple.Music", "com.spotify.client"] where running.contains(id) {
            return id
        }
        return nil
    }

    private func readRunningPlayer() -> NowPlaying? {
        guard let bundleID = runningPlayerBundleID() else { return nil }
        let isSpotify = (bundleID == "com.spotify.client")
        let appName = isSpotify ? "Spotify" : "Music"
        guard let script = infoScript(for: appName, includeArtworkURL: isSpotify) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let output = result.stringValue, !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        var artwork: NSImage?
        if parts.count >= 4, !parts[3].isEmpty {
            artwork = artworkImage(forURLString: parts[3])
        }
        return NowPlaying(title: parts[1], artist: parts[2],
                          isPlaying: parts[0] == "playing", artwork: artwork)
    }

    /// Downloads and caches artwork by URL (called only on `scriptQueue`).
    private func artworkImage(forURLString urlString: String) -> NSImage? {
        if urlString == lastArtworkURL { return lastArtworkImage }
        guard let url = URL(string: urlString) else { return nil }
        let image = NSImage(contentsOf: url)
        lastArtworkURL = urlString
        lastArtworkImage = image
        return image
    }

    /// Returns a compiled, cached now-playing query script for the given app.
    /// Called only on `scriptQueue`. NB: the variable must not be named `st` —
    /// that is a reserved ordinal token in AppleScript and won't compile.
    private func infoScript(for appName: String, includeArtworkURL: Bool) -> NSAppleScript? {
        if let cached = compiledScripts[appName] { return cached }
        let artLine = includeArtworkURL ? " & linefeed & (artwork url of current track)" : ""
        let source = """
        tell application "\(appName)"
            set pstate to (player state as text)
            if pstate is "playing" or pstate is "paused" then
                return pstate & linefeed & (name of current track) & linefeed & (artist of current track)\(artLine)
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
        if let sendCommand, sendCommand(command.rawValue, nil) { return }
        // MediaRemote unavailable or refused — drive the running player directly.
        scriptQueue.async { [weak self] in
            guard let self, let bundleID = self.runningPlayerBundleID() else { return }
            let appName = (bundleID == "com.spotify.client") ? "Spotify" : "Music"
            self.runAppleScript("tell application \"\(appName)\" to \(verb)")
            DispatchQueue.main.async { self.poll() }
        }
    }
}
