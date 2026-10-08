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
                arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; while :; do sleep 0.1; done", "probe", pidFile.path],
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
        while probe.anyRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        #expect(!probe.isRunning(leader))
        #expect(!probe.isRunning(descendant))
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
            #expect(probe.isRunning(descendant), "the descendant must still hold the pipes open")
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
        let task = cancellationMeasuredTask {
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
        let cancelledAt = ContinuousClock.now
        let leaderExit = cancellationMeasuredTask {
            await probe.observeGone(leader, deadline: cancelledAt.advanced(by: .milliseconds(400)))
        }
        let descendantExit = cancellationMeasuredTask {
            await probe.observeGone(descendant, deadline: cancelledAt.advanced(by: .seconds(2)))
        }
        task.cancel()
        do {
            let completion = await task.value
            #expect(cancelledAt.duration(to: completion.finishedAt) < .seconds(1))
            _ = try completion.result.get()
            Issue.record("Expected cancellation")
        } catch ProcessRunnerError.cancelled {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        // The default-TERM leader exits before the 0.5-second KILL escalation.
        #expect(try await leaderExit.value.result.get())
        #expect(try await descendantExit.value.result.get())
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
        #expect(probe.isRunning(descendant))
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

    var anyRunning: Bool {
        [pid("leader"), pid("descendant")].compactMap { $0 }.contains(where: isRunning)
    }

    func isRunning(_ pid: pid_t) -> Bool {
        Self.canRun(pid)
    }

    static func canRun(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            // The native query can fail even for a real zombie. Only ESRCH
            // from kill proves absence; permission failures remain unknown.
            guard kill(pid, 0) == 0 else { return errno != ESRCH }
            guard let output = ProcessRunner.capture(
                "/bin/ps", ["-o", "stat=", "-p", String(pid)], timeout: 1),
                  let state = String(data: output, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !state.isEmpty else {
                return true
            }
            // Only a positive zombie status proves it cannot execute. Empty,
            // failed, or unrecognized status queries must not pass the test.
            return !state.hasPrefix("Z")
        }
        // kill(pid, 0) succeeds for zombies too. They are already dead and
        // cannot retain a pipe or execute work, even if launchd has not reaped
        // them yet.
        return info.pbi_status != UInt32(SZOMB)
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
        while isRunning(pid) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!isRunning(pid))
    }

    func observeGone(_ pid: pid_t, deadline: ContinuousClock.Instant) async -> Bool {
        while isRunning(pid) {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return ContinuousClock.now < deadline
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
        while anyRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
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

    @Test("parent death stops and reaps only the owned stream child", arguments: [false, true])
    func parentDeathStopsOwnedChild(unreapedParent: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("child.sh")
        let pidFile = directory.appendingPathComponent("child.pid")
        try "trap 'exit 0' TERM; echo $$ > \"$1\"; while :; do sleep 0.1; done\n"
            .write(to: script, atomically: true, encoding: .utf8)

        let unrelated = Process()
        unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
        unrelated.arguments = ["60"]
        unrelated.standardOutput = FileHandle.nullDevice
        unrelated.standardError = FileHandle.nullDevice
        try unrelated.run()
        defer { if unrelated.isRunning { unrelated.terminate() } }

        let parentPIDFile = directory.appendingPathComponent("parent.pid")
        let parent = Process()
        parent.standardOutput = FileHandle.nullDevice
        parent.standardError = FileHandle.nullDevice
        if unreapedParent {
            // The Perl owner intentionally does not waitpid until teardown.
            // Its child dies as soon as the stream is ready and remains a real
            // kernel zombie, rather than relying on launchd's reaping latency.
            parent.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            parent.arguments = ["-e", #"""
            my ($ready, $pidfile) = @ARGV;
            my $pid = fork(); defined($pid) or die "fork: $!";
            if (!$pid) {
                while (!-s $ready) { select undef, undef, undef, 0.01; }
                exit 0;
            }
            open my $out, '>', $pidfile or die "open: $!";
            print $out "$pid\n"; close $out;
            $SIG{TERM} = sub { kill 'KILL', $pid; waitpid($pid, 0); exit 0; };
            while (1) { select undef, undef, undef, 0.1; }
            """#, pidFile.path, parentPIDFile.path]
        } else {
            parent.executableURL = URL(fileURLWithPath: "/bin/sh")
            // Deliver parent death independently of the cooperative executor.
            // Previously the runner's five-second deadline started before the
            // test task could resume to terminate the parent; CI contention
            // could consume that deadline before parent death was delivered.
            parent.arguments = ["-c", "while [ ! -s \"$1\" ]; do sleep 0.01; done",
                                "test-parent", pidFile.path]
        }
        try parent.run()
        defer { if parent.isRunning { parent.terminate() } }
        var monitoredPID = parent.processIdentifier
        if unreapedParent {
            let deadline = Date().addingTimeInterval(2)
            var recordedPID: pid_t?
            while recordedPID == nil {
                if let raw = try? String(contentsOf: parentPIDFile, encoding: .utf8) {
                    recordedPID = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                // Always inspect readiness after resuming, even if a delayed
                // executor wakeup crossed the setup deadline.
                if recordedPID != nil || Date() >= deadline { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            monitoredPID = try #require(recordedPID)
        }

        do {
            _ = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", MediaRemoteBridge.supervisorScript, "test-supervisor",
                            String(monitoredPID), "/bin/sh", script.path, pidFile.path],
                timeout: 5
            )
        } catch ProcessRunnerError.nonzeroExit {
            // A TERM-terminated child may report a nonzero status; ownership is
            // established by the child disappearing and the supervisor exiting.
        }
        let raw = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)))
        defer { if kill(pid, 0) == 0 { kill(pid, SIGKILL) } }
        #expect(kill(pid, 0) != 0)
        #expect(unrelated.isRunning, "parent death must not signal an unrelated process")
        #expect(DescendantProbe.canRun(unrelated.processIdentifier),
                "the observer must classify a live unrelated process as running")
        if unreapedParent {
            // proc_pidinfo can return ESRCH for zombies even while kill -0
            // succeeds. ps exposes their state on both macOS 15 and 27.
            #expect(kill(monitoredPID, 0) == 0)
            let status = try await ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-o", "stat=", "-p", String(monitoredPID)], timeout: 3)
            #expect(String(decoding: status.stdout, as: UTF8.self).contains("Z"),
                    "the supervisor must finish before the parent is reaped")
            #expect(!DescendantProbe.canRun(monitoredPID),
                    "the observer must classify the unreaped parent as dead")
        }
    }
}

// Cancellation deadlines describe the operation completing, not when the test
// caller next gets a cooperative worker. A private executor runs preferred
// operation jobs and records completion before the caller resumes. Actors keep
// their own executors; this does not bypass service isolation or hide time
// spent awaiting service work.
@available(macOS 15.0, *)
private final class CancellationTestExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "notchpill.tests.cancellation", qos: .userInitiated)
    func enqueue(_ job: UnownedJob) {
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

struct CancellationTestCompletion<Value: Sendable>: @unchecked Sendable {
    let result: Result<Value, Error>
    let finishedAt: ContinuousClock.Instant
}

func cancellationMeasuredTask<Value: Sendable>(
    _ operation: @escaping @Sendable () async throws -> Value
) -> Task<CancellationTestCompletion<Value>, Never> {
    let measured: @Sendable () async -> CancellationTestCompletion<Value> = {
        let result: Result<Value, Error>
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        return CancellationTestCompletion(result: result, finishedAt: ContinuousClock.now)
    }
    if #available(macOS 15.0, *) {
        return Task(executorPreference: CancellationTestExecutor(), operation: measured)
    }
    // Keep the same required result/deadline checks on the minimum supported OS.
    return Task(operation: measured)
}
