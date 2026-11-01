import SwiftUI

/// Every metric that is persisted to history. The raw value is the SQLite column name
/// (also used by the Python forecaster, so keep them in sync with `forecaster/worker.py`).
enum Metric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case gpu
    case memUsed = "mem_used"
    case memPressure = "mem_pressure"
    case swap
    case socTemp = "soc_temp"
    case socTempMax = "soc_temp_max"
    case batteryTemp = "batt_temp"
    case batteryPercent = "batt_pct"
    case batteryPower = "batt_power"
    case systemPower = "sys_power"
    case onAC = "on_ac"
    case charging
    case netIn = "net_in"
    case netOut = "net_out"
    case diskRead = "disk_read"
    case diskWrite = "disk_write"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memUsed: "Memory Used"
        case .memPressure: "Memory Pressure"
        case .swap: "Swap"
        case .socTemp: "SoC Temperature"
        case .socTempMax: "SoC Hotspot"
        case .batteryTemp: "Battery Temperature"
        case .batteryPercent: "Battery Level"
        case .batteryPower: "Battery Power"
        case .systemPower: "System Power"
        case .onAC: "On Power Adapter"
        case .charging: "Charging"
        case .netIn: "Download"
        case .netOut: "Upload"
        case .diskRead: "Disk Read"
        case .diskWrite: "Disk Write"
        }
    }

    var unit: MetricUnit {
        switch self {
        case .cpu, .gpu, .memUsed, .memPressure, .swap: .fraction
        case .socTemp, .socTempMax, .batteryTemp: .celsius
        case .batteryPercent: .percent
        case .batteryPower, .systemPower: .watts
        case .onAC, .charging: .fraction
        case .netIn, .netOut, .diskRead, .diskWrite: .bytesPerSecond
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .indigo
        case .memUsed, .memPressure, .swap: .purple
        case .socTemp, .socTempMax, .batteryTemp: .orange
        case .batteryPercent: .green
        case .batteryPower, .systemPower: .yellow
        case .onAC, .charging: .gray
        case .netIn, .diskRead: .teal
        case .netOut, .diskWrite: .pink
        }
    }

    /// Fixed y-axis range when it makes sense; nil lets the chart auto-scale.
    var yDomain: ClosedRange<Double>? {
        switch unit {
        case .fraction: 0...1
        case .percent: 0...100
        default: nil
        }
    }

    func value(from s: Snapshot) -> Double? {
        switch self {
        case .cpu: s.cpuTotal
        case .gpu: s.gpu
        case .memUsed: s.memUsedFraction
        case .memPressure: s.memPressure
        case .swap: s.swapTotal > 0 ? Double(s.swapUsed) / Double(s.swapTotal) : 0
        case .socTemp: s.socTemp
        case .socTempMax: s.socTempMax
        case .batteryTemp: s.batteryTemp
        case .batteryPercent: s.battery?.percent
        case .batteryPower: s.battery?.batteryPower
        case .systemPower: s.battery?.systemPower
        case .onAC: s.battery.map { $0.onAC ? 1 : 0 }
        case .charging: s.battery.map { $0.isCharging ? 1 : 0 }
        case .netIn: s.netIn
        case .netOut: s.netOut
        case .diskRead: s.diskRead
        case .diskWrite: s.diskWrite
        }
    }

    func format(_ value: Double) -> String { unit.format(value) }
}

enum MetricUnit: Sendable {
    case fraction, percent, celsius, watts, bytesPerSecond

    func format(_ v: Double) -> String {
        switch self {
        case .fraction: String(format: "%.0f%%", v * 100)
        case .percent: String(format: "%.0f%%", v)
        case .celsius: String(format: "%.0f°C", v)
        case .watts: String(format: abs(v) < 10 ? "%.1f W" : "%.0f W", v)
        case .bytesPerSecond: Format.bytes(v) + "/s"
        }
    }
}

enum Format {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .memory
        f.allowsNonnumericFormatting = false
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    static func bytes(_ value: Double) -> String {
        byteFormatter.string(fromByteCount: Int64(max(value, 0)))
    }

    static func bytes(_ value: UInt64) -> String { bytes(Double(value)) }

    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 60 { return "\(total)m" }
        let h = total / 60, m = total % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func duration(seconds: Double) -> String { duration(minutes: seconds / 60) }
}
