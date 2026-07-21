import AppKit

/// Holds files dropped onto the notch. Items are references (URLs) the user can
/// drag back out to Finder, AirDrop, Mail, etc. Kept in memory for the session;
/// persistence via security-scoped bookmarks is a future addition.
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

    func add(urls: [URL]) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            items.append(Item(url: url, icon: icon))
        }
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }
}
