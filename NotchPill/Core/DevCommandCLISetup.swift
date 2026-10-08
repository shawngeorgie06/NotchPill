import Foundation

/// Installs the bundled `notchpill` activity CLI into a directory the user
/// chooses, usually one already present in their shell's PATH.
enum DevCommandCLISetup {
    enum SetupError: LocalizedError {
        case missingBundledTool(String)
        case destinationIsNotDirectory
        case destinationNotWritable

        var errorDescription: String? {
            switch self {
            case .missingBundledTool(let name):
                return "The bundled \(name) command is missing from this app."
            case .destinationIsNotDirectory:
                return "Choose an existing folder for the command line tools."
            case .destinationNotWritable:
                return "NotchPill cannot write to that folder. Choose a writable PATH folder."
            }
        }
    }

    static let examples = """
    # Start an activity and keep its ID for later updates
    activity_id="$(notchpill working --title 'Unit tests' --detail 'Running test suite')"

    # Mark it as waiting for input
    notchpill waiting --id "$activity_id" --detail 'Review the migration plan'

    # Finish successfully, or report a failing exit code
    notchpill done --id "$activity_id" --detail 'Tests passed'
    notchpill error --id "$activity_id" --exit-code 1 --detail 'Tests failed'

    # Wrap a command while preserving its output and exit status
    notchpill-command.sh --title 'Unit tests' -- npm test
    """

    static func isInstalled(in directory: URL, fileManager: FileManager = .default) -> Bool {
        ["notchpill", "notchpill-command.sh"].allSatisfy { name in
            let path = directory.appendingPathComponent(name).path
            return fileManager.isExecutableFile(atPath: path)
        }
    }

    /// Copies both executable scripts from the signed app bundle. The
    /// destination is intentionally supplied by the caller after a folder
    /// picker, so this helper never chooses or modifies shell configuration.
    static func install(to destination: URL, bundle: Bundle = .main,
                        fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw SetupError.destinationIsNotDirectory }

        let resources = bundle.resourceURL?.appendingPathComponent("Scripts", isDirectory: true)
        guard let resources else { throw SetupError.missingBundledTool("notchpill") }
        let tools = ["notchpill", "notchpill-command.sh"]
        let sources = try tools.map { name -> (String, Data) in
            let source = resources.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: source) else {
                throw SetupError.missingBundledTool(name)
            }
            return (name, data)
        }

        // Validate write access before replacing either existing command.
        let probe = destination.appendingPathComponent(".notchpill-write-test-\(UUID().uuidString)")
        guard fileManager.createFile(atPath: probe.path, contents: Data()) else {
            throw SetupError.destinationNotWritable
        }
        try? fileManager.removeItem(at: probe)

        let prior = Dictionary(uniqueKeysWithValues: tools.map { name in
            (name, try? Data(contentsOf: destination.appendingPathComponent(name)))
        })
        let priorModes = Dictionary(uniqueKeysWithValues: tools.map { name in
            let attributes = try? fileManager.attributesOfItem(atPath: destination.appendingPathComponent(name).path)
            return (name, attributes?[.posixPermissions] as? NSNumber)
        })
        var installed: [String] = []
        do {
            for (name, data) in sources {
                let target = destination.appendingPathComponent(name)
                try data.write(to: target, options: .atomic)
                installed.append(name)
                try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
        } catch {
            for name in installed {
                let target = destination.appendingPathComponent(name)
                if let original = prior[name] ?? nil {
                    try? original.write(to: target, options: .atomic)
                    if let mode = priorModes[name] ?? nil {
                        try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
                    }
                } else {
                    try? fileManager.removeItem(at: target)
                }
            }
            throw error
        }
    }
}
