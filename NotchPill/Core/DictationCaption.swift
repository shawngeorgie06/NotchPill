import Foundation

/// The latest thing you dictated, as Murmur records it.
///
/// Murmur (a local voice-to-text app) has an opt-in "Mirror Captions to
/// NotchPill" setting that atomically writes `{text, timestamp}` to
/// `~/Library/Application Support/local-dictation/latest-caption.json` after
/// every transcription. It has been writing that file since July; nothing here
/// ever read it, so the setting broadcast into the void.
///
/// The contract is deliberately thin — a file, not a link between two
/// processes. Murmur is Tauri/Rust and this is Swift/AppKit; a shared file that
/// either side can be missing, stale, or malformed without breaking the other
/// is the right amount of coupling for that.
struct DictationCaption: Equatable {
    var text: String
    var timestamp: Date

    /// Where Murmur writes. `dirs::data_dir()` on macOS is
    /// `~/Library/Application Support`.
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/local-dictation/latest-caption.json")
    }

    /// Milliseconds since the epoch, which is what Murmur writes.
    static func parse(_ data: Data) -> DictationCaption? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object["text"] as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // A number in JSON can decode as Double or Int depending on the writer;
        // accept either rather than silently dropping every caption.
        let millis = (object["timestamp"] as? Double)
            ?? (object["timestamp"] as? Int).map(Double.init)
        guard let millis, millis > 0 else { return nil }
        return DictationCaption(text: String(trimmed.prefix(maxLength)),
                                timestamp: Date(timeIntervalSince1970: millis / 1000))
    }

    /// Longest caption we will take from the file.
    ///
    /// Nothing bounded this. The peek caps its own *lines*, so an enormous
    /// caption did not visibly overflow — it just quietly cost: the title is
    /// now measured with TextKit to size the peek, and that measurement runs
    /// over the whole string several times per layout pass. A multi-megabyte
    /// value would have burned that on every frame the peek was on screen.
    ///
    /// Worth bounding on principle as well as cost. The file lives at a fixed
    /// path under the user's own Application Support, so any process running as
    /// the user can write it — Murmur is the expected author, not a guaranteed
    /// one. This is well past the longest thing anyone dictates in one go, and
    /// the peek's line cap truncates far below it anyway.
    static let maxLength = 4000

    /// Anything older than this is history, not something you just said.
    ///
    /// This exists because of a specific failure: the caption sitting on this
    /// machine was written in July, and without a freshness rule the first
    /// launch after wiring this up would have popped a months-old sentence as
    /// though it had just been spoken. A file that persists across restarts
    /// cannot be treated as an event on its own.
    static let freshWithin: TimeInterval = 20

    /// Whether this caption is news worth showing.
    ///
    /// Pure, because the two ways to get it wrong — replaying an old caption at
    /// launch, and showing the same one twice — are both invisible until they
    /// annoy somebody.
    static func shouldPresent(_ caption: DictationCaption,
                              lastPresented: Date?,
                              now: Date) -> Bool {
        let age = now.timeIntervalSince(caption.timestamp)
        // Negative age means the writer's clock is ahead of ours; that is still
        // a caption that just happened, so it counts as fresh.
        guard age < freshWithin else { return false }
        guard let lastPresented else { return true }
        return caption.timestamp > lastPresented
    }
}
