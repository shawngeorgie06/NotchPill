import Foundation
import Combine

struct FileDestination: Identifiable, Equatable, Hashable {
    enum Source: Equatable { case pinned, recent }

    let url: URL
    let source: Source
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

@MainActor
final class DestinationStore: ObservableObject {
    static let shared = DestinationStore()

    @Published private(set) var pinned: [URL] = []

    private let defaults: UserDefaults
    private let recents: () -> [URL]
    private let defaultsKey = "shelfPinnedFolders"
    /// Last known bookmark per pinned folder, so `save()` can preserve entries
    /// that cannot be re-bookmarked right now.
    private var storedBookmarks: [URL: Data] = [:]

    init(
        defaults: UserDefaults = .standard,
        recents: @escaping () -> [URL] = { FinderRecentFolders.load() }
    ) {
        self.defaults = defaults
        self.recents = recents
        load()
    }

    func destinations() -> [FileDestination] {
        let pinnedURLs = pinned.filter { isDirectory($0) }
        let pinnedSet = Set(pinnedURLs)
        let recentURLs = recents().filter { isDirectory($0) && !pinnedSet.contains($0) }
        return pinnedURLs.map { FileDestination(url: $0, source: .pinned) }
            + recentURLs.prefix(6).map { FileDestination(url: $0, source: .recent) }
    }

    func pin(_ url: URL) {
        guard isDirectory(url), !pinned.contains(url) else { return }
        pinned.append(url)
        save()
    }

    func unpin(_ url: URL) {
        pinned.removeAll { $0 == url }
        save()
    }

    func movePinned(from offsets: IndexSet, to destination: Int) {
        pinned.move(fromOffsets: offsets, toOffset: destination)
        save()
    }

    private func isDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { return false }
        return values.isDirectory == true
    }

    /// Re-uses the bookmark a folder was loaded/pinned with when a fresh one
    /// cannot be made. `bookmarkData()` throws for anything on an unmounted
    /// volume, and dropping those would forget the pin the moment the user
    /// pinned something else — an ejected disk should come back, not vanish.
    private func save() {
        let data: [Data] = pinned.compactMap { url in
            if let fresh = try? url.bookmarkData() {
                storedBookmarks[url] = fresh
                return fresh
            }
            return storedBookmarks[url]
        }
        defaults.set(data, forKey: defaultsKey)
    }

    private func load() {
        guard let bookmarks = defaults.array(forKey: defaultsKey) as? [Data] else { return }
        var urls: [URL] = []
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            storedBookmarks[url] = data
            urls.append(url)
        }
        pinned = urls
    }
}
