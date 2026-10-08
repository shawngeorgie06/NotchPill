import Foundation
import Testing
@testable import NotchPill

@Suite("Updater identity safety")
struct UpdaterSafetyTests {
    @Test func stableUpdaterOnlyRunsForStableBundle() {
        #expect(UpdateChecker.allowsStableSelfUpdate(bundleIdentifier: "com.local.notchpill"))
        #expect(!UpdateChecker.allowsStableSelfUpdate(bundleIdentifier: "com.local.notchpill.dev"))
        #expect(!UpdateChecker.allowsStableSelfUpdate(bundleIdentifier: nil))
    }

    @Test func stagedBundleMustMatchIdentifierAndReleaseVersion() {
        #expect(UpdateInstaller.matchesReleaseIdentity(
            bundleIdentifier: "com.local.notchpill",
            version: "1.2.3",
            expectedBundleIdentifier: "com.local.notchpill",
            expectedVersion: "1.2.3"
        ))
        #expect(!UpdateInstaller.matchesReleaseIdentity(
            bundleIdentifier: "com.local.notchpill.dev",
            version: "1.2.3",
            expectedBundleIdentifier: "com.local.notchpill",
            expectedVersion: "1.2.3"
        ))
        #expect(!UpdateInstaller.matchesReleaseIdentity(
            bundleIdentifier: "com.local.notchpill",
            version: "1.2.2",
            expectedBundleIdentifier: "com.local.notchpill",
            expectedVersion: "1.2.3"
        ))
        #expect(!UpdateInstaller.matchesReleaseIdentity(
            bundleIdentifier: nil,
            version: nil,
            expectedBundleIdentifier: "com.local.notchpill",
            expectedVersion: "1.2.3"
        ))
    }
    @Test func downloadOriginsAndRedirectsRespectHostBoundaries() {
        let allowed = ["github.com", "objects.githubusercontent.com",
                       "release-assets.githubusercontent.com", "cdn.objects.githubusercontent.com"]
        for host in allowed {
            let url = URL(string: "https://\(host)/asset.zip")!
            #expect(UpdateChecker.isTrustedDownload(url))
            #expect(UpdateInstaller.allowsDownloadRedirect(URLRequest(url: url)))
        }
        let rejected = ["http://github.com/asset.zip", "file:///tmp/asset.zip",
                        "https://github.com.evil.test/asset.zip",
                        "https://evilgithub.com/asset.zip",
                        "https://objects.githubusercontent.com.evil.test/asset.zip",
                        "https://release-assets.githubusercontent.com.evil.test/asset.zip",
                        "https://evilrelease-assets.githubusercontent.com/asset.zip",
                        "https://github.com@evil.test/asset.zip"]
        for value in rejected {
            let url = URL(string: value)!
            #expect(!UpdateChecker.isTrustedDownload(url))
            #expect(!UpdateInstaller.allowsDownloadRedirect(URLRequest(url: url)))
        }
        #expect(!UpdateInstaller.allowsDownloadRedirect(URLRequest(url: URL(string: "about:blank")!)))
    }

    @Test func stagingRequiresTrustedHTTP200() {
        let trusted = URL(string: "https://release-assets.githubusercontent.com/asset.zip")!
        for status in [200, 206, 301, 302, 403, 404, 500] {
            let response = HTTPURLResponse(url: trusted, statusCode: status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            #expect(UpdateInstaller.acceptsDownloadResponse(response) == (status == 200))
        }
        for value in ["https://evil.test/asset.zip", "http://github.com/asset.zip"] {
            let response = HTTPURLResponse(url: URL(string: value)!, statusCode: 200,
                                           httpVersion: nil, headerFields: nil)!
            #expect(!UpdateInstaller.acceptsDownloadResponse(response))
        }
        #expect(!UpdateInstaller.acceptsDownloadResponse(nil))
        #expect(!UpdateInstaller.acceptsDownloadResponse(URLResponse(
            url: trusted, mimeType: "application/zip", expectedContentLength: 10,
            textEncodingName: nil)))
    }

}
