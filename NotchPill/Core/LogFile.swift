import Foundation

/// An opt-in copy of the log on disk.
///
/// `LogStore` is in memory on purpose, and that choice is right for the case it
/// was written for: reproduce the problem, then look. It is exactly wrong for
/// the case that keeps costing real time — a problem on somebody else's Mac.
/// A bug reported by a user two states away cannot be reproduced on demand, and
/// asking them to keep a window open until it happens again has a poor success
/// rate. By the time they think to look, the app has been restarted and the
/// history is gone.
///
/// So: off by default, and when switched on it writes the same lines the window
/// shows into a file the user can attach to a message. The privacy promise the
/// in-memory design was protecting is kept by other means — the directory and
/// the file are owner-only, every line goes through `SecretRedactor` first, and
/// nothing starts being written until someone deliberately turns it on.
enum LogFile {
    /// Small enough to paste or attach without thinking about it, large enough
    /// to hold the run-up to a bug rather than just its aftermath.
    static let maxBytes = 512 * 1024

    /// Whether appending `adding` bytes would push the file past the cap.
    ///
    /// Pure so the arithmetic is tested rather than discovered when a log
    /// quietly grows to a gigabyte on someone's laptop.
    static func shouldRotate(currentBytes: Int, adding: Int) -> Bool {
        currentBytes > 0 && currentBytes + adding > maxBytes
    }

    static var directory: URL { PrivateStore.root.appendingPathComponent("log") }
    static var url: URL { directory.appendingPathComponent("notchpill.log") }
    /// One generation back. Two files bound the disk cost at ~1MB while still
    /// surviving a rotation that happens moments before the interesting part.
    static var previousURL: URL { directory.appendingPathComponent("notchpill.1.log") }

    /// Appends one already-formatted line. Best-effort by design: logging must
    /// never be the reason the app misbehaves, so every failure here is
    /// swallowed rather than surfaced.
    static func append(_ line: String) {
        let safe = SecretRedactor.redact(line) + "\n"
        let data = Data(safe.utf8)
        PrivateStore.makeDirectory(directory)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let existing = (attributes?[.size] as? Int) ?? 0
        if shouldRotate(currentBytes: existing, adding: data.count) {
            try? FileManager.default.removeItem(at: previousURL)
            try? FileManager.default.moveItem(at: url, to: previousURL)
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // Permissions are re-applied on every write, not just at creation:
        // rotation makes a new file, and a 0644 log is exactly the mistake this
        // whole design is trying not to make.
        PrivateStore.prepareFile(url)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Both generations, oldest first — what to hand to someone debugging.
    static func combinedText() -> String {
        [previousURL, url]
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined()
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: previousURL)
    }
}
