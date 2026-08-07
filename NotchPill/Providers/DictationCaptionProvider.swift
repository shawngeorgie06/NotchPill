import Foundation

/// Watches Murmur's caption file and reports anything newly dictated.
///
/// Polled rather than watched with FSEvents, matching `DevReadyProvider`: the
/// file is under a hundred bytes, the poll checks the modification date before
/// reading anything, and a dropped FSEvent would silently disable the feature
/// in a way nobody would notice for weeks.
@MainActor
final class DictationCaptionProvider {
    var onCaption: ((DictationCaption) -> Void)?

    private let url: URL
    private var pollTimer: Timer?
    private var lastModified: Date?
    private var lastPresented: Date?

    init(url: URL = DictationCaption.fileURL) {
        self.url = url
    }

    func start() {
        // Whatever is in the file at launch is history — a caption from the
        // last session, or from July. Recording its timestamp without showing
        // it means the first peek is something the user actually just said.
        let modified = modificationDate()
        lastPresented = currentCaption()?.timestamp
        lastModified = modified
        // ...and then it goes. A caption we have decided not to show is speech
        // with no remaining purpose, and the whole point of consuming is that
        // it should not outlive that decision.
        consume(unchangedSince: modified)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Internal rather than private so a test can drive it directly with a
    /// controlled `now`, which is the only reason it takes one.
    func poll(now: Date = Date()) {
        // Cheap gate first: no write, nothing to parse.
        let modified = modificationDate()
        guard modified != lastModified else { return }
        lastModified = modified

        guard let caption = currentCaption() else { return }
        // Consume regardless of whether it gets shown: a caption too stale to
        // present is exactly the kind we least want left on disk.
        defer { consume(unchangedSince: modified) }
        guard DictationCaption.shouldPresent(caption,
                                             lastPresented: lastPresented,
                                             now: now) else { return }
        lastPresented = caption.timestamp
        LogStore.log("dictation", "caption \(caption.text.count) chars")
        onCaption?(caption)
    }

    /// Delete the caption now that it has been read.
    ///
    /// The file is a mailbox, not a store: it holds one record, Murmur
    /// overwrites it on every dictation, and NotchPill is its only reader. Left
    /// alone it means the last thing you said sits on disk indefinitely between
    /// dictations — owner-only, but still there, and still in backups. Reading
    /// it and then removing it drops that from forever to the length of one
    /// poll interval.
    ///
    /// Guarded on the modification date so a caption Murmur wrote in the gap
    /// between our read and this delete is not thrown away unseen. The guard is
    /// a narrowing, not a lock — there is no way to make check-then-delete
    /// atomic across two processes — but the window is microseconds against a
    /// writer that fires at most once per utterance, and losing that race costs
    /// one missed caption rather than anything unrecoverable.
    private func consume(unchangedSince modified: Date?) {
        guard modified != nil, modificationDate() == modified else { return }
        try? FileManager.default.removeItem(at: url)
        // The file is gone, so the next poll must not compare against the
        // mtime of something that no longer exists.
        lastModified = nil
    }

    private func currentCaption() -> DictationCaption? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DictationCaption.parse(data)
    }

    private func modificationDate() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
