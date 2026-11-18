import Foundation

/// Pure decision logic for whether it is safe to uninstall the helper.
///
/// Fail closed: only `leaseActive == false` AND no residual recovery record is
/// safe. `nil` (unknown/unreachable) is never safe.
public enum UninstallSafety {
    public static func canUninstall(leaseActive: Bool?, hasResidualRecord: Bool) -> Bool {
        guard leaseActive == false else { return false }
        return !hasResidualRecord
    }
}
