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
    /// On the adapter: battery current (A) below which the battery is helping the adapter.
    static let adapterDischargeAmps = -0.3

    static let diskWarningBytes: Int64 = 20_000_000_000
    static let diskWarningFraction = 0.10
    static let diskCriticalBytes: Int64 = 5_000_000_000
    static let diskCriticalFraction = 0.03

    static let healthWarning = 0.80
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
            switch memPressureLevel {
            case .normal: return .normal
            case .warning: return .warning
            case .critical: return .critical
            }
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
                if b.amperage < HealthRules.adapterDischargeAmps { return .critical }
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
        case .temperature: .thermal
        case .battery: .battery
        case .power: .power
        }
    }
}

@MainActor
extension SystemMonitor {
    func health(_ metric: HealthMetric) -> HealthState {
        latest.health(metric, live: live)
    }
}
