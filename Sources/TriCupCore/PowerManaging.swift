import Foundation

/// Abstraction over whatever makes a `CupState` physically effective.
///
/// The real implementation uses IOKit power assertions (empty/half) and the
/// privileged helper lease (full). Tests inject fakes through this seam.
public protocol PowerManaging: AnyObject {
    /// Make `state` effective. Throws when the state could not be applied, in
    /// which case the caller must keep the previous state.
    func apply(_ state: CupState) throws
}

/// Simple, equatable error used by power backends and the controller.
public struct PowerError: Error, Equatable, CustomStringConvertible {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
