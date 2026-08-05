import Foundation

/// Creates everything under `~/.notchpill` owner-only.
///
/// The directory and its files were left to the process umask, which on a
/// stock Mac means `0755` directories and `0644` files. What lands in there is
/// not innocuous: `agents.log` carries agent activity — session ids, working
/// directories, the first line of what an agent last said — and the peek log
/// carries notification titles and subtitles verbatim. On a shared Mac every
/// other local account could read all of it.
///
/// Nothing here defends against code already running *as* this user; that code
/// can read the files whatever their mode. The threat this closes is the other
/// account on the machine.
enum PrivateStore {
    /// `~/.notchpill`.
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".notchpill")
    }

    /// Creates `directory` and any missing parents, owner-only.
    ///
    /// `withIntermediateDirectories` applies the attributes to every level it
    /// creates, and an existing directory keeps whatever mode it already had —
    /// which is why `tighten` exists and is called on the ones that predate
    /// this.
    @discardableResult
    static func makeDirectory(_ directory: URL) -> Bool {
        let created = (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])) != nil
        tighten(directory, to: 0o700)
        return created
    }

    /// Narrows an existing path that was created before this rule, or by a
    /// hook script running under a different umask. Best-effort: a path owned
    /// by someone else cannot be changed, and failing to is not a reason to
    /// stop working.
    static func tighten(_ url: URL, to permissions: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: permissions],
                                               ofItemAtPath: url.path)
    }

    /// Ensures a log file exists and is `0600` before anything is appended.
    ///
    /// Called on the write path rather than once at launch on purpose: these
    /// files are recreated whenever they are rotated away, and a rotation that
    /// silently restored `0644` would undo this without anything noticing.
    static func prepareFile(_ url: URL) {
        makeDirectory(url.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil,
                                           attributes: [.posixPermissions: 0o600])
        } else {
            tighten(url, to: 0o600)
        }
    }
}
