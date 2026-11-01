import Charts
import SwiftUI

// MARK: - CPU

struct CPUSection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 32) {
                BigStat(label: "Total", value: Metric.cpu.format(s.cpuTotal), color: Metric.cpu.color)
                BigStat(label: "User", value: Metric.cpu.format(s.cpuUser))
                BigStat(label: "System", value: Metric.cpu.format(s.cpuSystem))
                BigStat(label: "Load average (1/5/15 min)",
                        value: String(format: "%.2f  %.2f  %.2f", s.loadAverage.0, s.loadAverage.1, s.loadAverage.2))
            }

            Card(title: "History", systemImage: "chart.xyaxis.line") {
                HistoryChart(metric: .cpu, range: range, forecast: forecaster.forecast(for: .cpu), height: 220)
            }

            Card(title: "Cores", systemImage: "square.grid.3x3") {
                CoreBars(cores: s.cpuCores, efficiencyCount: s.efficiencyCoreCount)
            }
        }
    }
}

private struct CoreBars: View {
    let cores: [Double]
    let efficiencyCount: Int

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, value in
                let isEfficiency = index < efficiencyCount
                VStack(spacing: 4) {
                    Text(Metric.cpu.format(value)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    GeometryReader { geo in
                        VStack {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(isEfficiency ? Color.teal : Color.blue)
                                .frame(height: max(2, geo.size.height * value))
                        }
                    }
                    .frame(height: 90)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 3))
                    Text(isEfficiency ? "E\(index + 1)" : "P\(index - efficiencyCount + 1)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                .animation(.easeOut(duration: 0.4), value: value)
            }
        }
        HStack(spacing: 14) {
            Label("Performance", systemImage: "circle.fill").foregroundStyle(.blue)
            Label("Efficiency", systemImage: "circle.fill").foregroundStyle(.teal)
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}

// MARK: - Memory

struct MemorySection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 32) {
                BigStat(label: "Pressure (\(s.memPressureLevel.label))", value: Metric.memPressure.format(s.memPressure),
                        color: pressureColor(s.memPressureLevel))
                BigStat(label: "Used of \(Format.bytes(s.memTotal))", value: Format.bytes(s.memUsed))
                BigStat(label: "Swap used", value: Format.bytes(s.swapUsed))
            }

            Card(title: "Breakdown", systemImage: "chart.bar.fill") {
                SegmentBar(segments: [
                    .init(label: "App \(Format.bytes(s.memApp))", value: Double(s.memApp), color: .purple),
                    .init(label: "Wired \(Format.bytes(s.memWired))", value: Double(s.memWired), color: .orange),
                    .init(label: "Compressed \(Format.bytes(s.memCompressed))", value: Double(s.memCompressed), color: .pink),
                    .init(label: "Cached \(Format.bytes(s.memCached))", value: Double(s.memCached), color: .gray.opacity(0.6)),
                ], total: Double(s.memTotal))
            }

            Card(title: "Memory Pressure", systemImage: "gauge.with.dots.needle.67percent") {
                HistoryChart(metric: .memPressure, range: range, forecast: forecaster.forecast(for: .memPressure))
            }
            Card(title: "Memory Used", systemImage: "memorychip") {
                HistoryChart(metric: .memUsed, range: range, height: 140)
            }
            Card(title: "Swap", systemImage: "arrow.left.arrow.right") {
                HistoryChart(metric: .swap, range: range, height: 120)
            }
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }
}

// MARK: - Thermals

struct ThermalSection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 32) {
                BigStat(label: "SoC average", value: s.socTemp.map(Metric.socTemp.format) ?? "—", color: .orange)
                BigStat(label: "SoC hotspot", value: s.socTempMax.map(Metric.socTemp.format) ?? "—")
                BigStat(label: "Battery", value: s.batteryTemp.map(Metric.socTemp.format) ?? "—")
                BigStat(label: "SSD", value: s.ssdTemp.map(Metric.socTemp.format) ?? "—")
                BigStat(label: "Thermal state", value: s.thermalStateText)
            }
            Card(title: "SoC Temperature", systemImage: "thermometer.medium") {
                HistoryChart(metric: .socTemp, range: range, forecast: forecaster.forecast(for: .socTemp), height: 220)
            }
            HStack(spacing: 16) {
                Card(title: "SoC Hotspot") { HistoryChart(metric: .socTempMax, range: range, height: 130) }
                Card(title: "Battery Temperature") { HistoryChart(metric: .batteryTemp, range: range, height: 130) }
            }
        }
    }
}

// MARK: - Battery & Power

struct BatterySection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared
    @State private var healthHistory: [BatteryHealthPoint] = []

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            if let b = s.battery {
                HStack(spacing: 32) {
                    BigStat(label: s.batteryStateText, value: Metric.batteryPercent.format(b.percent), color: .green)
                    BigStat(label: "System power", value: b.systemPower.map(Metric.systemPower.format) ?? "—", color: .yellow)
                    BigStat(label: b.batteryPower >= 0 ? "Into battery" : "Out of battery",
                            value: Metric.batteryPower.format(abs(b.batteryPower)))
                    BigStat(label: "Maximum capacity", value: String(format: "%.0f%%", b.health * 100))
                }

                HStack(alignment: .top, spacing: 16) {
                    Card(title: "Time Remaining", systemImage: "clock") {
                        InfoRow(label: "macOS estimate", value: macOSEstimate(b))
                        InfoRow(label: "Timestral forecast", value: forecaster.forecasts[ForecastKey.battery]?.batteryText ?? "—")
                    }
                    Card(title: "Details", systemImage: "info.circle") {
                        InfoRow(label: "Cycle count", value: "\(b.cycleCount)")
                        InfoRow(label: "Capacity (now / max / design)", value: "\(b.currentCapacity) / \(b.nominalCapacity) / \(b.designCapacity) mAh")
                        InfoRow(label: "Voltage", value: String(format: "%.2f V", b.voltage))
                        InfoRow(label: "Current", value: String(format: "%.2f A", b.amperage))
                        if let watts = b.adapterWatts, b.onAC {
                            InfoRow(label: "Adapter", value: "\(watts) W" + (b.adapterName.map { " · \($0)" } ?? ""))
                        }
                    }
                }

                Card(title: "Battery Level", systemImage: "battery.75percent") {
                    HistoryChart(metric: .batteryPercent, range: range, forecast: forecaster.forecast(for: .batteryPercent), height: 200)
                }
                Card(title: "System Power", systemImage: "bolt.fill") {
                    HistoryChart(metric: .systemPower, range: range, forecast: forecaster.forecast(for: .systemPower), height: 160)
                }
                Card(title: "Battery Health", systemImage: "heart.text.square") {
                    BatteryHealthChart(history: healthHistory, forecast: forecaster.forecasts[ForecastKey.health])
                }
            } else {
                ContentUnavailableView("No Battery", systemImage: "battery.0percent",
                                       description: Text("This Mac has no internal battery."))
            }
        }
        .task {
            healthHistory = await monitor.store.batteryHealthHistory()
        }
    }

    private func macOSEstimate(_ b: BatteryInfo) -> String {
        if b.isCharging { return b.minutesToFull.map { "Full in \(Format.duration(minutes: Double($0)))" } ?? "Calculating…" }
        if b.onAC { return "On power adapter" }
        return b.minutesToEmpty.map { "\(Format.duration(minutes: Double($0))) left" } ?? "Calculating…"
    }
}

struct BatteryHealthChart: View {
    let history: [BatteryHealthPoint]
    let forecast: Forecast?

    var body: some View {
        if history.count < 2 {
            Text("Tempra records battery health once a day. A trend appears after a couple of days, and a Timestral projection after two weeks.")
                .font(.callout).foregroundStyle(.secondary)
            if let last = history.last {
                InfoRow(label: "Today", value: String(format: "%.1f%% · %d cycles", last.health * 100, last.cycleCount))
            }
        } else {
            if let summary = forecast?.summary, let value = summary.value {
                Text("Projected in 6 months: \(String(format: "%.1f%%", value * 100))"
                     + (summary.daysTo80.map { " · reaches 80% in ~\($0) days" } ?? ""))
                    .font(.callout)
            }
            Chart {
                ForEach(history) { p in
                    LineMark(x: .value("Day", p.date), y: .value("Health", p.health * 100))
                        .foregroundStyle(.green)
                }
                if let forecast {
                    ForEach(forecast.points()) { p in
                        AreaMark(x: .value("Day", p.date), yStart: .value("Low", p.low * 100), yEnd: .value("High", p.high * 100))
                            .foregroundStyle(.green.opacity(0.15))
                        LineMark(x: .value("Day", p.date), y: .value("Forecast", p.median * 100), series: .value("S", "f"))
                            .foregroundStyle(.green)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
                RuleMark(y: .value("Service threshold", 80))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYAxis {
                AxisMarks(position: .leading) { v in
                    AxisGridLine()
                    AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))%") } }
                }
            }
            .frame(height: 160)
        }
    }
}

// MARK: - Disk & Network

struct IOSection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 32) {
                BigStat(label: "Download", value: Metric.netIn.format(s.netIn), color: .teal)
                BigStat(label: "Upload", value: Metric.netOut.format(s.netOut), color: .pink)
                BigStat(label: "Disk read", value: Metric.diskRead.format(s.diskRead))
                BigStat(label: "Disk write", value: Metric.diskWrite.format(s.diskWrite))
            }
            Card(title: "Startup Disk", systemImage: "internaldrive") {
                let used = Double(s.diskTotal - s.diskFree)
                SegmentBar(segments: [
                    .init(label: "Used \(Format.bytes(used))", value: used, color: .blue),
                    .init(label: "Available \(Format.bytes(Double(s.diskFree)))", value: Double(s.diskFree), color: .gray.opacity(0.3)),
                ], total: Double(s.diskTotal))
            }
            HStack(spacing: 16) {
                Card(title: "Download") { HistoryChart(metric: .netIn, range: range, height: 140) }
                Card(title: "Upload") { HistoryChart(metric: .netOut, range: range, height: 140) }
            }
            HStack(spacing: 16) {
                Card(title: "Disk Read") { HistoryChart(metric: .diskRead, range: range, height: 140) }
                Card(title: "Disk Write") { HistoryChart(metric: .diskWrite, range: range, height: 140) }
            }
        }
    }
}

// MARK: - Processes

struct ProcessesSection: View {
    @State private var sortOrder = [KeyPathComparator(\ProcessSample.cpu, order: .reverse)]
    @State private var filter = ""
    private let monitor = SystemMonitor.shared

    var body: some View {
        let rows = monitor.processes
            .filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
            .sorted(using: sortOrder)
            .prefix(60)
        VStack(alignment: .leading, spacing: 10) {
            TextField("Filter processes", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            Table(Array(rows), sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name)
                TableColumn("CPU", value: \.cpu) { p in
                    Text(String(format: "%.1f%%", p.cpu)).monospacedDigit()
                }
                .width(80)
                TableColumn("Memory", value: \.memory) { p in
                    Text(Format.bytes(p.memory)).monospacedDigit()
                }
                .width(100)
                TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).monospacedDigit() }
                    .width(60)
                TableColumn("User", value: \.user)
                    .width(120)
            }
            .frame(minHeight: 480)
            Text("CPU is a percentage of one core (like Activity Monitor). Updated every sample while this view is open.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { monitor.processesVisible = true }
        .onDisappear { monitor.processesVisible = false }
    }
}
