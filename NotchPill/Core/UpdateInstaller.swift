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
        case bundleIdentifierMismatch
        case versionMismatch(expected: String, actual: String?)
        case notWritable(String)
        case scriptCreation(String)
        case scriptLaunch(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .download: return "Couldn't download the update."
            case .unpack: return "The downloaded update was not a valid app."
            case .notSigned: return "The downloaded app failed signature verification."
            case .identityMismatch: return "The update is signed by a different identity and was blocked."
            case .bundleIdentifierMismatch: return "The update is not the stable NotchPill app and was blocked."
            case .versionMismatch(let expected, let actual):
                return "The downloaded app version does not match the release (expected \(expected), found \(actual ?? "unknown"))."
            case .notWritable(let path): return "NotchPill can't update itself at \(path). Move it to /Applications and try again."
            case .scriptCreation(let detail): return "Couldn't prepare the update installer: \(detail)"
            case .scriptLaunch(let detail): return "Couldn't launch the update installer: \(detail)"
            case .commandFailed(let detail): return "The update utility failed: \(detail)"
            }
        }
    }

    private static var isInstalling = false

    private struct StagedUpdate: Sendable {
        let appPath: String
        let stagingDirectory: URL
    }

    /// Downloads, verifies, swaps, and relaunches.
    static func install(_ release: UpdateRelease) {
        guard UpdateChecker.shared.allowsSelfUpdate,
              Bundle.main.bundleIdentifier == UpdateChecker.stableBundleIdentifier else {
            UpdateProgressStore.shared.clear()
            return
        }
        guard UpdateChecker.isTrustedDownload(release.zipURL) else {
            fail(.download, release: release)
            return
        }
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
            var stagingDirectory: URL?
            do {
                let staged = try await downloadAndStage(release)         // drives .downloading
                stagingDirectory = staged.stagingDirectory
                UpdateProgressStore.shared.setPhase(.verifying)
                try await verify(stagedApp: staged.appPath, matching: destPath,
                                 expectedBundleIdentifier: UpdateChecker.stableBundleIdentifier,
                                 expectedVersion: release.version)
                UpdateProgressStore.shared.setPhase(.installing)
                // Brief beat so the "Installing…" state is visible before the swap.
                try? await Task.sleep(nanoseconds: 350_000_000)
                UpdateProgressStore.shared.setPhase(.relaunching)
                try? await Task.sleep(nanoseconds: 250_000_000)
                try swapAndRelaunch(newApp: staged.appPath, destPath: destPath,
                                    stagingDirectory: staged.stagingDirectory) // quits the app
            } catch {
                if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
                UpdateProgressStore.shared.clear()
                isInstalling = false
                fail(error as? UpdateError ?? .download, release: release)
            }
        }
    }

    // MARK: - Steps (run off the main actor)

    nonisolated private static func downloadAndStage(_ release: UpdateRelease) async throws -> StagedUpdate {
        // Download with byte-level progress so the notch bar fills in real time.
        let zipDest = try await downloadWithProgress(release.zipURL) { fraction in
            Task { @MainActor in UpdateProgressStore.shared.setDownload(fraction: fraction) }
        }

        let stagingDirectory = zipDest.deletingLastPathComponent()
        do {
            // Unpack with ditto (the release ZIPs are produced by `ditto -c -k`).
            let unpackDir = stagingDirectory.appendingPathComponent("unpacked")
            _ = try await run("/usr/bin/ditto", ["-x", "-k", zipDest.path, unpackDir.path])

            guard let appPath = firstApp(in: unpackDir.path) else { throw UpdateError.unpack }

            // Downloads via URLSession aren't quarantined, but strip defensively.
            _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appPath])
            return StagedUpdate(appPath: appPath, stagingDirectory: stagingDirectory)
        } catch {
            try? FileManager.default.removeItem(at: stagingDirectory)
            throw error
        }
    }

    /// Used for every redirect before URLSession follows it.
    nonisolated static func allowsDownloadRedirect(_ request: URLRequest) -> Bool {
        request.url.map(UpdateChecker.isTrustedDownload) ?? false
    }

    /// Only a complete, trusted HTTP response may enter staging.
    nonisolated static func acceptsDownloadResponse(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200, let url = http.url else { return false }
        return UpdateChecker.isTrustedDownload(url)
    }

    /// Downloads a URL to a temp file, reporting 0...1 progress via `onProgress`.
    nonisolated private static func downloadWithProgress(
        _ url: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        guard UpdateChecker.isTrustedDownload(url) else { throw UpdateError.download }
        final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
            let onProgress: @Sendable (Double) -> Void
            let destination: URL
            var continuation: CheckedContinuation<URL, Error>?
            private var resumed = false

            init(destination: URL, onProgress: @escaping @Sendable (Double) -> Void) {
                self.destination = destination
                self.onProgress = onProgress
            }

            func urlSession(_ session: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping (URLRequest?) -> Void) {
                completionHandler(UpdateInstaller.allowsDownloadRedirect(request) ? request : nil)
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
                if !UpdateInstaller.acceptsDownloadResponse(downloadTask.response) {
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
        do {
            return try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    nonisolated private static func verify(
        stagedApp: String,
        matching destPath: String,
        expectedBundleIdentifier: String,
        expectedVersion: String
    ) async throws {
        guard let stagedBundle = Bundle(url: URL(fileURLWithPath: stagedApp)) else { throw UpdateError.unpack }
        let stagedIdentifier = stagedBundle.bundleIdentifier
        let stagedVersion = stagedBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard Self.matchesReleaseIdentity(bundleIdentifier: stagedIdentifier, version: stagedVersion,
                                          expectedBundleIdentifier: expectedBundleIdentifier,
                                          expectedVersion: expectedVersion) else {
            if stagedIdentifier != expectedBundleIdentifier { throw UpdateError.bundleIdentifierMismatch }
            throw UpdateError.versionMismatch(expected: expectedVersion, actual: stagedVersion)
        }
        // 1. The bundle must be internally consistent and validly signed.
        do {
            _ = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", stagedApp])
        } catch {
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

    nonisolated static func matchesReleaseIdentity(bundleIdentifier: String?, version: String?,
                                                   expectedBundleIdentifier: String,
                                                   expectedVersion: String) -> Bool {
        bundleIdentifier == expectedBundleIdentifier && version == expectedVersion
    }

    private static func swapAndRelaunch(newApp: String, destPath: String, stagingDirectory: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        // Paths arrive as positional arguments, never interpolated into the
        // script body. Both are strings this process does not fully control:
        // `destPath` is wherever the user put and named the bundle, and
        // `newApp` is a directory name read out of the downloaded archive. A
        // quote or `$(…)` in either used to land inside a shell script that
        // then ran — command execution out of a filename. Verification gates
        // the archive, so this was defence in depth rather than a live hole,
        // but it costs nothing to close and the bundle path is not gated by
        // anything at all.
        let logURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/NotchPill/update.log")
        let script = """
        #!/bin/bash
        set -u
        trap '/bin/rm -f "${BASH_SOURCE[0]}"' EXIT
        pid="$1"; dest="$2"; new="$3"; staging="$4"; log="$5"
        report() {
          mkdir -p "$(/usr/bin/dirname "$log")" 2>/dev/null || true
          /usr/bin/printf '%s %s\\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$log" 2>/dev/null || true
          /usr/bin/logger -t NotchPill "$1" 2>/dev/null || true
        }
        show_failure() {
          /usr/bin/osascript -e 'display dialog "NotchPill could not finish installing the update. The previous app was restored when possible. See ~/Library/Logs/NotchPill/update.log for details." buttons {"OK"} with icon caution' >/dev/null 2>&1 || true
        }
        # Wait for the running NotchPill to exit before replacing its bundle.
        for _ in $(seq 1 100); do /bin/kill -0 "$pid" 2>/dev/null || break; /bin/sleep 0.1; done
        BACKUP="$dest.old"
        if ! /bin/rm -rf "$BACKUP"; then
          report "Update failed before swap: could not remove prior backup."
          /usr/bin/open "$dest" >/dev/null 2>&1 || true
          show_failure
          /bin/rm -rf "$staging"
          exit 1
        fi
        if ! /bin/mv "$dest" "$BACKUP"; then
          report "Update failed before swap: could not move current app to backup; no rollback was needed."
          /usr/bin/open "$dest" >/dev/null 2>&1 || true
          show_failure
          /bin/rm -rf "$staging"
          exit 1
        fi
        if /usr/bin/ditto "$new" "$dest"; then
          /usr/bin/xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
          /bin/rm -rf "$BACKUP"
          report "Update installed successfully; rollback=false."
          /bin/rm -rf "$staging"
          if ! /usr/bin/open "$dest"; then
            report "Update installed, but macOS could not relaunch the app."
            show_failure
            exit 1
          fi
          exit 0
        fi
        /bin/rm -rf "$dest"
        if /bin/mv "$BACKUP" "$dest"; then
          report "Update installation failed; rollback=true and previous app restored."
          /usr/bin/open "$dest" >/dev/null 2>&1 || true
        else
          report "Update installation failed; rollback=true but restoring the previous app also failed. Backup remains at $BACKUP."
        fi
        show_failure
        /bin/rm -rf "$staging"
        /bin/rm -f "${BASH_SOURCE[0]}"
        exit 1
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchpill-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            throw UpdateError.scriptCreation(error.localizedDescription)
        }

        // Launch the swap detached so it outlives this process, then quit.
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptURL.path, String(pid), destPath, newApp, stagingDirectory.path, logURL.path]
        do {
            try task.run()
        } catch {
            try? FileManager.default.removeItem(at: scriptURL)
            throw UpdateError.scriptLaunch(error.localizedDescription)
        }
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    /// The certificate-hash portion of a bundle's designated requirement, e.g.
    /// `certificate root = H"b22cbb44…"`, or "adhoc" for an ad-hoc signature.
    nonisolated private static func signingIdentity(of appPath: String) async -> String? {
        guard let result = try? await run("/usr/bin/codesign", ["-d", "--requirements", "-", appPath]) else { return nil }
        let dr = String(data: result.stderr + result.stdout, encoding: .utf8) ?? ""
        if let range = dr.range(of: #"certificate root = H"[0-9a-fA-F]+""#, options: .regularExpression) {
            return String(dr[range])
        }
        // No ad-hoc branch, deliberately.
        //
        // It used to return the constant "adhoc", which made every ad-hoc
        // signature equal to every other one. An ad-hoc signature carries no
        // identity — anyone can produce one over any payload with a single
        // `codesign -s -` — so on an ad-hoc install the check that is supposed
        // to stop a hostile bundle replacing the app in place was comparing
        // "unsigned" against "unsigned" and passing. Returning nil fails the
        // guard in `verify`, so those installs now decline to self-update and
        // send the user to the release page instead.
        //
        // `opaque:` is dropped for the same reason plus a second: `hashValue`
        // is seeded per process, so the two sides were hashed in *this* run and
        // compared consistently, but the value means nothing beyond it.
        return nil
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
    nonisolated private static func run(_ launchPath: String, _ args: [String]) async throws -> ProcessResult {
        do {
            return try await ProcessRunner.run(executableURL: URL(fileURLWithPath: launchPath),
                                              arguments: args,
                                              timeout: launchPath.hasSuffix("ditto") ? 120 : 30)
        } catch let error as ProcessRunnerError {
            let detail: String
            switch error {
            case .launch(let cause): detail = "\(launchPath) could not start: \(cause.localizedDescription)"
            case .timedOut: detail = "\(launchPath) timed out."
            case .cancelled: detail = "\(launchPath) was cancelled."
            case .nonzeroExit(let status, _, let stderr):
                let output = String(data: stderr.prefix(600), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                detail = "\(launchPath) exited with status \(status)."
                    + (output.map { " " + $0 } ?? "")
            }
            throw UpdateError.commandFailed(detail)
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
