import AppKit
import Combine
import QuickLookThumbnailing

/// Quick Look thumbnails for the files on the shelf, so a chip shows the
/// screenshot rather than a generic "PNG" icon. A tray that shows its files
/// holds objects; one that shows file-type icons holds a list.
///
/// Generation is asynchronous and the result is published, so a chip draws
/// the file icon first and swaps to the thumbnail when it lands — usually
/// within a frame for an image, a beat for a PDF. Failures are remembered so
/// a file with no thumbnail (a shell script, a folder) is asked about once.
@MainActor
final class ThumbnailStore: ObservableObject {
    static let shared = ThumbnailStore()

    @Published private(set) var thumbnails: [URL: NSImage] = [:]
    private(set) var pending: Set<URL> = []
    private(set) var failed: Set<URL> = []

    init() {}

    func thumbnail(for url: URL) -> NSImage? { thumbnails[url] }

    /// Ask for a thumbnail at `size` points if one is not already known or in
    /// flight. Safe to call from every render.
    func request(_ url: URL, size: CGSize, scale: CGFloat = 2) {
        guard thumbnails[url] == nil, !pending.contains(url), !failed.contains(url) else { return }
        pending.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            // The main *queue*, not a main-actor Task: a queued block is
            // drained by any run of the main loop, including a nested one,
            // where an actor job sat undelivered for as long as the loop ran.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pending.remove(url)
                    if let rep {
                        self.thumbnails[url] = rep.nsImage
                    } else {
                        self.failed.insert(url)
                    }
                }
            }
        }
    }

    /// Forget a file that left the shelf, so a re-added file with new contents
    /// is not shown with its old picture.
    func forget(_ url: URL) {
        thumbnails[url] = nil
        failed.remove(url)
    }
}
