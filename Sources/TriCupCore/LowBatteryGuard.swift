import Foundation

public struct BatteryStatus: Equatable, Sendable {
    /// False when battery information could not be read at all.
    public let isAvailable: Bool
    /// False on desktops / Macs with no internal battery.
    public let hasBattery: Bool
    public let onBattery: Bool
    public let percent: Int

    public init(
        isAvailable: Bool = true,
        hasBattery: Bool = true,
        onBattery: Bool,
        percent: Int
    ) {
        self.isAvailable = isAvailable
        self.hasBattery = hasBattery
        self.onBattery = onBattery
        self.percent = percent
    }
}

public protocol BatteryStatusProviding: AnyObject {
    func current() -> BatteryStatus
}

/// Blocks / exits full mode when running on battery at or below a fixed
/// threshold (15% by policy). Desktops (no battery) never trigger it, and
/// unreadable battery info on a battery-equipped Mac fails closed.
public struct LowBatteryGuard: Sendable {
    public let threshold: Int

    public init(threshold: Int = 15) {
        self.threshold = threshold
    }

    public func blocksFull(_ status: BatteryStatus) -> Bool {
        // Desktops (no internal battery) never block.
        guard status.hasBattery else { return false }
        // On a battery-equipped Mac, unknown battery info is unsafe: fail closed.
        if !status.isAvailable { return true }
        return status.onBattery && status.percent <= threshold
    }

    public func shouldExitFull(_ status: BatteryStatus) -> Bool {
        blocksFull(status)
    }
}
