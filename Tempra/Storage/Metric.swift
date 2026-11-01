import SwiftUI

/// Every metric that is persisted to history. The raw value is the SQLite column name
/// (also used by the Python forecaster, so keep them in sync with `forecaster/worker.py`).
enum Metric: String, CaseIterable, Identifiable, Sendable {
    case cpu
    case gpu
    case memUsed = "mem_used"
    case memPressure = "mem_pressure"
    case swap
    case swapOut = "swap_out"
    case socTemp = "soc_temp"
    case socTempMax = "soc_temp_max"
    case batteryTemp = "batt_temp"
    case fanRPM = "fan_rpm"
    case batteryPercent = "batt_pct"
    case batteryPower = "batt_power"
    case systemPower = "sys_power"
    case onAC = "on_ac"
    case charging
    case adapterWatts = "adapter_w"
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
        case .swapOut: "Swapping Out"
        case .socTemp: "SoC Temperature"
        case .socTempMax: "SoC Hotspot"
        case .batteryTemp: "Battery Temperature"
        case .fanRPM: "Fan Speed"
        case .batteryPercent: "Battery Level"
        case .batteryPower: "Battery Power"
        case .systemPower: "System Power"
        case .onAC: "On Power Adapter"
        case .charging: "Charging"
        case .adapterWatts: "Adapter Rating"
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
        case .fanRPM: .rpm
        case .batteryPercent: .percent
        case .batteryPower, .systemPower, .adapterWatts: .watts
        case .onAC, .charging: .fraction
        case .netIn, .netOut, .diskRead, .diskWrite, .swapOut: .bytesPerSecond
        }
    }

    var color: Color {
        switch self {
        case .cpu: .blue
        case .gpu: .indigo
        case .memUsed, .memPressure, .swap, .swapOut: .purple
        case .socTemp, .socTempMax, .batteryTemp: .orange
        case .fanRPM: .cyan
        case .batteryPercent: .green
        case .batteryPower, .systemPower: .yellow
        case .onAC, .charging, .adapterWatts: .gray
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
        case .swapOut: s.swapOutRate
        case .socTemp: s.socTemp
        case .socTempMax: s.socTempMax
        case .batteryTemp: s.batteryTemp
        case .fanRPM: s.fanRPM
        case .batteryPercent: s.battery?.percent
        case .batteryPower: s.battery?.batteryPower
        case .systemPower: s.battery?.systemPower
        case .onAC: s.battery.map { $0.onAC ? 1 : 0 }
        case .charging: s.battery.map { $0.isCharging ? 1 : 0 }
        case .adapterWatts: s.battery.flatMap { $0.onAC ? $0.adapterWatts.map(Double.init) : nil }
        case .netIn: s.netIn
        case .netOut: s.netOut
        case .diskRead: s.diskRead
        case .diskWrite: s.diskWrite
        }
    }

    func format(_ value: Double) -> String { unit.format(value) }
}

enum MetricUnit: Sendable {
    case fraction, percent, celsius, watts, bytesPerSecond, rpm

    /// Smallest y-axis span for auto-scaled charts.
    var minimumSpan: Double {
        switch self {
        case .fraction: 0.05
        case .percent: 5
        case .celsius: 5
        case .watts: 2
        case .bytesPerSecond: 10_000
        case .rpm: 1000
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .fraction: String(format: "%.0f%%", v * 100)
        case .percent: String(format: "%.0f%%", v)
        case .celsius: String(format: "%.0f°C", v)
        case .watts: String(format: abs(v) < 10 ? "%.1f W" : "%.0f W", v)
        case .bytesPerSecond: Format.bytes(v) + "/s"
        case .rpm: String(format: "%.0f rpm", max(v, 0))
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
