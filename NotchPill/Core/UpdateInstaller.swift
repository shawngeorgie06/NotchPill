import AppKit

/// Downloads a NotchPill release, verifies it, replaces the running app in place,
/// and relaunches — the "fully in-app" update flow. No Terminal, no browser.
///
/// Safety: the downloaded bundle must pass `codesign --verify --deep --strict`,
/// and its signing identity (certificate hash in the designated requirement) must
/// match the currently running app. That prevents a tampered or wrong-identity
/// binary from replacing the installed one. The swap keeps the same code identity
/// so macOS preserves Accessibility/Calendar permissions across the update.
@MainActor
enum UpdateInstaller {
    enum UpdateError: LocalizedError {
        case download
        case unpack
        case notSigned
        case identityMismatch
        case notWritable(String)

        var errorDescription: String? {
            switch self {
            case .download: return "Couldn't download the update."
            case .unpack: return "The downloaded update was not a valid app."
            case .notSigned: return "The downloaded app failed signature verification."
            case .identityMismatch: return "The update is signed by a different identity and was blocked."
            case .notWritable(let path): return "NotchPill can't update itself at \(path). Move it to /Applications and try again."
            }
        }
    }

    private static var isInstalling = false

    /// Downloads, verifies, swaps, and relaunches.
    static func install(_ release: UpdateRelease) {
        guard !isInstalling else { return }
        isInstalling = true

        let destPath = Bundle.main.bundlePath
        // Fail fast if we can't write our own bundle (e.g. a read-only mount) so we
        // never quit the app with no way to relaunch the new one.
        guard FileManager.default.isWritableFile(atPath: destPath),
              FileManager.default.isWritableFile(atPath: (destPath as NSString).deletingLastPathComponent) else {
            isInstalling = false
            fail(.notWritable(destPath), release: release)
            return
        }

        // Live progress bar in the notch (see UpdateProgressStore → NotchState).
        UpdateProgressStore.shared.begin(version: release.version)

        Task {
            do {
                let stagedApp = try await downloadAndStage(release)      // drives .downloading
                UpdateProgressStore.shared.setPhase(.verifying)
                try await verify(stagedApp: stagedApp, matching: destPath)
                UpdateProgressStore.shared.setPhase(.installing)
                // Brief beat so the "Installing…" state is visible before the swap.
                try? await Task.sleep(nanoseconds: 350_000_000)
                UpdateProgressStore.shared.setPhase(.relaunching)
                try? await Task.sleep(nanoseconds: 250_000_000)
                swapAndRelaunch(newApp: stagedApp, destPath: destPath)   // quits the app
            } catch {
                UpdateProgressStore.shared.clear()
                isInstalling = false
                fail((error as? UpdateError) ?? .download, release: release)
            }
        }
    }

    // MARK: - Steps (run off the main actor)

    nonisolated private static func downloadAndStage(_ release: UpdateRelease) async throws -> String {
        // Download with byte-level progress so the notch bar fills in real time.
        let zipDest = try await downloadWithProgress(release.zipURL) { fraction in
            Task { @MainActor in UpdateProgressStore.shared.setDownload(fraction: fraction) }
        }

        // Unpack with ditto (the release ZIPs are produced by `ditto -c -k`).
        let unpackDir = zipDest.deletingLastPathComponent().appendingPathComponent("unpacked")
        _ = try await run("/usr/bin/ditto", ["-x", "-k", zipDest.path, unpackDir.path])

        guard let appPath = firstApp(in: unpackDir.path) else { throw UpdateError.unpack }

        // Downloads via URLSession aren't quarantined, but strip defensively.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appPath])
        return appPath
    }

    /// Downloads a URL to a temp file, reporting 0...1 progress via `onProgress`.
    nonisolated private static func downloadWithProgress(
        _ url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            let onProgress: @Sendable (Double) -> Void
            let destination: URL
            var continuation: CheckedContinuation<URL, Error>?
            private var resumed = false

            init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
                self.destination = destination
                self.onProgress = onProgress
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                            totalBytesExpectedToWrite: Int64) {
                guard totalBytesExpectedToWrite > 0 else { return }
                onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
            }

            func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                            didFinishDownloadingTo location: URL) {
                guard !resumed else { return }
                resumed = true
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                    continuation?.resume(throwing: UpdateError.download)
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation?.resume(returning: destination)
                } catch {
                    continuation?.resume(throwing: error)
                }
            }

            func urlSession(_ session: URLSession, task: URLSessionTask,
                            didCompleteWithError error: Error?) {
                guard !resumed else { return }   // success already handled above
                resumed = true
                continuation?.resume(throwing: error ?? UpdateError.download)
            }
        }

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotchPillUpdate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let dest = work.appendingPathComponent("update.zip")

        let delegate = Delegate(destination: dest, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.downloadTask(with: url).resume()
        }
    }

    nonisolated private static func verify(stagedApp: String, matching destPath: String) async throws {
        // 1. The bundle must be internally consistent and validly signed.
        guard (try? await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp])) != nil else {
            throw UpdateError.notSigned
        }
        // 2. Its signing identity must match the app we're replacing, so a
        //    differently-signed binary can never take over in place.
        let newID = await signingIdentity(of: stagedApp)
        let currentID = await signingIdentity(of: destPath)
        guard let newID, let currentID, newID == currentID else {
            throw UpdateError.identityMismatch
        }
    }

    private static func swapAndRelaunch(newApp: String, destPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        set -e
        # Wait for the running NotchPill to exit before replacing its bundle.
        for _ in $(seq 1 100); do kill -0 \(pid) 2>/dev/null || break; sleep 0.1; done
        BACKUP="\(destPath).old"
        rm -rf "$BACKUP" 2>/dev/null || true
        mv "\(destPath)" "$BACKUP" 2>/dev/null || true
        if /usr/bin/ditto "\(newApp)" "\(destPath)"; then
          /usr/bin/xattr -dr com.apple.quarantine "\(destPath)" 2>/dev/null || true
          rm -rf "$BACKUP" 2>/dev/null || true
        else
          # Restore on failure so the user isn't left without an app.
          rm -rf "\(destPath)" 2>/dev/null || true
          mv "$BACKUP" "\(destPath)" 2>/dev/null || true
        fi
        /usr/bin/open "\(destPath)"
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchpill-update-\(UUID().uuidString).sh")
        guard (try? script.write(to: scriptURL, atomically: true, encoding: .utf8)) != nil else {
            isInstalling = false
            return
        }

        // Launch the swap detached so it outlives this process, then quit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path]
        guard (try? task.run()) != nil else {
            isInstalling = false
            return
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// The certificate-hash portion of a bundle's designated requirement, e.g.
    /// `certificate root = H"b22cbb44…"`, or "adhoc" for an ad-hoc signature.
    nonisolated private static func signingIdentity(of appPath: String) async -> String? {
        guard let dr = try? await run("/usr/bin/codesign", ["-d", "--requirements", "-", appPath],
                                      captureStderr: true) else { return nil }
        if let range = dr.range(of: #"certificate root = H"[0-9a-fA-F]+""#, options: .regularExpression) {
            return String(dr[range])
        }
        if dr.lowercased().contains("adhoc") { return "adhoc" }
        return dr.isEmpty ? nil : "opaque:\(dr.hashValue)"
    }

    nonisolated private static func firstApp(in dir: String) -> String? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        if let direct = items.first(where: { $0.hasSuffix(".app") }) {
            return (dir as NSString).appendingPathComponent(direct)
        }
        // One level deeper (release ZIPs wrap the app in a version folder).
        for item in items {
            let sub = (dir as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: sub, isDirectory: &isDir), isDir.boolValue,
               let nested = (try? fm.contentsOfDirectory(atPath: sub))?.first(where: { $0.hasSuffix(".app") }) {
                return (sub as NSString).appendingPathComponent(nested)
            }
        }
        return nil
    }

    /// Runs a tool asynchronously without blocking the caller's thread.
    nonisolated private static func run(_ launchPath: String, _ args: [String],
                                        captureStderr: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: launchPath)
            task.arguments = args
            let out = Pipe()
            task.standardOutput = out
            task.standardError = captureStderr ? out : Pipe()
            task.terminationHandler = { proc in
                let data = out.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: NSError(domain: "UpdateInstaller",
                                                          code: Int(proc.terminationStatus)))
                }
            }
            do { try task.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - UI

    private static func fail(_ error: UpdateError, release: UpdateRelease) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't install the update"
        alert.informativeText = (error.errorDescription ?? "Update failed.")
            + "\n\nYou can download it from the release page instead."
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }
}
