import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ForecastSettings()
                .tabItem { Label("Forecasting", systemImage: "sparkles") }
            DataSettings()
                .tabItem { Label("Data", systemImage: "cylinder.split.1x2") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralSettings: View {
    @AppStorage(SettingsKey.menuBarDisplay) private var display = MenuBarDisplay.cpu.rawValue
    @AppStorage(SettingsKey.sampleInterval) private var interval = SettingsKey.defaultSampleInterval
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Picker("Show in menu bar", selection: $display) {
                ForEach(MenuBarDisplay.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Sample every", selection: $interval) {
                ForEach([1.0, 2, 3, 5, 10], id: \.self) { Text("\(Int($0)) s").tag($0) }
            }
            .onChange(of: interval) { SystemMonitor.shared.restart() }

            Toggle("Open Tempra at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let loginError {
                Text(loginError).font(.caption).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ForecastSettings: View {
    @AppStorage(SettingsKey.forecastEnabled) private var enabled = true
    @AppStorage(SettingsKey.forecastModel) private var model = ForecastModel.small.rawValue
    private let service = ForecastService.shared

    var body: some View {
        Form {
            Section {
                Toggle("Forecast with Timestral", isOn: $enabled)
                    .onChange(of: enabled) { service.restartWorker() }
                Picker("Model", selection: $model) {
                    ForEach(ForecastModel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .onChange(of: model) { service.restartWorker() }
                LabeledContent("Status", value: service.status.label)
                if let last = service.lastRun {
                    LabeledContent("Last forecast", value: last.formatted(date: .omitted, time: .shortened))
                }
            } footer: {
                Text("Timestral runs locally in a background Python process and refreshes forecasts every 5 minutes. The model is downloaded from Hugging Face on first use.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Engine") {
                HStack {
                    Text(service.isInstalled ? "Python environment installed" : "Needs Python, PyTorch and Timestral (~400 MB, requires uv).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(service.isInstalled ? "Reinstall" : "Install") { service.install() }
                        .disabled(service.status == .installing)
                }
                if !service.installLog.isEmpty {
                    ScrollView {
                        Text(service.installLog)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                    .defaultScrollAnchor(.bottom)
                }
                HStack {
                    Button("Show Engine Folder") { NSWorkspace.shared.open(ForecastService.directory) }
                    Button("Show Log") { NSWorkspace.shared.open(ForecastService.logURL) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DataSettings: View {
    @State private var size: Int64 = 0
    @State private var confirmDelete = false
    private let store = SystemMonitor.shared.store

    var body: some View {
        Form {
            Section {
                LabeledContent("Database size", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                LabeledContent("Every sample", value: "kept 24 hours")
                LabeledContent("1-minute averages", value: "kept 30 days")
                LabeledContent("1-hour averages", value: "kept forever")
            }
            Section {
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([HistoryStore.databaseURL]) }
                    Spacer()
                    Button("Delete History…", role: .destructive) { confirmDelete = true }
                }
            }
        }
        .formStyle(.grouped)
        .task { size = await store.diskSize() }
        .confirmationDialog("Delete all recorded history and forecasts?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                Task {
                    await store.deleteAll()
                    size = await store.diskSize()
                }
            }
        }
    }
}
