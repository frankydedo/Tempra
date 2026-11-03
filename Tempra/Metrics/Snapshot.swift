import Foundation

/// One reading of every vital sign, taken at `date`.
struct Snapshot: Sendable {
    var date = Date()

    // CPU (fractions 0...1)
    var cpuTotal: Double = 0
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuCores: [Double] = []
    var efficiencyCoreCount = 0
    var loadAverage: (Double, Double, Double) = (0, 0, 0)

    // GPU (fractions 0...1, memory in bytes)
    var gpu: Double?
    var gpuRenderer: Double = 0
    var gpuTiler: Double = 0
    var gpuMemoryInUse: UInt64 = 0
    var gpuMemoryAllocated: UInt64 = 0

    // Memory (bytes)
    var memTotal: UInt64 = 0
    var memUsed: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0
    /// Bytes per second being written to swap right now.
    var swapOutRate: Double = 0
    /// 0...1, derived from kern.memorystatus_level (same idea as Activity Monitor's pressure graph).
    var memPressure: Double = 0
    var memPressureLevel: MemoryPressureLevel = .normal

    // Thermals (°C)
    var socTemp: Double?
    var socTempMax: Double?
    var batteryTemp: Double?
    var ssdTemp: Double?
    var thermalState: ProcessInfo.ThermalState = .nominal
    /// One entry per fan; empty on fanless Macs.
    var fans: [FanReading] = []

    /// Average fan speed, nil on fanless Macs.
    var fanRPM: Double? { fans.isEmpty ? nil : fans.map(\.rpm).reduce(0, +) / Double(fans.count) }
    var fanText: String? {
        guard let rpm = fanRPM else { return nil }
        return rpm > 0 ? Metric.fanRPM.format(rpm) : "Fan off"
    }

    // Battery & power
    var battery: BatteryInfo?
    /// Real-time power by component (SMC and IOReport).
    var power = PowerReading()

    // I/O (bytes per second)
    var netIn: Double = 0
    var netOut: Double = 0
    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskFree: Int64 = 0
    var diskTotal: Int64 = 0

    var memUsedFraction: Double { memTotal > 0 ? Double(memUsed) / Double(memTotal) : 0 }

    /// macOS is deliberately running the Mac from the battery while plugged in (battery health
    /// management lets it drain a few percent before charging again; "Charge to Full Now" ends it):
    /// it reports a reason for not charging and the adapter is nearly idle. Seen here: 0.6 W in from a
    /// 58 W adapter. An adapter that's too weak looks different: it delivers close to its rating.
    var macOSRunsOnBattery: Bool {
        guard let b = battery, b.onAC, !b.isCharging, b.notChargingReason != 0 else { return false }
        let input = power.adapterInput ?? 0
        return input < max(Double(b.adapterWatts ?? 0) * 0.25, 2)
    }
}

enum MemoryPressureLevel: Int, Sendable {
    case normal = 1, warning = 2, critical = 4

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

struct BatteryInfo: Sendable {
    var percent: Double = 0
    var isCharging = false
    var onAC = false
    var isFullyCharged = false
    /// Minutes, as estimated by macOS. nil while calculating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var cycleCount: Int = 0
    var designCapacity: Int = 0      // mAh
    var nominalCapacity: Int = 0     // mAh, what Apple calls "Maximum Capacity"
    var currentCapacity: Int = 0     // mAh
    var voltage: Double = 0          // V
    var amperage: Double = 0         // A, negative while discharging
    /// Whole-system power draw in watts (from the battery's telemetry).
    var systemPower: Double?
    var adapterWatts: Int?
    var adapterName: String?
    /// macOS's own low-battery warning (the one behind its "battery low" alerts).
    var lowBatteryWarning: LowBatteryWarning = .none
    /// macOS's battery condition, e.g. "Service Recommended", when it reports one.
    var healthCondition: String?
    /// Charger flags from AppleSmartBattery's ChargerData: non-zero when macOS is deliberately not
    /// charging (charge limit, optimized charging, temperature) or charging slowly.
    var notChargingReason = 0
    var slowChargingReason = 0

    enum LowBatteryWarning: Sendable {
        /// Early: below about 22%. Final: less than about 10 minutes left.
        case none, early, final
    }

    var needsService: Bool {
        guard let condition = healthCondition?.lowercased() else { return false }
        return condition.contains("service") || condition.contains("check") || condition.contains("fail")
    }

    /// Watts flowing in (+) or out (-) of the battery.
    var batteryPower: Double { voltage * amperage }
    var health: Double { designCapacity > 0 ? Double(nominalCapacity) / Double(designCapacity) : 0 }
}

struct ProcessSample: Identifiable, Sendable {
    var id: Int32 { pid }
    let pid: Int32
    let name: String
    let user: String
    let cpu: Double        // percent of one core
    let memory: UInt64     // bytes (resident)
}
