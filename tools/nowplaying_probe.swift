import AppKit

// Probes what now-playing data is actually reachable on this machine.
typealias GetInfoFn = @convention(c) (DispatchQueue, @escaping (CFDictionary?) -> Void) -> Void
typealias IsPlayingFn = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
typealias GetAppFn = @convention(c) (DispatchQueue, @escaping (CFString?) -> Void) -> Void

let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
guard let handle = dlopen(path, RTLD_LAZY) else { print("dlopen FAILED"); exit(1) }
print("dlopen OK")

func sym(_ name: String) -> UnsafeMutableRawPointer? { dlsym(handle, name) }
print("GetNowPlayingInfo present:", sym("MRMediaRemoteGetNowPlayingInfo") != nil)
print("SendCommand present:", sym("MRMediaRemoteSendCommand") != nil)
print("IsPlaying present:", sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying") != nil)

print("\nRunning media-ish apps:")
for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
    if let id = app.bundleIdentifier,
       ["music","spotify","safari","chrome","brave","firefox","podcast","tv","vlc","arc"].contains(where: { id.lowercased().contains($0) }) {
        print("  -", id)
    }
}

if let s = sym("MRMediaRemoteGetNowPlayingInfo") {
    let getInfo = unsafeBitCast(s, to: GetInfoFn.self)
    getInfo(.main) { info in
        print("\nGetNowPlayingInfo returned:", info == nil ? "nil" : "dict")
        if let dict = info as? [String: Any] {
            print("  keys count:", dict.count)
            for (k, v) in dict.sorted(by: { $0.key < $1.key }) {
                if let data = v as? Data { print("  \(k): <\(data.count) bytes>") }
                else { print("  \(k): \(v)") }
            }
        }
        exit(0)
    }
}
if let s = sym("MRMediaRemoteGetNowPlayingApplicationIsPlaying") {
    let isPlaying = unsafeBitCast(s, to: IsPlayingFn.self)
    isPlaying(.main) { playing in print("IsPlaying:", playing) }
}
RunLoop.main.run(until: Date().addingTimeInterval(3))
print("(timed out waiting for info callback)")
exit(0)
