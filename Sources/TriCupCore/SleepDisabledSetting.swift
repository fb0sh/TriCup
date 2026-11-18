import Foundation

/// Reads and writes the system-wide `SleepDisabled` power setting.
///
/// The real implementation shells out to `/usr/bin/pmset` from the privileged
/// helper. Tests inject a fake through this seam.
public protocol SleepDisabledSetting {
    func readSleepDisabled() throws -> Bool
    func writeSleepDisabled(_ disabled: Bool) throws
}

/// Persistent record of an active TriCup lease, used to restore the original
/// power setting after a crash, helper restart or reboot.
public struct LeaseRecord: Codable, Equatable, Sendable {
    /// Value of `SleepDisabled` observed before TriCup changed it.
    public let originalSleepDisabled: Bool
    public let createdAt: Date
    public let schemaVersion: Int

    public init(originalSleepDisabled: Bool, createdAt: Date = Date()) {
        self.originalSleepDisabled = originalSleepDisabled
        self.createdAt = createdAt
        self.schemaVersion = 1
    }
}

/// Persists at most one lease record.
public protocol LeaseStoring {
    /// Returns the stored record, or `nil` when there is none.
    func load() throws -> LeaseRecord?
    /// Persist the record before any system setting is modified.
    func save(_ record: LeaseRecord) throws
    /// Remove the record only after the original setting is confirmed restored.
    func clear() throws
}

public enum LeaseError: Error, Equatable, CustomStringConvertible {
    case alreadyActive
    case persistenceFailed(String)
    case applyFailed(String)
    case verificationFailed(String)
    case restoreFailed(String)

    public var description: String {
        switch self {
        case .alreadyActive: return "a lease is already active"
        case .persistenceFailed(let m): return "lease persistence failed: \(m)"
        case .applyFailed(let m): return "failed to enable SleepDisabled: \(m)"
        case .verificationFailed(let m): return "SleepDisabled verification failed: \(m)"
        case .restoreFailed(let m): return "failed to restore SleepDisabled: \(m)"
        }
    }
}
