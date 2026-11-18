import Foundation

public struct BatteryStatus: Equatable, Sendable {
    public let onBattery: Bool
    public let percent: Int

    public init(onBattery: Bool, percent: Int) {
        self.onBattery = onBattery
        self.percent = percent
    }
}

public protocol BatteryStatusProviding: AnyObject {
    func current() -> BatteryStatus
}

/// Blocks / exits full mode when running on battery at or below a fixed
/// threshold (20% by policy). Desktops (no battery) never trigger it.
public struct LowBatteryGuard: Sendable {
    public let threshold: Int

    public init(threshold: Int = 20) {
        self.threshold = threshold
    }

    public func blocksFull(_ status: BatteryStatus) -> Bool {
        status.onBattery && status.percent <= threshold
    }

    public func shouldExitFull(_ status: BatteryStatus) -> Bool {
        blocksFull(status)
    }
}
