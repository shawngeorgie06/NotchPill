import Testing
import Foundation
@testable import NotchPill

@Suite("Dev command snapshots")
struct DevCommandTests {
    @Test("decodes a shell snapshot and redacts the display title")
    func decodeSnapshot() throws {
        let data = Data(#"{"id":"one","title":"Build ghp_abcdefghijklmnopqrstuvwxyz","command":"npm","state":"failed","startedAt":100,"updatedAt":105,"endedAt":105,"exitCode":23,"processId":1234}"#.utf8)
        let command = try JSONDecoder().decode(DevCommand.self, from: data)
        #expect(command.id == "one")
        #expect(command.state == .failed)
        #expect(command.exitCode == 23)
        #expect(command.startedAt == Date(timeIntervalSince1970: 100))
        #expect(!command.displayTitle.contains("ghp_"))
    }

    @Test("keeps concurrent commands and settles a vanished wrapper once")
    @MainActor
    func providerSnapshots() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let now = Date(timeIntervalSince1970: 1_000)
        let running = #"{"id":"one","title":"Tests","command":"npm","state":"running","startedAt":900,"updatedAt":900,"processId":99999999}"#
        let passed = #"{"id":"two","title":"Build","command":"swift","state":"passed","startedAt":920,"updatedAt":930,"endedAt":930,"exitCode":0}"#
        try Data(running.utf8).write(to: folder.appendingPathComponent("one.json"))
        try Data(passed.utf8).write(to: folder.appendingPathComponent("two.json"))
        let provider = DevCommandProvider(directory: folder)
        provider.refresh(now: now)
        #expect(provider.commands.count == 2)
        #expect(provider.commands.map(\.id).sorted() == ["one", "two"])
        #expect(provider.commands.first(where: { $0.id == "one" })?.state == .failed)
        let endedAt = provider.commands.first(where: { $0.id == "one" })?.endedAt
        provider.refresh(now: now.addingTimeInterval(5))
        #expect(provider.commands.first(where: { $0.id == "one" })?.endedAt == endedAt)
        #expect(provider.commands.first(where: { $0.id == "two" })?.state == .passed)
    }

    @Test("script activities wait without a wrapper process")
    @MainActor
    func scriptWaitingState() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let waiting = #"{"id":"review","title":"Deploy","command":"script","detail":"Approve release","state":"waiting","startedAt":100,"updatedAt":105}"#
        try Data(waiting.utf8).write(to: folder.appendingPathComponent("review.json"))
        let provider = DevCommandProvider(directory: folder)
        provider.refresh(now: Date(timeIntervalSince1970: 1_000))
        #expect(provider.commands.first?.state == .waiting)
        #expect(provider.commands.first?.displayDetail == "Approve release")
    }

    @Test("dismiss removes only the selected activity snapshot")
    @MainActor
    func dismissOneSnapshot() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = #"{"id":"one","title":"Tests","command":"swift","state":"passed","startedAt":1,"updatedAt":2}"#
        let second = #"{"id":"two","title":"Build","command":"swift","state":"passed","startedAt":1,"updatedAt":2}"#
        try Data(first.utf8).write(to: folder.appendingPathComponent("one.json"))
        try Data(second.utf8).write(to: folder.appendingPathComponent("two.json"))
        let provider = DevCommandProvider(directory: folder)
        provider.refresh(now: Date(timeIntervalSince1970: 10))

        provider.dismiss(id: "one")

        #expect(provider.commands.map(\.id) == ["two"])
        for _ in 0..<50 where FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("one.json").path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("one.json").path))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("two.json").path))

        // The running wrapper may write another state after a dismissal.
        // That ID stays hidden even if it recreates the snapshot.
        try Data(first.utf8).write(to: folder.appendingPathComponent("one.json"))
        provider.refresh(now: Date(timeIntervalSince1970: 11))
        #expect(provider.commands.map(\.id) == ["two"])
    }

    @Test("an orphaned command expires from the original detected end time")
    @MainActor
    func orphanExpires() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("orphan.json")
        let running = #"{"id":"orphan","title":"Tests","command":"swift","state":"running","startedAt":1,"updatedAt":2,"processId":99999999}"#
        try Data(running.utf8).write(to: file)
        let provider = DevCommandProvider(directory: folder)
        let detected = Date(timeIntervalSince1970: 100)
        provider.refresh(now: detected)
        #expect(provider.commands.first?.endedAt == detected)
        provider.refresh(now: detected.addingTimeInterval(30 * 60 + 1))
        #expect(provider.commands.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test("CLI setup installs bundled scripts as executables into the chosen folder")
    func installCLI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundleURL = root.appendingPathComponent("NotchPill.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources/Scripts")
        let destination = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let info = bundleURL.appendingPathComponent("Contents/Info.plist")
        try Data(#"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.notchpill</string></dict></plist>"#.utf8)
            .write(to: info)
        let script = Data("#!/bin/sh\nexit 0\n".utf8)
        try script.write(to: resources.appendingPathComponent("notchpill"))
        try script.write(to: resources.appendingPathComponent("notchpill-command.sh"))
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try #require(Bundle(url: bundleURL))

        try DevCommandCLISetup.install(to: destination, bundle: bundle)

        #expect(DevCommandCLISetup.isInstalled(in: destination))
        #expect(try Data(contentsOf: destination.appendingPathComponent("notchpill")) == script)
        #expect(DevCommandCLISetup.examples.contains("notchpill working"))
    }

    @Test("exact command focus declines missing or unsupported terminal targets")
    func exactFocusSafety() {
        #expect(!AgentSessionLocator.focus(terminalTTY: nil, bundleId: "com.apple.Terminal"))
        #expect(!AgentSessionLocator.focus(terminalTTY: "/dev/ttys012", bundleId: "dev.warp.Warp-Stable"))
        #expect(!AgentSessionLocator.focus(terminalTTY: "ttys012", bundleId: "com.apple.Terminal"))
    }

    @Test("a partial CLI install restores the original script and executable mode")
    func installCLIRollbackPreservesMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Tools.bundle")
        let resources = bundleURL.appendingPathComponent("Contents/Resources/Scripts")
        let destination = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data(#"<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.rollback</string></dict></plist>"#.utf8)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        for name in ["notchpill", "notchpill-command.sh"] {
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: resources.appendingPathComponent(name))
        }
        let oldTool = destination.appendingPathComponent("notchpill")
        let original = Data("#!/bin/sh\necho original\n".utf8)
        try original.write(to: oldTool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: oldTool.path)
        // A directory at the second target forces the second copy to fail.
        try FileManager.default.createDirectory(at: destination.appendingPathComponent("notchpill-command.sh"),
                                                withIntermediateDirectories: false)
        let bundle = try #require(Bundle(url: bundleURL))
        do {
            try DevCommandCLISetup.install(to: destination, bundle: bundle)
            Issue.record("Expected second-tool installation to fail")
        } catch {
            #expect(try Data(contentsOf: oldTool) == original)
            let attributes = try FileManager.default.attributesOfItem(atPath: oldTool.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        }
    }
}
