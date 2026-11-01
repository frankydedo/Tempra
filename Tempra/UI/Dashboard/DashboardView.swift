import SwiftUI

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, cpu, gpu, memory, thermals, battery, io, processes, forecasts

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .memory: "Memory"
        case .thermals: "Thermals"
        case .battery: "Battery & Power"
        case .io: "Disk & Network"
        case .processes: "Processes"
        case .forecasts: "Forecasts"
        }
    }

    var icon: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cpu: "cpu"
        case .gpu: "cube"
        case .memory: "memorychip"
        case .thermals: "thermometer.medium"
        case .battery: "battery.75percent"
        case .io: "externaldrive"
        case .processes: "list.bullet.rectangle"
        case .forecasts: "sparkles"
        }
    }
}

/// The full dashboard window.
struct DashboardView: View {
    @SceneStorage("section") private var section: DashboardSection = .overview
    @AppStorage("dashboardRange") private var range: TimeRange = .h1

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { section }, set: { section = $0 ?? .overview })) {
                Section("Monitor") {
                    ForEach([DashboardSection.overview, .cpu, .gpu, .memory, .thermals, .battery, .io, .processes]) { s in
                        Label(s.title, systemImage: s.icon).tag(s)
                    }
                }
                Section("Predict") {
                    Label(DashboardSection.forecasts.title, systemImage: DashboardSection.forecasts.icon)
                        .tag(DashboardSection.forecasts)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                Group {
                    switch section {
                    case .overview: OverviewSection(range: range)
                    case .cpu: CPUSection(range: range)
                    case .gpu: GPUSection(range: range)
                    case .memory: MemorySection(range: range)
                    case .thermals: ThermalSection(range: range)
                    case .battery: BatterySection(range: range)
                    case .io: IOSection(range: range)
                    case .processes: ProcessesSection()
                    case .forecasts: ForecastsSection()
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(section.title)
            .toolbar {
                if section != .processes && section != .forecasts {
                    ToolbarItem(placement: .primaryAction) {
                        Picker("Range", selection: $range) {
                            ForEach(TimeRange.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .help("History range")
                    }
                }
            }
        }
    }
}

// MARK: - Overview

struct OverviewSection: View {
    let range: TimeRange
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                StatTile(title: "CPU", systemImage: "cpu", value: Metric.cpu.format(s.cpuTotal),
                         detail: String(format: "Load %.2f · %.2f · %.2f", s.loadAverage.0, s.loadAverage.1, s.loadAverage.2),
                         state: monitor.health(.cpu))
                StatTile(title: "GPU", systemImage: "cube", value: s.gpu.map(Metric.gpu.format) ?? "—",
                         detail: "\(Format.bytes(s.gpuMemoryInUse)) GPU memory", state: monitor.health(.gpu))
                StatTile(title: "Memory pressure", systemImage: "memorychip", value: Metric.memPressure.format(s.memPressure),
                         detail: "\(Format.bytes(s.memUsed)) used · swap \(Format.bytes(s.swapUsed))",
                         state: monitor.health(.memory))
                StatTile(title: "SoC temperature", systemImage: "thermometer.medium", value: s.socTemp.map(Metric.socTemp.format) ?? "—",
                         detail: "Thermal state: \(s.thermalStateText)", state: monitor.health(.thermal))
                StatTile(title: "Battery", systemImage: "battery.75percent",
                         value: s.battery.map { Metric.batteryPercent.format($0.percent) } ?? "—",
                         detail: forecaster.batteryForecastText ?? s.batteryStateText,
                         state: monitor.health(.battery))
                StatTile(title: "Power", systemImage: "bolt.fill", value: s.battery?.systemPower.map(Metric.systemPower.format) ?? "—",
                         detail: "Whole system", state: monitor.health(.power))
                StatTile(title: "Network", systemImage: "network", value: "↓ " + Metric.netIn.format(s.netIn),
                         detail: "↑ " + Metric.netOut.format(s.netOut))
                StatTile(title: "Startup disk", systemImage: "internaldrive", value: Format.bytes(Double(s.diskFree)),
                         detail: "available of \(Format.bytes(Double(s.diskTotal)))", state: monitor.health(.disk))
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                ForEach([Metric.cpu, .gpu, .memPressure, .socTemp, .systemPower, .batteryPercent], id: \.self) { metric in
                    Card(title: metric.title) {
                        HistoryChart(metric: metric, range: range, forecast: forecaster.forecast(for: metric), height: 140)
                            // Same height for every card, whether or not the chart has a legend below it.
                            .frame(height: 162, alignment: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Forecasts

struct ForecastsSection: View {
    private let forecaster = ForecastService.shared
    @AppStorage(SettingsKey.forecastModel) private var model = ForecastModel.small.rawValue
    @Environment(\.openSettings) private var openSettings
    @State private var healthHistory: [BatteryHealthPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Timestral", systemImage: "sparkles") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zero-shot probabilistic forecasts from Mistral's Timestral, running locally on this Mac. Bands show the 10th–90th percentile range.")
                        .font(.callout).foregroundStyle(.secondary)
                    InfoRow(label: "Status", value: forecaster.status.label)
                    InfoRow(label: "Model", value: ForecastModel(rawValue: model)?.title ?? model)
                    if let last = forecaster.lastRun {
                        InfoRow(label: "Last run", value: last.formatted(.relative(presentation: .named)))
                    }
                    if forecaster.status == .notInstalled || forecaster.status == .disabled {
                        Button("Set Up Forecasting…") { openSettings() }
                    }
                }
            }

            if let battery = forecaster.currentBatteryForecast {
                ForecastCard(metric: .batteryPercent, forecast: battery, headline: battery.batteryText)
            }
            ForEach([(Metric.cpu, ForecastKey.cpu), (.gpu, ForecastKey.gpu), (.memPressure, ForecastKey.memoryPressure),
                     (.socTemp, ForecastKey.temperature), (.systemPower, ForecastKey.power)], id: \.1) { metric, key in
                if let f = forecaster.forecasts[key] {
                    ForecastCard(metric: metric, forecast: f,
                                 headline: "Next hour: avg \(metric.format(f.median.average ?? 0)), range \(metric.format(f.low.min() ?? 0))–\(metric.format(f.high.max() ?? 0))")
                }
            }

            Card(title: "Accuracy · last 7 days", systemImage: "scope") {
                AccuracyTable(accuracy: forecaster.accuracy)
            }

            Card(title: "Battery Health", systemImage: "heart.text.square") {
                BatteryHealthChart(history: healthHistory, forecast: forecaster.forecasts[ForecastKey.health])
            }

            if forecaster.forecasts.isEmpty, forecaster.status == .running || forecaster.status == .starting {
                Text("Forecasts appear once Tempra has collected enough history (about an hour for CPU, memory and temperature, two hours for battery).")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .task {
            healthHistory = await SystemMonitor.shared.store.batteryHealthHistory()
        }
    }
}

/// Compares past forecasts with what really happened.
struct AccuracyTable: View {
    let accuracy: [String: ForecastAccuracy]

    private let rows: [(key: String, metric: Metric)] = [
        (ForecastKey.battery, .batteryPercent), (ForecastKey.cpu, .cpu), (ForecastKey.gpu, .gpu),
        (ForecastKey.memoryPressure, .memPressure), (ForecastKey.temperature, .socTemp), (ForecastKey.power, .systemPower),
    ]

    var body: some View {
        if accuracy.isEmpty {
            Text("Tempra checks every forecast against what actually happened once its horizon has passed. Results appear after the first hour (12 hours for battery).")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Forecast")
                    Text("Typical error")
                    Text("vs. “no change”")
                    Text("Inside band")
                    Text("Checked")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(rows, id: \.key) { row in
                    if let a = accuracy[row.key] {
                        GridRow {
                            Text(row.metric.title)
                            Text("±" + row.metric.format(a.mae)).monospacedDigit()
                            skillText(a.skill).monospacedDigit()
                            Text(String(format: "%.0f%%", a.coverage * 100)).monospacedDigit()
                                .foregroundStyle(abs(a.coverage - a.targetCoverage) > 0.2 ? .orange : .primary)
                            Text("\(a.forecasts)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                    }
                }
            }
            Text("Typical error is the mean absolute difference between forecast and reality. “vs. no change” compares it with simply assuming the current value stays put: positive means Timestral did better. Inside band should be close to 80%, the width of the 10–90% band.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func skillText(_ skill: Double?) -> Text {
        guard let skill else { return Text("—").foregroundStyle(.secondary) }
        let text = Text(String(format: "%+.0f%%", skill * 100))
        return skill < 0 ? text.foregroundStyle(.orange) : text
    }
}

struct ForecastCard: View {
    let metric: Metric
    let forecast: Forecast
    var headline: String?

    private var accuracy: ForecastAccuracy? { ForecastService.shared.accuracy[forecast.metric] }

    var body: some View {
        Card(title: metric.title, systemImage: "chart.line.uptrend.xyaxis") {
            if let headline { Text(headline).font(.callout) }
            HistoryChart(metric: metric, range: forecast.step >= 300 ? .h24 : .h6, forecast: forecast, height: 160)
            Text("Generated \(forecast.generatedDate.formatted(.relative(presentation: .named))) from \(forecast.contextPoints) points"
                 + (accuracy.map { " · typical error ±\(metric.format($0.mae)) over the last 7 days" } ?? ""))
                .font(.caption2).foregroundStyle(.secondary)
            if let covariates = forecast.covariates, !covariates.isEmpty {
                Text("Conditioned on: " + covariates.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
