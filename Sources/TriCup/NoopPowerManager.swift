import TriCupCore

/// Placeholder power backend for the T1 walking skeleton.
///
/// Power behaviour is NOT implemented yet: the menu-bar UI and state machine are
/// wired up, but nothing actually prevents sleep. Real IOKit assertions arrive
/// in T2 and the privileged helper lease in T3–T5.
final class NoopPowerManager: PowerManaging {
    func apply(_ state: CupState) throws {
        // Intentionally does nothing in T1.
    }
}
