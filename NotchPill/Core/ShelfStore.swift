import AppKit

/// Holds files dropped onto the notch. Items are references (URLs) the user can
/// drag back out to Finder, AirDrop, Mail, etc. Persisted across launches via
/// bookmark data so the shelf survives quit/restart (and file moves/renames).
@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        let icon: NSImage
        var name: String { url.lastPathComponent }

        static func == (lhs: Item, rhs: Item) -> Bool { lhs.id == rhs.id }
    }

    @Published private(set) var items: [Item] = []
    /// True while a valid file drag is hovering the drop area (drives highlight).
    @Published var isDropTargeted = false

    private let defaultsKey = "shelfBookmarks"
    private let defaults: UserDefaults

    /// `defaults` is injectable so tests can use an isolated suite (the test host
    /// shares the app's bundle id / standard defaults otherwise).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(urls: [URL]) {
        var changed = false
        for url in urls where !items.contains(where: { $0.url == url }) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            items.append(Item(url: url, icon: icon))
            changed = true
        }
        if changed { save() }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        let bookmarks: [Data] = items.compactMap { try? $0.url.bookmarkData() }
        defaults.set(bookmarks, forKey: defaultsKey)
    }

    private func load() {
        guard let bookmarks = defaults.array(forKey: defaultsKey) as? [Data] else { return }
        var restored: [Item] = []
        for data in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                     relativeTo: nil, bookmarkDataIsStale: &stale),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            restored.append(Item(url: url, icon: icon))
        }
        items = restored
    }
}
