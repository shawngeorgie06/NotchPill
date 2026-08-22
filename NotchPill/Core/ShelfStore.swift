import AppKit

struct ShelfFilingReceipt: Equatable {
    let token: ShelfFiler.UndoToken
    let destinationName: String
    let itemName: String
    let expiresAt: Date
}

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
    @Published private(set) var receipt: ShelfFilingReceipt?
    @Published private(set) var lastError: String?
    /// True while a valid file drag is hovering the drop area (drives highlight).
    @Published var isDropTargeted = false

    private let defaultsKey = "shelfBookmarks"
    private let defaults: UserDefaults
    private var receiptTimer: Timer?
    private var errorTimer: Timer?

    /// `defaults` is injectable so tests can use an isolated suite (the test host
    /// shares the app's bundle id / standard defaults otherwise).
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    func add(urls: [URL]) {
        var added = 0
        for url in urls where !items.contains(where: { $0.url == url }) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            items.append(Item(url: url, icon: icon))
            added += 1
        }
        if added > 0 {
            save()
            clearError()
            return
        }
        // Every dropped file was already here. Saying nothing makes a working
        // drop look identical to a broken one — the drop lands, the shelf does
        // not change, and there is no way to tell which happened.
        guard !urls.isEmpty else { return }
        let name = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        setNotice("Already on the shelf — \(name)")
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func fileItem(id: UUID, into folder: URL) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        do {
            let token = try ShelfFiler.file(item.url, into: folder)
            items.removeAll { $0.id == id }
            save()
            receipt = ShelfFilingReceipt(
                token: token,
                destinationName: folder.lastPathComponent,
                itemName: item.name,
                expiresAt: .now.addingTimeInterval(10)
            )
            scheduleReceiptExpiry()
            clearError()
        } catch let error as ShelfFiler.FilingError {
            setError(humanMessage(for: error))
        } catch {
            setError("Couldn't move — \(error.localizedDescription)")
        }
    }

    func undoLastFiling() {
        guard let receipt else { return }
        do {
            try ShelfFiler.undo(receipt.token)
            let icon = NSWorkspace.shared.icon(forFile: receipt.token.from.path)
            items.append(Item(url: receipt.token.from, icon: icon))
            save()
            self.receipt = nil
            receiptTimer?.invalidate()
            clearError()
        } catch let error as ShelfFiler.FilingError {
            setError(humanMessage(for: error))
        } catch {
            setError("Couldn't undo — \(error.localizedDescription)")
        }
    }

    func dismissReceipt() {
        receiptTimer?.invalidate()
        receipt = nil
    }

    private func scheduleReceiptExpiry() {
        receiptTimer?.invalidate()
        receiptTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.dismissReceipt() }
        }
    }

    /// Same channel as an error — it is the "your drop did nothing" line — but
    /// it is not a failure, so it clears sooner.
    private func setNotice(_ message: String) {
        lastError = message
        errorTimer?.invalidate()
        errorTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lastError = nil }
        }
    }

    private func setError(_ message: String) {
        lastError = message
        errorTimer?.invalidate()
        errorTimer = Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.lastError = nil }
        }
    }

    private func clearError() {
        errorTimer?.invalidate()
        errorTimer = nil
        lastError = nil
    }

    private func humanMessage(for error: ShelfFiler.FilingError) -> String {
        switch error {
        case .sourceMissing: return "Couldn't move — file is no longer there"
        case .destinationUnwritable: return "Couldn't move — permission denied"
        case .destinationNotADirectory: return "Couldn't move — destination is not a folder"
        case .undoConflicted: return "Couldn't undo — the file changed"
        case .moveFailed(let message): return "Couldn't move — \(message)"
        }
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
