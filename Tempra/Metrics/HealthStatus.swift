import SwiftUI

/// Normal / Warning / Critical state of a metric. macOS's own signals are used where they exist
/// (memory pressure, thermal state, low-battery warning, battery service condition); the rest use
/// Tempra's thresholds below.
enum HealthState: Int, Comparable, Sendable {
    case normal, warning, critical

    static func < (lhs: HealthState, rhs: HealthState) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// Normal is deliberately uncoloured so Warning and Critical stand out.
    var color: Color? {
        switch self {
        case .normal: nil
        case .warning: .orange
        case .critical: .red
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .normal: nil
        case .warning: .systemOrange
        case .critical: .systemRed
        }
    }
}

/// The statistics that have a health state.
enum HealthMetric: CaseIterable {
    case cpu, gpu, memory, thermal, battery, batteryHealth, power, disk
}

enum HealthRules {
    /// CPU and GPU use the average of the last minute: short spikes are normal.
    static let loadWindow: TimeInterval = 60
    static let loadWarning = 0.75
    static let loadCritical = 0.90

    /// Battery runtime at the current draw, in hours.
    static let runtimeWarning = 2.0
    static let runtimeCritical = 1.0
    /// On the adapter: share of the adapter's rating above which it may not keep up.
    static let adapterWarning = 0.9
    /// On the adapter: battery power (W) below which the battery is helping the adapter.
    static let adapterDischargeWatts = -3.0
    /// ...and for how long it must last. The battery gauge refreshes only every 30–60 s, so right
    /// after plugging in it still reports the discharge; requiring two minutes of continuous
    /// adapter + discharge readings filters that out.
    static let adapterDischargeWindow: TimeInterval = 120

    static let diskWarningBytes: Int64 = 20_000_000_000
    static let diskWarningFraction = 0.10
    static let diskCriticalBytes: Int64 = 5_000_000_000
    static let diskCriticalFraction = 0.03

    static let healthWarning = 0.80

    /// Memory pressure (100% − macOS's available-memory level, the value Activity Monitor plots)
    /// and swap-out rate thresholds, held for `memoryShare` of the last `memoryWindow`.
    static let memoryWarningPressure = 0.70
    static let memoryCriticalPressure = 0.85
    static let swapWarningRate = 1_000_000.0      // 1 MB/s written to swap
    static let swapCriticalRate = 20_000_000.0    // 20 MB/s
    static let memoryWindow: TimeInterval = 60
    static let memoryShare = 0.8

    /// A metric returns to a calmer state only after it has stayed there this long.
    static let recoveryDelay: TimeInterval = 120
    /// Metrics that can hover around a threshold. Battery and power follow the adapter instantly.
    static let hysteresis: Set<HealthMetric> = [.cpu, .gpu, .memory, .thermal, .disk]
}

extension Snapshot {
    func health(_ metric: HealthMetric, live: [Metric: [ChartPoint]]) -> HealthState {
        switch metric {
        case .cpu:
            return Self.loadState(Self.recentAverage(live[.cpu]) ?? cpuTotal)
        case .gpu:
            guard let gpu else { return .normal }
            return Self.loadState(Self.recentAverage(live[.gpu]) ?? gpu)
        case .memory:
            // Follows what Activity Monitor's colours mean: little memory left (its graph is the same
            // pressure percentage) or active swapping. macOS's "warning" level is not used: it's a hint
            // for apps to drop caches and can stay raised with half the memory free.
            if memPressureLevel == .critical
                || Self.sustained(live[.memPressure], above: HealthRules.memoryCriticalPressure)
                || Self.sustained(live[.swapOut], above: HealthRules.swapCriticalRate) { return .critical }
            if Self.sustained(live[.memPressure], above: HealthRules.memoryWarningPressure)
                || Self.sustained(live[.swapOut], above: HealthRules.swapWarningRate) { return .warning }
            return .normal
        case .thermal:
            switch thermalState {
            case .nominal, .fair: return .normal
            case .serious: return .warning
            case .critical: return .critical
            @unknown default: return .normal
            }
        case .battery:
            guard let b = battery, !b.onAC else { return .normal }
            switch b.lowBatteryWarning {
            case .final: return .critical
            case .early: return .warning
            case .none: return .normal
            }
        case .batteryHealth:
            guard let b = battery else { return .normal }
            if b.needsService { return .critical }
            return b.health > 0 && b.health < HealthRules.healthWarning ? .warning : .normal
        case .power:
            guard let b = battery, let power = b.systemPower, power > 0 else { return .normal }
            if b.onAC {
                if Self.sustainedDischargeOnAdapter(live) { return .critical }
                if let watts = b.adapterWatts, watts > 0, power > Double(watts) * HealthRules.adapterWarning { return .warning }
                return .normal
            }
            guard let hours = b.runtimeHours else { return .normal }
            if hours < HealthRules.runtimeCritical { return .critical }
            return hours < HealthRules.runtimeWarning ? .warning : .normal
        case .disk:
            guard diskTotal > 0 else { return .normal }
            let fraction = Double(diskFree) / Double(diskTotal)
            if diskFree < HealthRules.diskCriticalBytes || fraction < HealthRules.diskCriticalFraction { return .critical }
            if diskFree < HealthRules.diskWarningBytes || fraction < HealthRules.diskWarningFraction { return .warning }
            return .normal
        }
    }

    /// The values behind a state, for logs ("why did this turn Critical?").
    func healthDetail(_ metric: HealthMetric, live: [Metric: [ChartPoint]]) -> String {
        switch metric {
        case .cpu:
            return String(format: "CPU %.0f%%, 1-min avg %.0f%%", cpuTotal * 100, (Self.recentAverage(live[.cpu]) ?? cpuTotal) * 100)
        case .gpu:
            return String(format: "GPU %.0f%%, 1-min avg %.0f%%", (gpu ?? 0) * 100, (Self.recentAverage(live[.gpu]) ?? gpu ?? 0) * 100)
        case .memory:
            return String(format: "pressure %.0f%% (macOS level %@), used %@, swap %@, swapping out %@/s",
                          memPressure * 100, memPressureLevel.label, Format.bytes(memUsed), Format.bytes(swapUsed),
                          Format.bytes(swapOutRate))
        case .thermal:
            return String(format: "thermal state %@, SoC %.0f°C, hotspot %.0f°C", thermalStateText, socTemp ?? 0, socTempMax ?? 0)
        case .battery, .batteryHealth, .power:
            guard let b = battery else { return "no battery" }
            return String(format: "%@, %.0f%%, system %.1f W, battery %.2f A × %.2f V, adapter %@, runtime %@, low-battery warning %@, health %.1f%%%@",
                          b.onAC ? "on adapter" : "on battery", b.percent, b.systemPower ?? 0, b.amperage, b.voltage,
                          b.adapterWatts.map { "\($0) W" } ?? "—", b.runtimeHours.map { String(format: "%.1f h", $0) } ?? "—",
                          String(describing: b.lowBatteryWarning), b.health * 100,
                          (b.healthCondition.map { ", condition \($0)" } ?? "")
                            + (b.notChargingReason != 0 ? ", not charging reason \(b.notChargingReason)" : "")
                            + (b.slowChargingReason != 0 ? ", slow charging reason \(b.slowChargingReason)" : ""))
        case .disk:
            return "free \(Format.bytes(Double(diskFree))) of \(Format.bytes(Double(diskTotal)))"
        }
    }

    /// True when every reading of the last `adapterDischargeWindow` was on the adapter *and*
    /// discharging, and the readings actually cover that whole window.
    private static func sustainedDischargeOnAdapter(_ live: [Metric: [ChartPoint]]) -> Bool {
        guard let adapter = live[.onAC], let power = live[.batteryPower], let now = power.last?.date else { return false }
        let start = now.addingTimeInterval(-HealthRules.adapterDischargeWindow)
        let window = { (points: [ChartPoint]) in points.filter { $0.date >= start } }
        let adapterWindow = window(adapter), powerWindow = window(power)
        guard let first = powerWindow.first?.date, first.timeIntervalSince(start) < 15,
              let firstAdapter = adapterWindow.first?.date, firstAdapter.timeIntervalSince(start) < 15 else { return false }
        return adapterWindow.allSatisfy { $0.value >= 0.5 }
            && powerWindow.allSatisfy { $0.value < HealthRules.adapterDischargeWatts }
    }

    /// True when `points` stayed above `threshold` for most of the last `memoryWindow`.
    private static func sustained(_ points: [ChartPoint]?, above threshold: Double) -> Bool {
        guard let points, let now = points.last?.date else { return false }
        let window = points.filter { $0.date >= now.addingTimeInterval(-HealthRules.memoryWindow) }
        guard window.count >= 3 else { return false }
        return Double(window.filter { $0.value > threshold }.count) / Double(window.count) >= HealthRules.memoryShare
    }

    private static func loadState(_ value: Double) -> HealthState {
        if value > HealthRules.loadCritical { return .critical }
        return value >= HealthRules.loadWarning ? .warning : .normal
    }

    private static func recentAverage(_ points: [ChartPoint]?) -> Double? {
        guard let last = points?.last?.date else { return nil }
        let recent = points!.filter { last.timeIntervalSince($0.date) <= HealthRules.loadWindow }.map(\.value)
        return recent.average
    }
}

extension BatteryInfo {
    /// Hours left at the current whole-system draw.
    var runtimeHours: Double? {
        guard let power = systemPower, power > 0.5, voltage > 0 else { return nil }
        return Double(currentCapacity) / 1000 * voltage / power
    }
}

extension MenuBarDisplay {
    var healthMetric: HealthMetric? {
        switch self {
        case .iconOnly: nil
        case .cpu: .cpu
        case .gpu: .gpu
        case .memory: .memory
        case .temperature, .fan: .thermal
        case .battery: .battery
        case .power: .power
        }
    }
}

@MainActor
extension SystemMonitor {
    func health(_ metric: HealthMetric) -> HealthState {
        healthStates[metric] ?? latest.health(metric, live: live)
    }
}
