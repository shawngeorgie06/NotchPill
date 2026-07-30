import AppKit
import Foundation

/// Running and detecting the bundled `install-agent-hooks.sh`.
///
/// This used to live inside `MenuBarController`; the onboarding guide needs the
/// same button, and duplicating a `Process` launch is how two call sites drift.
enum AgentHooks {
    /// Where each agent keeps the config the installer writes into, relative to
    /// home. Detection is a substring check because that is exactly what the
    /// installer's own `--status` does, and the two must agree.
    nonisolated static let configPaths = [
        ".claude/settings.json",
        ".codex/config.toml",
        ".cursor/hooks.json",
    ]

    nonisolated static func isInstalled(inConfig contents: String) -> Bool {
        contents.range(of: "notchpill", options: .caseInsensitive) != nil
    }

    /// True when *any* agent is wired up. Not all three — most people use one,
    /// and asking someone who has Claude Code set up to keep looking at a
    /// "not configured" step because they don't use Codex would be wrong.
    static func isInstalled(home: String = NSHomeDirectory()) -> Bool {
        configPaths.contains { path in
            guard let text = try? String(contentsOfFile: (home as NSString)
                .appendingPathComponent(path), encoding: .utf8) else { return false }
            return isInstalled(inConfig: text)
        }
    }

    /// Strips the ANSI colouring the script writes for a terminal.
    nonisolated static func cleanOutput(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs the installer off the main thread and hands back its transcript.
    /// The script ships inside the app bundle, so this works for someone who
    /// installed via Homebrew and never cloned the repo.
    static func install(completion: @escaping (String) -> Void) {
        guard let script = Bundle.main.url(forResource: "install-agent-hooks",
                                           withExtension: "sh",
                                           subdirectory: "Scripts") else {
            completion("This build of NotchPill did not ship Scripts/install-agent-hooks.sh.")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        DispatchQueue.global(qos: .userInitiated).async {
            var output = ""
            do {
                try task.run()
                // Read before waiting: a full pipe buffer would deadlock the
                // script against us.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                output = String(decoding: data, as: UTF8.self)
            } catch {
                output = "Couldn't run the setup script: \(error.localizedDescription)"
            }
            let cleaned = cleanOutput(output)
            DispatchQueue.main.async {
                // Which agents ended up wired is the single most common cause of
                // "the notch stopped telling me anything".
                LogStore.log("hooks", "installer finished — "
                    + (isInstalled() ? "at least one agent wired up" : "nothing wired up"),
                    level: isInstalled() ? .info : .warn)
                completion(cleaned)
            }
        }
    }
}
