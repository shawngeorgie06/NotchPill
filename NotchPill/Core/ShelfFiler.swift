import Foundation

enum ShelfFiler {
    struct UndoToken: Equatable {
        let from: URL
        let to: URL
    }

    enum FilingError: Error, Equatable {
        case sourceMissing(URL)
        case destinationUnwritable(URL)
        case destinationNotADirectory(URL)
        case undoConflicted
        case moveFailed(String)
    }

    @discardableResult
    static func file(_ url: URL, into folder: URL) throws -> UndoToken {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FilingError.sourceMissing(url) }
        guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true else {
            if fm.fileExists(atPath: folder.path) { throw FilingError.destinationNotADirectory(folder) }
            throw FilingError.destinationUnwritable(folder)
        }

        let destination = collisionSafeURL(for: url, in: folder, fileExists: fm.fileExists(atPath:))
        do {
            try fm.moveItem(at: url, to: destination)
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain,
               error.code == NSFileWriteNoPermissionError {
                throw FilingError.destinationUnwritable(folder)
            }
            throw FilingError.moveFailed(error.localizedDescription)
        } catch {
            throw FilingError.moveFailed(error.localizedDescription)
        }
        guard !fm.fileExists(atPath: url.path), fm.fileExists(atPath: destination.path) else {
            throw FilingError.moveFailed("The move did not complete")
        }
        return UndoToken(from: url, to: destination)
    }

    static func undo(_ token: UndoToken) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: token.to.path),
              !fm.fileExists(atPath: token.from.path) else {
            throw FilingError.undoConflicted
        }
        do {
            try fm.moveItem(at: token.to, to: token.from)
        } catch {
            throw FilingError.moveFailed(error.localizedDescription)
        }
    }

    static func collisionSafeURL(
        for source: URL,
        in folder: URL,
        fileExists: (String) -> Bool
    ) -> URL {
        let name = source.lastPathComponent
        // Finder treats a leading-dot name such as `.env` as extensionless.
        // URL.pathExtension reports `env` for that shape on some Foundation
        // versions, which would produce the surprising `.env 2`/`.env 3`
        // split as a stem plus suffix.
        let ext = (name.hasPrefix(".") && !name.dropFirst().contains("."))
            ? ""
            : source.pathExtension
        let stem: String
        if ext.isEmpty {
            stem = name
        } else {
            stem = String(name.dropLast(ext.count + 1))
        }
        let suffix = ext.isEmpty ? "" : ".\(ext)"
        var candidate = folder.appendingPathComponent(name)
        var number = 2
        while fileExists(candidate.path) {
            candidate = folder.appendingPathComponent("\(stem) \(number)\(suffix)")
            number += 1
        }
        return candidate
    }
}
