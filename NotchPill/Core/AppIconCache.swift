import AppKit

/// The icons of the apps agents run in, looked up once per bundle id.
///
/// `NSWorkspace.urlForApplication` walks Launch Services and `icon(forFile:)`
/// decodes an icon family; both are fine once and not fine on every render of
/// a tile strip that redraws whenever a status age ticks. A miss is cached too,
/// so an agent whose app is not installed does not repeat the search.
final class AppIconCache: @unchecked Sendable {
    static let shared = AppIconCache()

    init() {}

    private let lock = NSLock()
    private var icons: [String: NSImage?] = [:]

    /// The first candidate that resolves to an installed app, in order — so a
    /// caller lists the app it means first and the app that ships the same
    /// tool second.
    func icon(forAnyOf bundleIds: [String]) -> NSImage? {
        for id in bundleIds {
            if let icon = icon(bundleId: id) { return icon }
        }
        return nil
    }

    func icon(bundleId: String) -> NSImage? {
        lock.lock()
        if let cached = icons[bundleId] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        lock.lock()
        icons[bundleId] = icon
        lock.unlock()
        return icon
    }
}
