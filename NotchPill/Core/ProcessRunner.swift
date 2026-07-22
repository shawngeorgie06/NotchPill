import Foundation

/// Runs a short-lived tool and captures its stdout without deadlocking.
///
/// The classic trap is calling `Process.waitUntilExit()` *before* draining the
/// output pipe: if the child writes more than the OS pipe buffer (~64 KB) the
/// child blocks on `write`, the parent blocks on `waitUntilExit`, and neither
/// ever proceeds. Reading to EOF first drains the pipe as the child writes, so
/// large payloads (e.g. ~130 KB album artwork) come back intact.
enum ProcessRunner {
    static func capture(_ launchPath: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        // Drain BEFORE waiting: readDataToEndOfFile returns when the child closes
        // stdout (i.e. exits), consuming output as it is produced.
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
