import Foundation

/// Owns the current, physically-effective cup state and the transition logic.
///
/// Transitions are applied through `PowerManaging`; if applying a desired state
/// throws, the controller keeps its previous state so the icon never lies about
/// what is actually in effect.
public final class CupController {
    public private(set) var state: CupState
    private let power: PowerManaging

    public init(power: PowerManaging, initial: CupState = .empty) {
        self.power = power
        self.state = initial
    }

    /// Cycle empty -> half -> full -> empty (left click).
    @discardableResult
    public func cycle() -> Result<CupState, Error> {
        setState(state.next)
    }

    /// Set the state without applying power effects. Used to reconcile the UI
    /// after an external event (e.g. a helper disconnect) already changed power.
    public func synchronize(to newState: CupState) {
        state = newState
    }

    /// Attempt to move to `desired`. On failure the current state is unchanged.
    @discardableResult
    public func setState(_ desired: CupState) -> Result<CupState, Error> {
        guard desired != state else {
            return .success(state)
        }
        do {
            try power.apply(desired)
            state = desired
            return .success(desired)
        } catch {
            return .failure(error)
        }
    }
}
