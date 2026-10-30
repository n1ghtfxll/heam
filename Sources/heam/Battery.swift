import Foundation
import IOKit

/// Battery state from the AppleSmartBattery driver. nil on Macs without a battery.
struct BatteryInfo: Equatable {
    var percent: Int
    var cycles: Int
    /// The cycle count Apple rates the battery for (1000 on recent Macs).
    var ratedCycles: Int?
    var designCapacity: Int?   // mAh when new
    var fullCapacity: Int?     // mAh it holds now when full
    var isCharging: Bool
    var onPower: Bool
    var fullyCharged: Bool
    /// Positive while charging, negative on battery.
    var watts: Double
    var minutesRemaining: Int?
    var adapterWatts: Int?

    /// Remaining capacity versus new, as macOS shows under Battery Health.
    var health: Double? {
        guard let design = designCapacity, let full = fullCapacity, design > 0 else { return nil }
        return min(1, Double(full) / Double(design))
    }

    static func read() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let props = unmanaged?.takeRetainedValue() as? [String: Any],
              props["BatteryInstalled"] as? Bool ?? true else { return nil }

        let data = props["BatteryData"] as? [String: Any] ?? [:]
        func int(_ key: String) -> Int? {
            (props[key] as? NSNumber ?? data[key] as? NSNumber).map { $0.intValue }
        }
        /// Amperage arrives as an unsigned 64-bit value holding a signed number.
        func signed(_ key: String) -> Int {
            guard let n = props[key] as? NSNumber else { return 0 }
            return Int(Int64(bitPattern: n.uint64Value))
        }
        let maxCapacity = max(int("MaxCapacity") ?? 100, 1)
        let charging = props["IsCharging"] as? Bool ?? false
        // 65535 means "still calculating".
        let minutes = charging ? int("AvgTimeToFull") : int("TimeRemaining")
        let adapter = (props["AdapterDetails"] as? [String: Any])?["Watts"] as? NSNumber

        return BatteryInfo(
            percent: min(100, (int("CurrentCapacity") ?? 0) * 100 / maxCapacity),
            cycles: int("CycleCount") ?? 0,
            ratedCycles: int("DesignCycleCount9C"),
            designCapacity: int("DesignCapacity"),
            fullCapacity: int("AppleRawMaxCapacity") ?? int("NominalChargeCapacity"),
            isCharging: charging,
            onPower: props["ExternalConnected"] as? Bool ?? false,
            fullyCharged: props["FullyCharged"] as? Bool ?? false,
            watts: Double(int("Voltage") ?? 0) * Double(signed("InstantAmperage")) / 1_000_000,
            minutesRemaining: minutes.flatMap { $0 > 0 && $0 < 65535 ? $0 : nil },
            adapterWatts: adapter.map { $0.intValue }.flatMap { $0 > 0 ? $0 : nil }
        )
    }
}
