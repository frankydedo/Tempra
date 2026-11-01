import Foundation
import IOKit
import IOKit.ps

/// Reads battery state from IOPowerSources (what macOS shows) and AppleSmartBattery (raw gauge data).
enum BatteryReader {
    static func read() -> BatteryInfo? {
        guard let service = smartBatteryService() else { return nil }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dict = props?.takeRetainedValue() as? [String: Any] else { return nil }

        var info = BatteryInfo()
        let batteryData = dict["BatteryData"] as? [String: Any] ?? [:]

        info.cycleCount = int(dict["CycleCount"]) ?? 0
        info.designCapacity = int(dict["DesignCapacity"]) ?? int(batteryData["DesignCapacity"]) ?? 0
        info.nominalCapacity = int(dict["NominalChargeCapacity"]) ?? int(batteryData["NominalChargeCapacity"])
            ?? int(dict["AppleRawMaxCapacity"]) ?? 0
        info.currentCapacity = int(dict["AppleRawCurrentCapacity"]) ?? int(batteryData["RemainingCapacity"]) ?? 0
        info.voltage = Double(int(dict["Voltage"]) ?? 0) / 1000
        info.amperage = Double(signed(dict["InstantAmperage"] ?? dict["Amperage"])) / 1000
        info.onAC = (dict["ExternalConnected"] as? Bool) ?? false
        info.isCharging = (dict["IsCharging"] as? Bool) ?? false
        info.isFullyCharged = (dict["FullyCharged"] as? Bool) ?? false

        if let telemetry = dict["PowerTelemetryData"] as? [String: Any],
           let load = int(telemetry["SystemLoad"]), load > 0 {
            info.systemPower = Double(load) / 1000
        }
        if let adapter = dict["AdapterDetails"] as? [String: Any] {
            info.adapterWatts = int(adapter["Watts"])
            info.adapterName = adapter["Name"] as? String ?? adapter["Description"] as? String
        }

        // Percentage and time estimates exactly as shown by macOS.
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let desc = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                      desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                if let current = int(desc[kIOPSCurrentCapacityKey]), let max = int(desc[kIOPSMaxCapacityKey]), max > 0 {
                    info.percent = Double(current) / Double(max) * 100
                }
                if let empty = int(desc[kIOPSTimeToEmptyKey]), empty > 0 { info.minutesToEmpty = empty }
                if let full = int(desc[kIOPSTimeToFullChargeKey]), full > 0 { info.minutesToFull = full }
                if let charging = desc[kIOPSIsChargingKey] as? Bool { info.isCharging = charging }
                info.onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            }
        }
        if info.percent == 0, let max = int(dict["MaxCapacity"]), max > 0, let cur = int(dict["CurrentCapacity"]) {
            info.percent = Double(cur) / Double(max) * 100
        }
        return info
    }

    private static func smartBatteryService() -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        return service == 0 ? nil : service
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: n.intValue
        case let i as Int: i
        default: nil
        }
    }

    /// The gauge reports current as an unsigned 64-bit value that is really a signed mA reading.
    private static func signed(_ value: Any?) -> Int64 {
        guard let n = value as? NSNumber else { return 0 }
        return Int64(bitPattern: n.uint64Value)
    }
}
