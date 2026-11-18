import Foundation
import IOKit.ps
import TriCupCore

/// `BatteryStatusProviding` backed by IOKit power sources.
///
/// Distinguishes:
/// - battery present and readable → normal status;
/// - readable but no internal battery (desktop) → `hasBattery == false`;
/// - battery info unreadable → `isAvailable == false` (for a battery-equipped
///   Mac we remember that it has a battery so the low-battery guard fails closed).
final class BatteryMonitor: BatteryStatusProviding {
    /// Remembers whether the machine has an internal battery, so an unreadable
    /// power source on a MacBook is still treated as "battery-equipped".
    private var lastHasBattery: Bool?

    func current() -> BatteryStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryStatus(
                isAvailable: false,
                hasBattery: lastHasBattery ?? true,
                onBattery: false,
                percent: 0
            )
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else {
                continue
            }
            lastHasBattery = true
            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let onBattery = (state == (kIOPSBatteryPowerValue as String))
            guard let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int,
                  let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int,
                  maxCapacity > 0
            else {
                return BatteryStatus(isAvailable: false, hasBattery: true, onBattery: onBattery, percent: 0)
            }
            let percent = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
            return BatteryStatus(isAvailable: true, hasBattery: true, onBattery: onBattery, percent: percent)
        }

        // Readable power sources but no internal battery (desktop).
        lastHasBattery = false
        return BatteryStatus(isAvailable: true, hasBattery: false, onBattery: false, percent: 0)
    }
}
