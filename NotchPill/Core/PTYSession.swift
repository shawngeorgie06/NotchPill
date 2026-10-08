import Darwin
import Foundation

/// A real login shell on a pseudo-terminal.
///
/// `Process` with pipes would have been less code, but it is not a terminal:
/// the shell sees a pipe, decides it is not interactive, and drops the prompt,
/// the colours, and job control. `forkpty` gives the child an actual controlling
/// terminal, which is the whole reason anything here behaves like a terminal at
/// all.
///
/// Everything the child writes is card-only and truncated by
/// `TerminalEmulator.scrollbackLimit`; nothing is written to disk.
final class PTYSession {

    /// Bytes from the shell, delivered on the main queue in read-sized chunks.
    var onOutput: (([UInt8]) -> Void)?
    /// Fired once when the shell exits, with its status.
    var onExit: ((Int32) -> Void)?

    private(set) var isRunning = false
    private var primary: Int32 = -1
    private var childPID: pid_t = -1
    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?

    /// The shell to run, honouring `$SHELL` and falling back to zsh, which is
    /// the macOS default. `-l` so the profile is read and `$PATH` is the one
    /// the person actually has in a terminal.
    static func loginShell() -> String {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? ""
        return shell.isEmpty ? "/bin/zsh" : shell
    }

    /// The environment handed to the shell.
    ///
    /// `TERM` has to claim colour or the shell will not emit any, and
    /// `xterm-256color` is the honest description of what the emulator
    /// implements. `LANG` is set when it is missing because a shell launched
    /// from an app bundle inherits no locale, and without one anything
    /// non-ASCII arrives as `?`.
    static func environment(from base: [String: String]) -> [String: String] {
        var env = base
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // The pill is not a pager and cannot answer one's keypresses.
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        return env
    }

    @discardableResult
    func start(columns: Int, rows: Int,
               directory: String? = nil,
               shell: String = PTYSession.loginShell()) -> Bool {
        guard !isRunning else { return true }

        // Prepare every allocation and borrowed buffer before forking. The
        // child can inherit runtime/allocator locks held by vanished threads.
        var ownedStrings: [UnsafeMutablePointer<CChar>] = []
        defer { ownedStrings.forEach { free($0) } }
        func duplicate(_ string: String) -> UnsafeMutablePointer<CChar>? {
            guard let pointer = strdup(string) else { return nil }
            ownedStrings.append(pointer)
            return pointer
        }
        guard let shellPointer = duplicate(shell),
              let namePointer = duplicate("-" + (shell as NSString).lastPathComponent)
        else { return false }
        var directoryPointer: UnsafeMutablePointer<CChar>?
        if let directory, !directory.isEmpty {
            guard let pointer = duplicate(directory) else { return false }
            directoryPointer = pointer
        }

        let argv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: 2)
        argv.initialize(repeating: nil, count: 2)
        argv[0] = namePointer
        defer { argv.deinitialize(count: 2); argv.deallocate() }

        let environment = Self.environment(from: ProcessInfo.processInfo.environment)
        let environmentCount = environment.count + 1
        let envp = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: environmentCount)
        envp.initialize(repeating: nil, count: environmentCount)
        defer { envp.deinitialize(count: environmentCount); envp.deallocate() }
        for (index, entry) in environment.enumerated() {
            guard let pointer = duplicate("\(entry.key)=\(entry.value)") else { return false }
            envp[index] = pointer
        }

        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                           ws_xpixel: 0, ws_ypixel: 0)
        var primaryFD: Int32 = -1
        let pid = forkpty(&primaryFD, nil, nil, &size)

        if pid < 0 { return false }

        if pid == 0 {
            // Only prepared C pointers and async-signal-safe calls here.
            // _exit also bypasses all Swift cleanup if exec fails.
            if let directoryPointer { _ = chdir(directoryPointer) }
            execve(shellPointer, argv, envp)
            _exit(127)
        }

        primary = primaryFD
        childPID = pid
        isRunning = true

        // Non-blocking, so a read that arrives with nothing behind it does not
        // wedge the dispatch source.
        let flags = fcntl(primary, F_GETFL, 0)
        _ = fcntl(primary, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: primary,
                                                   queue: .global(qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler { [weak self] in
            guard let self, self.primary >= 0 else { return }
            close(self.primary)
            self.primary = -1
        }
        source.resume()
        readSource = source

        // The child has to be reaped, or every shell that exits leaves a
        // zombie behind for as long as the app runs.
        let exiting = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit,
                                                       queue: .main)
        exiting.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            waitpid(pid, &status, WNOHANG)
            self.finish(status: status)
        }
        exiting.resume()
        exitSource = exiting

        return true
    }

    private func drain() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(primary, $0.baseAddress, 4096) }
            if count > 0 {
                let chunk = Array(buffer[0..<count])
                DispatchQueue.main.async { [weak self] in self?.onOutput?(chunk) }
                if count < 4096 { return }
                continue
            }
            if count < 0, errno == EINTR { continue }
            // EAGAIN just means "nothing more right now"; anything else — most
            // often EIO when the shell has exited — ends the session.
            if count < 0, errno == EAGAIN { return }
            DispatchQueue.main.async { [weak self] in self?.finish(status: 0) }
            return
        }
    }

    func write(_ text: String) { write(Array(text.utf8)) }

    func write(_ bytes: [UInt8]) {
        guard isRunning, primary >= 0, !bytes.isEmpty else { return }
        var offset = 0
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < bytes.count {
                let written = Darwin.write(primary, base + offset, bytes.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0, errno == EINTR { continue }
                // A full buffer means the child is not reading. Dropping the
                // rest is better than blocking the main thread on it.
                return
            }
        }
    }

    /// Tells the shell the window changed, which is what makes a resized card
    /// rewrap rather than keep drawing at the old width.
    func resize(columns: Int, rows: Int) {
        guard isRunning, primary >= 0 else { return }
        var size = winsize(ws_row: UInt16(max(1, rows)), ws_col: UInt16(max(1, columns)),
                           ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(primary, TIOCSWINSZ, &size)
        if childPID > 0 { kill(childPID, SIGWINCH) }
    }

    /// Sends SIGINT to the foreground process group, which is what ⌃C means.
    /// Writing `\u{03}` would only work when the shell happens to be reading.
    func interrupt() {
        guard isRunning, primary >= 0 else { return }
        var group: pid_t = 0
        if ioctl(primary, TIOCGPGRP, &group) == 0, group > 0 {
            kill(-group, SIGINT)
        } else {
            write([0x03])
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if childPID > 0 {
            kill(-childPID, SIGHUP)
            kill(childPID, SIGHUP)
            var status: Int32 = 0
            waitpid(childPID, &status, WNOHANG)
            childPID = -1
        }
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()   // the cancel handler closes the descriptor
        readSource = nil
    }

    private func finish(status: Int32) {
        guard isRunning else { return }
        isRunning = false
        childPID = -1
        exitSource?.cancel()
        exitSource = nil
        readSource?.cancel()
        readSource = nil
        onExit?(status)
    }

    deinit { stop() }
}
