import Foundation

/// Anything that can hold IOKit idle-sleep assertions (system + display).
public protocol AssertionControlling: AnyObject {
    func acquire() throws
    func release()
}

/// Anything that can hold the closed-lid lease through the privileged helper.
public protocol LidSleepControlling: AnyObject {
    func enable() throws
    func disable() throws
    /// True while the helper connection backing an active lease is still alive.
    func checkAlive() -> Bool
    /// Whether the helper currently reports an active lease. Throws when the
    /// helper cannot be reached.
    func leaseActive() throws -> Bool
}

/// Reads the actual system `SleepDisabled` value (e.g. via `pmset -g`).
public protocol SleepStateReading: AnyObject {
    func readSleepDisabled() throws -> Bool
}

public struct PowerTransitionError: Error, Equatable, CustomStringConvertible {
    public enum Kind: String, Equatable {
        case applyFailed
        case releaseFailed
        case verificationFailed
        case rollbackFailed
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var description: String { "\(kind.rawValue): \(message)" }
}

/// Combines IOKit assertions and the privileged helper lease into a single
/// `PowerManaging` backend with transactional, verified transitions.
///
/// Important invariants:
/// - `.empty`/`.half` MUST release the closed-lid lease; a release failure is
///   never swallowed (otherwise `SleepDisabled` could stay 1 while the UI claims
///   sleep is allowed).
/// - After any transition we re-read the real `SleepDisabled` value and never
///   claim a state we could not confirm (`uncertain`).
/// - If a transition fails, we roll back to the previous state, but only record
///   that state once the rollback is itself verified; a rollback failure sets
///   `uncertain` and surfaces `rollbackFailed`.
public final class SystemPowerManager: PowerManaging {
    public private(set) var applied: CupState = .empty
    /// True when the real SleepDisabled state could not be confirmed.
    public private(set) var uncertain = false
    /// True when SleepDisabled is observed as true outside our lease.
    public private(set) var externallyBlocked = false

    private let assertions: AssertionControlling
    private let lid: LidSleepControlling
    private let reader: SleepStateReading?

    public var onUnexpectedDisconnect: ((CupState, Bool) -> Void)?

    public init(
        assertions: AssertionControlling,
        lid: LidSleepControlling,
        reader: SleepStateReading? = nil
    ) {
        self.assertions = assertions
        self.lid = lid
        self.reader = reader
    }

    public func apply(_ desired: CupState) throws {
        guard desired != applied else { return }
        let previous = applied
        do {
            try perform(desired)
            let known = try verify(desired)
            applied = desired
            uncertain = (known == nil)
        } catch {
            do {
                try perform(previous)
                let known = try verify(previous)
                applied = previous
                uncertain = (known == nil)
            } catch let rollbackError {
                uncertain = true
                throw PowerTransitionError(
                    .rollbackFailed,
                    "transition to \(desired) failed (\(error)); rollback to \(previous) failed (\(rollbackError))"
                )
            }
            if let transitionError = error as? PowerTransitionError {
                throw transitionError
            }
            throw PowerTransitionError(.applyFailed, "\(error)")
        }
    }

    private func perform(_ state: CupState) throws {
        switch state {
        case .empty:
            do {
                try lid.disable()
            } catch {
                throw PowerTransitionError(.releaseFailed, "failed to release closed-lid lease: \(error)")
            }
            assertions.release()
        case .half:
            do {
                try lid.disable()
            } catch {
                throw PowerTransitionError(.releaseFailed, "failed to release closed-lid lease: \(error)")
            }
            try assertions.acquire()
        case .full:
            try assertions.acquire()
            do {
                try lid.enable()
            } catch {
                throw PowerTransitionError(.applyFailed, "failed to acquire closed-lid lease: \(error)")
            }
        }
    }

    /// Returns true when verified, nil when the real value could not be read.
    /// Throws only on a concrete mismatch that must invalidate the transition.
    private func verify(_ state: CupState) throws -> Bool? {
        guard let reader = reader else { return nil }
        let actual: Bool
        do {
            actual = try reader.readSleepDisabled()
        } catch {
            return nil
        }
        switch state {
        case .full:
            guard actual else {
                throw PowerTransitionError(
                    .verificationFailed,
                    "SleepDisabled is 0 while claiming full mode"
                )
            }
            externallyBlocked = false
        case .empty, .half:
            externallyBlocked = actual
        }
        return true
    }

    /// Called by the app when the helper connection is lost while full.
    /// Drops to `.empty` and never re-acquires the lease. If we cannot confirm
    /// that sleep is allowed again, `uncertain` is set for the UI to surface.
    public func handleLidDisconnect() {
        guard applied == .full else { return }
        var becameUncertain = true
        do {
            try lid.disable()
            becameUncertain = false
        } catch {
            becameUncertain = true
        }
        assertions.release()

        if let reader = reader {
            do {
                let actual = try reader.readSleepDisabled()
                externallyBlocked = actual
                if actual == false {
                    becameUncertain = false
                }
            } catch {
                becameUncertain = true
            }
        } else {
            becameUncertain = true
        }

        applied = .empty
        uncertain = becameUncertain
        onUnexpectedDisconnect?(.empty, becameUncertain)
    }
}
