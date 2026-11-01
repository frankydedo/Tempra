import SwiftUI

/// The compact panel shown when clicking the menu bar item.
struct SummaryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let monitor = SystemMonitor.shared
    private let forecaster = ForecastService.shared

    var body: some View {
        let s = monitor.latest
        VStack(alignment: .leading, spacing: 12) {
            header

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                StatTile(title: "CPU", systemImage: "cpu", value: Metric.cpu.format(s.cpuTotal),
                         detail: String(format: "Load %.2f", s.loadAverage.0),
                         color: Metric.cpu.color, points: monitor.live[.cpu] ?? [], domain: 0...1)
                StatTile(title: "GPU", systemImage: "cube", value: s.gpu.map(Metric.gpu.format) ?? "—",
                         detail: "Memory \(Format.bytes(s.gpuMemoryInUse))",
                         color: Metric.gpu.color, points: monitor.live[.gpu] ?? [], domain: 0...1)
                StatTile(title: "Memory", systemImage: "memorychip", value: Metric.memPressure.format(s.memPressure),
                         detail: "\(Format.bytes(s.memUsed)) of \(Format.bytes(s.memTotal)) · \(s.memPressureLevel.label)",
                         color: Metric.memPressure.color, points: monitor.live[.memPressure] ?? [], domain: 0...1)
                StatTile(title: "Temperature", systemImage: "thermometer.medium",
                         value: s.socTemp.map(Metric.socTemp.format) ?? "—",
                         detail: s.socTempMax.map { "Hotspot \(Metric.socTemp.format($0)) · \(s.thermalStateText)" },
                         color: Metric.socTemp.color, points: monitor.live[.socTemp] ?? [])
                StatTile(title: "Battery", systemImage: s.battery.map(MenuBarDisplay.batterySymbol) ?? "battery.0percent", value: s.battery.map { Metric.batteryPercent.format($0.percent) } ?? "—",
                         detail: batteryDetail(s),
                         color: Metric.batteryPercent.color, points: monitor.live[.batteryPercent] ?? [])
                StatTile(title: "Power", systemImage: "bolt.fill", value: s.battery?.systemPower.map(Metric.systemPower.format) ?? "—",
                         detail: powerDetail(s),
                         color: Metric.systemPower.color, points: monitor.live[.systemPower] ?? [])
            }

            ioRow(s)

            forecastCard

            Button {
                openDashboard()
            } label: {
                Label("Open Dashboard", systemImage: "macwindow")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut("d")
        }
        .padding(14)
        .frame(width: 360)
        .animation(.default, value: s.date)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg")
                .font(.title3)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text("Tempra").font(.headline)
                Text(Host.current().localizedName ?? "This Mac").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            } label: { Image(systemName: "gearshape") }
                .buttonStyle(.borderless)
                .help("Settings")
            Button {
                NSApp.terminate(nil)
            } label: { Image(systemName: "power") }
                .buttonStyle(.borderless)
                .help("Quit Tempra")
        }
    }

    @ViewBuilder
    private var forecastCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Forecast", systemImage: "sparkles")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("Timestral").font(.caption2).foregroundStyle(.secondary)
            }
            switch forecaster.status {
            case .notInstalled, .failed, .disabled:
                HStack {
                    Text(forecaster.status == .notInstalled ? "Forecasting is not set up yet." : forecaster.status.label)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Set Up…") {
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                    .controlSize(.small)
                }
            default:
                if forecaster.forecasts.isEmpty {
                    Text(forecaster.status == .running ? "Collecting history — first forecasts after about an hour of data."
                                                       : forecaster.status.label)
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    forecastRows
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var forecastRows: some View {
        let f = forecaster.forecasts
        if let battery = f[ForecastKey.battery], let text = battery.batteryText, monitor.latest.battery != nil {
            ForecastRow(icon: "battery.75percent", text: text)
        }
        if let cpu = f[ForecastKey.cpu] {
            ForecastRow(icon: "cpu", text: "CPU next hour: avg \(Metric.cpu.format(cpu.median.average ?? 0)), peak \(Metric.cpu.format(cpu.high.max() ?? 0))")
        }
        if let temp = f[ForecastKey.temperature], let peak = temp.median.max() {
            ForecastRow(icon: "thermometer.medium", text: "Temperature next hour: up to \(Metric.socTemp.format(peak))")
        }
        if let power = f[ForecastKey.power], let avg = power.median.average {
            ForecastRow(icon: "bolt", text: "Power next hour: ~\(Metric.systemPower.format(avg)) avg")
        }
    }

    private func openDashboard() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: TempraApp.dashboardWindowID)
    }

    /// One compact line for network and disk, which matter less at a glance.
    private func ioRow(_ s: Snapshot) -> some View {
        HStack(spacing: 14) {
            Label("↓ \(Metric.netIn.format(s.netIn))  ↑ \(Metric.netOut.format(s.netOut))", systemImage: "network")
            Spacer()
            Label("\(Format.bytes(Double(s.diskFree))) free", systemImage: "internaldrive")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func batteryDetail(_ s: Snapshot) -> String {
        guard let b = s.battery else { return "No battery" }
        if b.isCharging, let m = b.minutesToFull { return "Charging · full in \(Format.duration(minutes: Double(m)))" }
        if !b.onAC, let m = b.minutesToEmpty { return "\(Format.duration(minutes: Double(m))) left (macOS)" }
        return s.batteryStateText
    }

    private func powerDetail(_ s: Snapshot) -> String {
        guard let b = s.battery else { return "" }
        let flow = b.batteryPower
        if abs(flow) < 0.1 { return "Battery idle" }
        return flow > 0 ? "Charging at \(Metric.batteryPower.format(flow))" : "Battery \(Metric.batteryPower.format(-flow)) out"
    }
}

private struct ForecastRow: View {
    let icon: String
    let text: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
    }
}
