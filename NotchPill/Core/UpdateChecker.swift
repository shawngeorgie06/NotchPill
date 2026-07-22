import Foundation
import AppKit

/// A release newer than the running build, discovered on GitHub.
struct UpdateRelease: Equatable, Sendable {
    let version: String   // "1.2.0"
    let tag: String       // "v1.2.0"
    let zipURL: URL       // the macOS-arm64.zip asset
    let notes: String     // release body (markdown)
    let htmlURL: URL      // release page (fallback)
}

/// Polls the GitHub Releases API for a newer NotchPill and publishes it so the
/// menu bar can offer an in-app update. Read-only network access; the actual
/// install is handled by `UpdateInstaller`.
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    @Published private(set) var available: UpdateRelease?
    @Published private(set) var isChecking = false
    @Published private(set) var lastError: String?

    /// Fired once when a newer release is first discovered (for a launch peek, etc.).
    var onUpdateFound: ((UpdateRelease) -> Void)?

    private let repo = "shawngeorgie06/NotchPill"
    private let recheckInterval: TimeInterval = 6 * 3600
    private var timer: Timer?
    private var announcedVersion: String?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        check()
        let timer = Timer(timeInterval: recheckInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// `force` bypasses the auto-check preference (used by "Check for Updates…").
    func check(force: Bool = false) {
        guard force || AppSettings.shared.autoCheckUpdates else { return }
        guard !isChecking else { return }
        isChecking = true
        lastError = nil
        Task {
            defer { isChecking = false }
            do {
                if let release = try await fetchLatest(),
                   Self.isNewer(release.version, than: currentVersion) {
                    available = release
                    NSLog("NotchPill: update available \(release.version) (current \(currentVersion))")
                    if announcedVersion != release.version {
                        announcedVersion = release.version
                        onUpdateFound?(release)
                    }
                } else {
                    available = nil
                    NSLog("NotchPill: up to date (current \(currentVersion))")
                }
            } catch {
                lastError = error.localizedDescription
                NSLog("NotchPill: update check failed — \(error.localizedDescription)")
            }
        }
    }

    private func fetchLatest() async throws -> UpdateRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchPill/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String else { return nil }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let notes = (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let htmlURL = URL(string: json["html_url"] as? String ?? "")
            ?? URL(string: "https://github.com/\(repo)/releases/latest")!

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard let zipString = assets
                .compactMap({ $0["browser_download_url"] as? String })
                .first(where: { $0.hasSuffix("macOS-arm64.zip") }),
              let zipURL = URL(string: zipString) else { return nil }

        return UpdateRelease(version: version, tag: tag, zipURL: zipURL, notes: notes, htmlURL: htmlURL)
    }

    /// Semantic-ish comparison of dotted numeric versions ("1.10.0" > "1.9.9").
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." }).map { Int($0.filter(\.isNumber)) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
