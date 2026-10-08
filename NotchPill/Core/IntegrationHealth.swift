import Foundation
import Combine

enum IntegrationHealthState: String, Sendable {
    case notChecked
    case ready
    case toolMissing
    case permissionNeeded
    case signedOut
    case retrying
}

struct IntegrationHealthRecord: Sendable {
    var state: IntegrationHealthState
    var updatedAt: Date?
    var retryAt: Date?
}

/// Structured outcomes from work integrations already perform. This store does
/// not inspect credentials or start checks on its own.
@MainActor
final class IntegrationHealthStore: ObservableObject {
    static let shared = IntegrationHealthStore()

    @Published private(set) var records: [String: IntegrationHealthRecord] = [:]

    private init() {}

    func record(_ key: String, state: IntegrationHealthState,
                updatedAt: Date? = nil, retryAt: Date? = nil) {
        records[key] = IntegrationHealthRecord(state: state, updatedAt: updatedAt,
                                                retryAt: retryAt)
    }

    nonisolated static func report(_ key: String, state: IntegrationHealthState,
                                   updatedAt: Date? = nil, retryAt: Date? = nil) {
        Task { @MainActor in
            shared.record(key, state: state, updatedAt: updatedAt, retryAt: retryAt)
        }
    }
}
