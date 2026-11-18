import Foundation

/// Owns TriCup's single closed-lid lease and the restoration of the original
/// `SleepDisabled` value.
///
/// Invariants (see ADR-0001):
/// - The original value is read and the lease persisted *before* the system
///   setting is modified.
/// - Only one lease may be active at a time.
/// - The original value is restored on release, with read-back verification and
///   a bounded number of retries.
/// - If restoration fails the persisted record is kept so a later attempt (or a
///   helper restart) can finish the job. The record is cleared only after a
///   verified restore.
public final class LeaseManager {
    private let setting: SleepDisabledSetting
    private let store: LeaseStoring
    private let maxRestoreAttempts: Int

    public private(set) var activeRecord: LeaseRecord?

    public init(
        setting: SleepDisabledSetting,
        store: LeaseStoring,
        maxRestoreAttempts: Int = 3
    ) {
        self.setting = setting
        self.store = store
        self.maxRestoreAttempts = max(1, maxRestoreAttempts)
    }

    public var isActive: Bool { activeRecord != nil }

    /// Acquire the lease: persist the original value, enable `SleepDisabled` and
    /// verify it actually took effect.
    public func enable() throws {
        if activeRecord != nil {
            throw LeaseError.alreadyActive
        }

        let existing: LeaseRecord?
        do {
            existing = try store.load()
        } catch {
            throw LeaseError.persistenceFailed(String(describing: error))
        }
        if existing != nil {
            // A residual lease must be recovered before a new one is accepted.
            throw LeaseError.alreadyActive
        }

        let original: Bool
        do {
            original = try setting.readSleepDisabled()
        } catch {
            throw LeaseError.applyFailed("read before enable failed: \(error)")
        }

        let record = LeaseRecord(originalSleepDisabled: original)
        do {
            try store.save(record)
        } catch {
            // Persistence failed: do not touch the system setting.
            throw LeaseError.persistenceFailed(String(describing: error))
        }

        do {
            try setting.writeSleepDisabled(true)
        } catch {
            rollbackOrKeep(record)
            throw LeaseError.applyFailed(String(describing: error))
        }

        let effective: Bool
        do {
            effective = try setting.readSleepDisabled()
        } catch {
            rollbackOrKeep(record)
            throw LeaseError.verificationFailed("read-back failed: \(error)")
        }
        guard effective == true else {
            rollbackOrKeep(record)
            throw LeaseError.verificationFailed("SleepDisabled did not become true")
        }

        activeRecord = record
    }

    /// Release the lease and restore the original value. Idempotent: safe to call
    /// when no lease is active.
    public func disable() throws {
        if let active = activeRecord {
            try performRestore(active)
            return
        }
        let stored: LeaseRecord?
        do {
            stored = try store.load()
        } catch {
            return
        }
        if let stored = stored {
            try performRestore(stored)
        }
    }

    /// On helper start (after a crash or reboot) restore any residual lease.
    public func recoverOnStartup() throws {
        guard let record = try store.load() else {
            activeRecord = nil
            return
        }
        try performRestore(record)
    }

    private func performRestore(_ record: LeaseRecord) throws {
        guard restoreWithRetries(record) else {
            // Keep the persisted record so a later attempt can retry.
            throw LeaseError.restoreFailed(
                "could not restore SleepDisabled to \(record.originalSleepDisabled)"
            )
        }
        do {
            try store.clear()
        } catch {
            // Restore succeeded; a leftover record is harmless (idempotent retry
            // on next start) but surface it so it is not silently lost.
            throw LeaseError.persistenceFailed("restored but clearing record failed: \(error)")
        }
        activeRecord = nil
    }

    private func rollbackOrKeep(_ record: LeaseRecord) {
        if restoreWithRetries(record) {
            try? store.clear()
        }
    }

    /// Writes the original value and verifies the read-back, retrying a bounded
    /// number of times. Returns true only when a verified restore succeeded.
    private func restoreWithRetries(_ record: LeaseRecord) -> Bool {
        for _ in 0..<maxRestoreAttempts {
            do {
                try setting.writeSleepDisabled(record.originalSleepDisabled)
                if try setting.readSleepDisabled() == record.originalSleepDisabled {
                    return true
                }
            } catch {
                // try again
            }
        }
        return false
    }
}
