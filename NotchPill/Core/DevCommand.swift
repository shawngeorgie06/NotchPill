import Foundation

/// A command reported by the opt-in wrapper or a developer activity posted
/// through `notchpill`.
/// The JSON stores Unix timestamps so shell scripts can produce it without
/// depending on Swift's date encoding conventions.
struct DevCommand: Identifiable, Equatable, Decodable {
    enum State: String, Decodable {
        case running, waiting, passed, failed

        var isActive: Bool { self == .running || self == .waiting }
        var label: String {
            switch self {
            case .running: return "Running"
            case .waiting: return "Needs input"
            case .passed: return "Passed"
            case .failed: return "Failed"
            }
        }
    }

    let id: String
    let title: String
    /// Executable name only. Arguments may contain credentials and are never stored.
    let command: String
    let detail: String?
    let projectPath: String?
    let source: String?
    let bundleId: String?
    let terminalTTY: String?
    var state: State
    let startedAt: Date
    var endedAt: Date?
    var exitCode: Int?
    let processId: Int32?
    let updatedAt: Date

    var displayTitle: String { SecretRedactor.redact(String(title.prefix(100))) }
    var displayDetail: String? { detail.map { SecretRedactor.redact(String($0.prefix(140))) } }
    var displayProject: String? {
        projectPath.map { SecretRedactor.redact(URL(fileURLWithPath: $0).lastPathComponent) }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, command, detail, projectPath, source, bundleId, terminalTTY
        case state, startedAt, endedAt, exitCode, processId, updatedAt
    }

    init(id: String, title: String, command: String, detail: String? = nil,
         projectPath: String? = nil,
         source: String? = nil, bundleId: String? = nil, terminalTTY: String? = nil,
         state: State, startedAt: Date, endedAt: Date? = nil,
         exitCode: Int? = nil, processId: Int32? = nil, updatedAt: Date) {
        self.id = id
        self.title = title
        self.command = command
        self.detail = detail
        self.projectPath = projectPath
        self.source = source
        self.bundleId = bundleId
        self.terminalTTY = terminalTTY
        self.state = state
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.processId = processId
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        command = try c.decode(String.self, forKey: .command)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        projectPath = try c.decodeIfPresent(String.self, forKey: .projectPath)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        bundleId = try c.decodeIfPresent(String.self, forKey: .bundleId)
        terminalTTY = try c.decodeIfPresent(String.self, forKey: .terminalTTY)
        state = try c.decode(State.self, forKey: .state)
        startedAt = Date(timeIntervalSince1970: try c.decode(TimeInterval.self, forKey: .startedAt))
        endedAt = try c.decodeIfPresent(TimeInterval.self, forKey: .endedAt)
            .map(Date.init(timeIntervalSince1970:))
        exitCode = try c.decodeIfPresent(Int.self, forKey: .exitCode)
        processId = try c.decodeIfPresent(Int32.self, forKey: .processId)
        updatedAt = Date(timeIntervalSince1970: try c.decode(TimeInterval.self, forKey: .updatedAt))
    }
}
