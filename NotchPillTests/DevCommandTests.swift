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
}
