import Foundation

/// Finder's "Recent Folders" list, read from its own defaults domain.
enum FinderRecentFolders {
    static let defaultsKey = "FXRecentFolders"

    static func load(
        defaults: UserDefaults? = UserDefaults(suiteName: "com.apple.finder"),
        limit: Int = 6
    ) -> [URL] {
        guard limit > 0,
              let rawEntries = defaults?.array(forKey: defaultsKey) else {
            return []
        }

        var result: [URL] = []
        for case let entry as [String: Any] in rawEntries {
            guard let data = entry["file-bookmark"] as? Data else { continue }
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ),
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
            values.isDirectory == true else {
                continue
            }
            result.append(url.standardizedFileURL)
            if result.count == limit { break }
        }
        return result
    }
}
