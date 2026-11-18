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
}

/// Combines IOKit assertions and the privileged helper lease into a single
/// `PowerManaging` backend with transactional transitions.
///
/// - `.empty` releases the lease and all assertions.
/// - `.half` releases the lease and holds system+display assertions.
/// - `.full` holds system+display assertions and the closed-lid lease.
///
/// If applying a state fails, the previous state's effects are re-applied so the
/// UI and the real power state stay in agreement.
public final class SystemPowerManager: PowerManaging {
    public private(set) var applied: CupState = .empty

    private let assertions: AssertionControlling
    private let lid: LidSleepControlling

    /// Called after an unexpected helper disconnect forces a drop to `.empty`.
    public var onUnexpectedDisconnect: ((CupState) -> Void)?

    public init(assertions: AssertionControlling, lid: LidSleepControlling) {
        self.assertions = assertions
        self.lid = lid
    }

    public func apply(_ state: CupState) throws {
        guard state != applied else { return }
        let previous = applied
        do {
            try perform(state)
            applied = state
        } catch {
            try? perform(previous)
            applied = previous
            throw error
        }
    }

    private func perform(_ state: CupState) throws {
        switch state {
        case .empty:
            try? lid.disable()
            assertions.release()
        case .half:
            try? lid.disable()
            try assertions.acquire()
        case .full:
            try assertions.acquire()
            try lid.enable()
        }
    }

    /// Called by the app when the helper connection is lost while full.
    /// Drops to `.empty` (allowing sleep) and never re-acquires the lease.
    public func handleLidDisconnect() {
        guard applied == .full else { return }
        try? lid.disable()
        assertions.release()
        applied = .empty
        onUnexpectedDisconnect?(.empty)
    }
}
