import Foundation
import Darwin
import Testing
@testable import NotchPill

@Suite("Process execution reliability")
struct ProcessRunnerReliabilityTests {
    @Test("synchronous focus helper has a bounded wait")
    func focusCaptureTimeout() {
        let started = Date()
        let output = ProcessRunner.capture("/bin/sh", ["-c", "sleep 10"], timeout: 0.1)
        #expect(output == nil)
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test("drains stdout and stderr while bounding captured output")
    func drainsBothStreamsAndBoundsCapture() async throws {
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "head -c 1048576 /dev/zero >&2; printf 'finished'"],
            timeout: 5,
            outputLimitBytes: 32
        )
        #expect(result.stdout == Data("finished".utf8))
        #expect(result.stderr.count == 32)
        #expect(result.stderrWasTruncated)
        #expect(!result.stdoutWasTruncated)
    }

    @Test("reports a non-zero exit with captured diagnostics")
    func nonzeroExit() async {
        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf 'problem' >&2; exit 7"],
                timeout: 3
            )
            Issue.record("Expected a non-zero exit error")
        } catch ProcessRunnerError.nonzeroExit(let status, _, let stderr) {
            #expect(status == 7)
            #expect(String(data: stderr, encoding: .utf8) == "problem")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("timeout retains its cause when termination callbacks race")
    func timeout() async {
        for attempt in 0..<12 {
            do {
                _ = try await ProcessRunner.run(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: ["-c", "exec sleep 10"],
                    timeout: 0.02
                )
                Issue.record("Expected timeout on attempt \(attempt)")
            } catch ProcessRunnerError.timedOut {
                // The SIGTERM exit is a consequence of the deadline.
            } catch {
                Issue.record("Unexpected error on attempt \(attempt): \(error)")
            }
        }
    }

    @Test("cancels a running command")
    func cancellation() async {
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "sleep 10"],
                timeout: 5
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch ProcessRunnerError.cancelled {
            #expect(Bool(true))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("cancellation reaps a child that ignores graceful termination")
    func cancellationEscalatesAfterRunnerReturns() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let task = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do :; done", "probe", pidFile.path],
                timeout: 5
            )
        }
        var pid: Int32?
        for _ in 0..<50 {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                pid = value
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        _ = try? await task.value
        let child = try #require(pid)
        defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
        for _ in 0..<30 {
            if kill(child, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(kill(child, 0) != 0)
    }
}


@Suite("Process descendant ownership")
struct ProcessRunnerDescendantTests {
    @Test("synchronous timeout kills a descendant that ignores TERM")
    func synchronousTimeout() throws {
        let probe = try DescendantProbe()
        defer { probe.cleanup() }
        let started = Date()
        let output = ProcessRunner.capture("/bin/sh", probe.arguments(), timeout: 0.6)
        #expect(output == nil)
        #expect(Date().timeIntervalSince(started) < 2)
        let leader = try #require(probe.pid("leader"))
        let descendant = try #require(probe.pid("descendant"))
        let deadline = Date().addingTimeInterval(2)
        while probe.anyAlive && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(kill(leader, 0) != 0)
        #expect(kill(descendant, 0) != 0)
    }

    @Test("async timeout kills descendants even after the leader exits", arguments: [false, true])
    func asynchronousTimeout(leaderExitsEarly: Bool) async throws {
        let probe = try DescendantProbe()
        defer { probe.cleanup() }
        let arguments = probe.arguments(leaderExitsEarly: leaderExitsEarly)
        let task = Task {
            try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: arguments, timeout: 0.8)
        }
        defer { task.cancel() }
        try await probe.waitUntilReady()
        let leader = try #require(probe.pid("leader"))
        let descendant = try #require(probe.pid("descendant"))
        #expect(getpgid(descendant) == leader)
        #expect(leader != getpgrp())
        if leaderExitsEarly {
            try await probe.waitUntilGone(leader, seconds: 0.4)
            #expect(kill(descendant, 0) == 0, "the descendant must still hold the pipes open")
        }
        do {
            _ = try await task.value
            Issue.record("Expected timeout")
        } catch ProcessRunnerError.timedOut {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        try await probe.waitUntilGone(leader, seconds: 2)
        try await probe.waitUntilGone(descendant, seconds: 2)
    }

    @Test("cancellation escalates against descendants after the leader exits")
    func cancellationAfterLeaderExit() async throws {
        let probe = try DescendantProbe()
        defer { probe.cleanup() }
        let arguments = probe.arguments()
        let task = Task {
            try await ProcessRunner.run(executableURL: URL(fileURLWithPath: "/bin/sh"),
                                        arguments: arguments, timeout: 5)
        }
        defer { task.cancel() }
        try await probe.waitUntilReady()
        let leader = try #require(probe.pid("leader"))
        let descendant = try #require(probe.pid("descendant"))
        #expect(getpgid(leader) == leader)
        #expect(getpgid(descendant) == leader)
        #expect(leader != getpgrp())
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch ProcessRunnerError.cancelled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(Date().timeIntervalSince(cancelledAt) < 1)
        // The default-TERM leader exits before the 0.5-second KILL escalation.
        try await probe.waitUntilGone(leader, seconds: 0.4)
        try await probe.waitUntilGone(descendant, seconds: 2)
    }

    @Test("normal success leaves descendants with closed pipes alone")
    func normalSuccess() async throws {
        let probe = try DescendantProbe()
        defer { probe.cleanup() }
        let result = try await ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: probe.arguments(leaderExitsEarly: true, closeDescendantPipes: true),
            timeout: 0.2)
        #expect(result.terminationStatus == 0)
        let descendant = try #require(probe.pid("descendant"))
        // Wait beyond both the deadline and escalation window: a completed
        // success must cancel the timer rather than kill the background child.
        try await Task.sleep(for: .milliseconds(800))
        #expect(kill(descendant, 0) == 0)
    }
}

private struct DescendantProbe: Sendable {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchpill-descendants-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func arguments(leaderExitsEarly: Bool = false, closeDescendantPipes: Bool = false) -> [String] {
        let redirect = closeDescendantPipes ? ">/dev/null 2>&1" : ""
        let script = """
        echo $$ > "$1/leader.pid"
        /bin/sh -c 'trap "" TERM; echo $$ > "$1/descendant.pid"; while :; do sleep 0.1; done' descendant "$1" \(redirect) &
        while [ ! -s "$1/descendant.pid" ]; do sleep 0.01; done
        echo ready > "$1/ready"
        if [ "$2" = exit ]; then exit 0; fi
        wait
        """
        return ["-c", script, "probe", directory.path, leaderExitsEarly ? "exit" : "wait"]
    }

    func pid(_ name: String) -> pid_t? {
        guard let raw = try? String(contentsOf: directory.appendingPathComponent(name + ".pid"),
                                   encoding: .utf8) else { return nil }
        return pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var anyAlive: Bool {
        [pid("leader"), pid("descendant")].compactMap { $0 }.contains { kill($0, 0) == 0 }
    }

    func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
                && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path))
    }

    func waitUntilGone(_ pid: pid_t, seconds: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while kill(pid, 0) == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(kill(pid, 0) != 0)
    }

    func cleanup() {
        // Re-read probe files even on assertion/launch failure, and signal only
        // the confirmed owned group (including its transient sleep children).
        let leader = pid("leader")
        let descendant = pid("descendant")
        if let leader, leader > 0,
           getpgid(leader) == leader || descendant.map({ getpgid($0) == leader }) == true {
            kill(-leader, SIGKILL)
        }
        for pid in [leader, descendant].compactMap({ $0 }) where kill(pid, 0) == 0 {
            kill(pid, SIGKILL)
        }
        let deadline = Date().addingTimeInterval(2)
        while anyAlive && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Media stream child ownership")
struct MediaSupervisorTests {
    @Test("supervisor exits when its stream child exits")
    func childExitStopsSupervisor() async throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sh")
        try "exit 7\n".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", MediaRemoteBridge.supervisorScript, "test-supervisor",
                            String(getpid()), "/bin/sh", script.path, "unused"],
                timeout: 4
            )
            Issue.record("Expected the child status to reach the supervisor")
        } catch ProcessRunnerError.nonzeroExit(let status, _, _) {
            #expect(status == 7)
        }
    }

    @Test("parent death stops and reaps only the owned stream child")
    func parentDeathStopsOwnedChild() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("child.sh")
        let pidFile = directory.appendingPathComponent("child.pid")
        try "echo $$ > \"$1\"; trap 'exit 0' TERM; while :; do sleep 0.1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)

        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = ["-c", "sleep 60"]
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }

        let supervisor = Task {
            try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", MediaRemoteBridge.supervisorScript, "test-supervisor",
                            String(parent.processIdentifier), "/bin/sh", script.path, pidFile.path],
                timeout: 5
            )
        }
        defer { supervisor.cancel() }

        var childPID: Int32?
        for _ in 0..<50 {
            if let raw = try? String(contentsOf: pidFile, encoding: .utf8),
               let value = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = value
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try #require(childPID)
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        parent.terminate()
        parent.waitUntilExit()
        do {
            _ = try await supervisor.value
        } catch ProcessRunnerError.nonzeroExit {
            // A TERM-terminated child may report a nonzero status; ownership is
            // established by the child disappearing and the supervisor exiting.
        }
        #expect(kill(pid, 0) != 0)
    }
}
