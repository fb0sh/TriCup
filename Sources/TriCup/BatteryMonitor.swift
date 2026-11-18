import Foundation
import IOKit.ps
import TriCupCore

/// `BatteryStatusProviding` backed by IOKit power sources. Returns
/// `onBattery == false` on desktops with no internal battery, so the low-battery
/// guard never triggers there.
final class BatteryMonitor: BatteryStatusProviding {
    func current() -> BatteryStatus {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryStatus(onBattery: false, percent: 100)
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            guard (description[kIOPSTypeKey as String] as? String) == (kIOPSInternalBatteryType as String) else {
                continue
            }

            let state = description[kIOPSPowerSourceStateKey as String] as? String
            let onBattery = (state == (kIOPSBatteryPowerValue as String))
            let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int ?? 100
            let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int ?? 100
            let percent = maxCapacity > 0
                ? Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
                : 100
            return BatteryStatus(onBattery: onBattery, percent: percent)
        }

        return BatteryStatus(onBattery: false, percent: 100)
    }
}
