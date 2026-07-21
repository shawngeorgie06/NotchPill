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

    private var pollTimer: Timer?
    private let scriptQueue = DispatchQueue(label: "notchpill.nowplaying.applescript")
    private var lastDelivered: NowPlaying?

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
        // MediaRemote posts to the default center after registration.
        let center = NotificationCenter.default
        for name in ["kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                     "kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification"] {
            center.addObserver(self, selector: #selector(mediaRemoteChanged),
                               name: Notification.Name(name), object: nil)
        }
        poll()
        // Backstop poll: covers the AppleScript fallback where notifications
        // don't fire, and catches missed MediaRemote updates.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        NotificationCenter.default.removeObserver(self)
        if let mrHandle { dlclose(mrHandle) }
    }

    @objc private func mediaRemoteChanged() { poll() }

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
        let appName = (bundleID == "com.spotify.client") ? "Spotify" : "Music"
        let script = """
        tell application "\(appName)"
            set st to (player state as text)
            if st is "playing" or st is "paused" then
                return st & "\\n" & (name of current track) & "\\n" & (artist of current track)
            end if
            return ""
        end tell
        """
        guard let output = runAppleScript(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 3 else { return nil }
        return NowPlaying(title: parts[1], artist: parts[2],
                          isPlaying: parts[0] == "playing", artwork: nil)
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
