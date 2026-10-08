import Foundation
import Darwin

struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let terminationStatus: Int32
    let stdoutWasTruncated: Bool
    let stderrWasTruncated: Bool
}

enum ProcessRunnerError: Error {
    case launch(Error)
    case timedOut
    case cancelled
    case nonzeroExit(status: Int32, stdout: Data, stderr: Data)
}

/// Executes short lived command line tools while draining both pipes, enforcing
/// a deadline, and retaining only a bounded amount of output per stream.
enum ProcessRunner {
    static let defaultOutputLimitBytes = 1_048_576

    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        timeout: TimeInterval = 30,
        outputLimitBytes: Int = defaultOutputLimitBytes
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let runner = AsyncProcess(executableURL: executableURL,
                                  arguments: arguments,
                                  currentDirectoryURL: currentDirectoryURL,
                                  timeout: timeout,
                                  outputLimitBytes: max(0, outputLimitBytes))
        return try await withTaskCancellationHandler {
            try await runner.startAndWait()
        } onCancel: {
            runner.cancel()
        }
    }

    /// Compatibility entry point for existing synchronous, non-UI callers.
    /// It retains the old nil-on-failure contract and applies the same output
    /// cap while reading stdout and stderr concurrently.
    static func capture(_ launchPath: String, _ arguments: [String]) -> Data? {
        capture(launchPath, arguments, timeout: 30)
    }

    static func captureForFocus(_ launchPath: String, _ arguments: [String]) -> Data? {
        capture(launchPath, arguments, timeout: 2)
    }

    static func capture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let output = LockedCapture(limit: defaultOutputLimitBytes)
        let readers = DispatchGroup()
        readers.enter()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                readers.leave()
            } else { output.append(data, stdout: true) }
        }
        readers.enter()
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                readers.leave()
            } else { output.append(data, stdout: false) }
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            return nil
        }
        let signalTarget = ProcessSignalTarget(process: process)
        var normalExit = exited.wait(timeout: .now() + max(0.01, timeout)) == .success
        if !normalExit {
            signalTarget.signal(SIGTERM, process: process)
            _ = exited.wait(timeout: .now() + 0.5)
            // The leader may exit on TERM while a descendant ignores it.
            signalTarget.signal(SIGKILL, process: process)
            if process.isRunning { _ = exited.wait(timeout: .now() + 0.5) }
        }
        // Descendants can inherit pipe handles after the launched process exits.
        // Give pending bytes a short drain window, then close our read ends so a
        // compatibility call cannot wait forever for unrelated grandchildren.
        let drained = readers.wait(timeout: .now() + 0.25) == .success
        if !drained {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            _ = readers.wait(timeout: .now() + 0.1)
        }
        normalExit = normalExit && process.terminationStatus == 0
        return normalExit ? output.stdout : nil
    }
}

/// Foundation normally creates a group led by the launched child on macOS.
/// Capture ownership at launch; never send a signal to an inherited group.
private struct ProcessSignalTarget: Sendable {
    let pid: pid_t
    let ownedGroup: pid_t?

    init(process: Process) {
        pid = process.processIdentifier
        ownedGroup = pid > 0 && getpgid(pid) == pid ? pid : nil
    }

    func signal(_ signal: Int32, process: Process) {
        if let ownedGroup {
            kill(-ownedGroup, signal)
        } else if pid > 0 && process.isRunning {
            kill(pid, signal)
        }
    }
}

private final class LockedCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var output = Data()
    var stdout: Data { lock.lock(); defer { lock.unlock() }; return output }
    init(limit: Int) { self.limit = limit }
    func append(_ data: Data, stdout isStdout: Bool) {
        guard isStdout else { return } // stderr is drained, but not captured by compatibility API.
        lock.lock(); defer { lock.unlock() }
        let remaining = max(0, limit - output.count)
        if remaining > 0 { output.append(data.prefix(remaining)) }
    }
}

private final class AsyncProcess: @unchecked Sendable {
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let timeout: TimeInterval
    private let outputLimit: Int
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ProcessResult, Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutTruncated = false
    private var stderrTruncated = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var exited = false
    private var completed = false
    private var failure: ProcessRunnerError?
    private var timeoutWork: DispatchWorkItem?
    private var signalTarget: ProcessSignalTarget?

    init(executableURL: URL, arguments: [String], currentDirectoryURL: URL?, timeout: TimeInterval, outputLimitBytes: Int) {
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.timeout = max(0.01, timeout)
        outputLimit = outputLimitBytes
    }

    func startAndWait() async throws -> ProcessResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if completed {
                let error = failure ?? .cancelled
                lock.unlock()
                continuation.resume(throwing: error)
                return
            }
            self.continuation = continuation
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.received(data, stdout: true)
            }
            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                self?.received(data, stdout: false)
            }
            process.terminationHandler = { [weak self] _ in
                guard let self else { return }
                self.lock.lock(); self.exited = true; self.lock.unlock()
                self.finishIfReady()
            }
            do {
                // Serialize launch with cancellation: a cancellation between
                // continuation setup and run() must not leave a new child behind.
                try process.run()
                signalTarget = ProcessSignalTarget(process: process)
                let item = DispatchWorkItem { [weak self] in self?.fail(.timedOut) }
                timeoutWork = item
                lock.unlock()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: item)
            } catch {
                lock.unlock()
                finish(.failure(ProcessRunnerError.launch(error)))
            }
        }
    }

    func cancel() { fail(.cancelled) }

    private func received(_ data: Data, stdout isStdout: Bool) {
        lock.lock()
        if data.isEmpty {
            if isStdout { stdoutClosed = true } else { stderrClosed = true }
        } else if isStdout {
            append(data, to: &stdout, truncated: &stdoutTruncated)
        } else {
            append(data, to: &stderr, truncated: &stderrTruncated)
        }
        lock.unlock()
        if data.isEmpty {
            if isStdout { stdoutPipe.fileHandleForReading.readabilityHandler = nil }
            else { stderrPipe.fileHandleForReading.readabilityHandler = nil }
        }
        finishIfReady()
    }

    private func append(_ data: Data, to target: inout Data, truncated: inout Bool) {
        let remaining = max(0, outputLimit - target.count)
        if remaining > 0 { target.append(data.prefix(remaining)) }
        if data.count > remaining { truncated = true }
    }

    private func finishIfReady() {
        lock.lock()
        guard exited && stdoutClosed && stderrClosed && !completed else {
            lock.unlock()
            return
        }
        // Choose the result while holding the same lock used by fail(). A
        // timeout can otherwise arrive after reading failure but before the
        // result is committed, and turn its signal exit into nonzeroExit.
        let result: Result<ProcessResult, Error>
        if let failure {
            result = .failure(failure)
        } else {
            let status = process.terminationStatus
            let output = ProcessResult(stdout: stdout, stderr: stderr, terminationStatus: status,
                                       stdoutWasTruncated: stdoutTruncated,
                                       stderrWasTruncated: stderrTruncated)
            if status == 0 { result = .success(output) }
            else { result = .failure(ProcessRunnerError.nonzeroExit(status: status, stdout: output.stdout, stderr: output.stderr)) }
        }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        complete(result, continuation: continuation)
    }

    private func fail(_ error: ProcessRunnerError) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        guard failure == nil else { lock.unlock(); return }
        failure = error
        let target = signalTarget
        lock.unlock()
        if let target {
            target.signal(SIGTERM, process: process)
            // Keep the Process alive after the awaiting task receives its error;
            // otherwise a stubborn child could outlive the runner and escalation.
            let child = process
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                target.signal(SIGKILL, process: child)
            }
        }
        finish(.failure(error))
    }

    private func finish(_ result: Result<ProcessResult, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        let continuation = self.continuation
        self.continuation = nil
        timeoutWork?.cancel()
        timeoutWork = nil
        lock.unlock()
        complete(result, continuation: continuation)
    }

    private func complete(_ result: Result<ProcessResult, Error>, continuation: CheckedContinuation<ProcessResult, Error>?) {
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()
        continuation?.resume(with: result)
    }
}
