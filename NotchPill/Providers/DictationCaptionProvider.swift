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
        lastPresented = currentCaption()?.timestamp
        lastModified = modificationDate()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func poll(now: Date = Date()) {
        // Cheap gate first: no write, nothing to parse.
        let modified = modificationDate()
        guard modified != lastModified else { return }
        lastModified = modified

        guard let caption = currentCaption() else { return }
        guard DictationCaption.shouldPresent(caption,
                                             lastPresented: lastPresented,
                                             now: now) else { return }
        lastPresented = caption.timestamp
        LogStore.log("dictation", "caption \(caption.text.count) chars")
        onCaption?(caption)
    }

    private func currentCaption() -> DictationCaption? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return DictationCaption.parse(data)
    }

    private func modificationDate() -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}
