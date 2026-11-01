import Foundation
import Observation

/// A probabilistic forecast produced by Timestral (see `forecaster/worker.py`).
struct Forecast: Decodable, Sendable {
    struct ETA: Decodable, Sendable {
        let seconds: Double?
        let low: Double?
        let high: Double?
    }

    struct Summary: Decodable, Sendable {
        let kind: String
        let seconds: Double?
        let low: Double?
        let high: Double?
        let horizon: Double?
        let value: Double?
        let daysTo80: Int?
        let percent: Double?
        /// Battery life if unplugged now (sent while on the adapter).
        let ifUnplugged: ETA?

        var eta: ETA { ETA(seconds: seconds, low: low, high: high) }
    }

    let metric: String
    let generatedAt: Double
    let start: Double
    let step: Double
    let median: [Double]
    let low: [Double]
    let high: [Double]
    let lowLevel: Double
    let highLevel: Double
    let contextPoints: Int
    let model: String?
    let summary: Summary?
    /// What the forecast was conditioned on, e.g. other metrics forecast jointly.
    let covariates: [String]?
    /// How much the worker widened (>1) or narrowed (<1) the band to match past accuracy.
    let bandScale: Double?

    var generatedDate: Date { Date(timeIntervalSince1970: generatedAt) }
    var endDate: Date { Date(timeIntervalSince1970: start + step * Double(median.count - 1)) }

    struct Point: Identifiable {
        var id: Date { date }
        let date: Date
        let median: Double
        let low: Double
        let high: Double
    }

    /// Forecast points, optionally limited to the first `horizon` seconds.
    func points(horizon: TimeInterval? = nil) -> [Point] {
        let count = horizon.map { min(median.count, Int($0 / step)) } ?? median.count
        return (0..<count).map { i in
            Point(date: Date(timeIntervalSince1970: start + step * Double(i)), median: median[i], low: low[i], high: high[i])
        }
    }

    /// Value of the median at roughly `seconds` from the forecast start.
    func median(after seconds: TimeInterval) -> Double? {
        let i = Int(seconds / step) - 1
        return median.indices.contains(i) ? median[i] : median.last
    }
}

/// How past forecasts compared with what actually happened (last 7 days), computed by the worker.
struct ForecastAccuracy: Decodable, Sendable {
    let forecasts: Int
    /// Mean absolute error, in the metric's own unit.
    let mae: Double
    /// 1 − error / error of assuming nothing changes. Positive = better than that baseline.
    let skill: Double?
    /// Share of actual values inside the forecast band (ideally `targetCoverage`).
    let coverage: Double
    let targetCoverage: Double
    let since: Double
}

/// Keys used for forecasts in the database.
enum ForecastKey {
    static let battery = "batt_pct"
    static let cpu = "cpu"
    static let gpu = "gpu"
    static let memoryPressure = "mem_pressure"
    static let temperature = "soc_temp"
    static let fan = "fan_rpm"
    static let power = "sys_power"
    static let health = "health"

    static func forMetric(_ metric: Metric) -> String? {
        switch metric {
        case .batteryPercent: battery
        case .cpu: cpu
        case .gpu: gpu
        case .memPressure: memoryPressure
        case .socTemp: temperature
        case .fanRPM: fan
        case .systemPower: power
        default: nil
        }
    }
}

/// Installs, runs and reads the Python Timestral worker.
@MainActor
@Observable
final class ForecastService {
    static let shared = ForecastService()

    enum Status: Equatable {
        case disabled
        case notInstalled
        case installing
        case starting
        case running
        case failed(String)

        var label: String {
            switch self {
            case .disabled: "Disabled"
            case .notInstalled: "Not installed"
            case .installing: "Installing…"
            case .starting: "Loading model…"
            case .running: "Running"
            case .failed(let message): "Error: \(message)"
            }
        }
    }

    private(set) var status: Status = .notInstalled {
        didSet {
            guard status != oldValue else { return }
            if case .failed(let message) = status {
                Log.error(.forecast, "Forecaster failed: \(message)")
            } else {
                Log.info(.forecast, "Forecaster status: \(status.label)")
            }
        }
    }
    private(set) var forecasts: [String: Forecast] = [:]
    private(set) var accuracy: [String: ForecastAccuracy] = [:]
    private(set) var lastRun: Date?
    private(set) var installLog = ""

    private var worker: Process?
    private var installer: Process?
    private var pollTask: Task<Void, Never>?
    private let store: HistoryStore

    static var directory: URL { HistoryStore.directory.appendingPathComponent("forecaster", isDirectory: true) }
    static var python: URL { directory.appendingPathComponent(".venv/bin/python") }
    static var logURL: URL { Log.directory.appendingPathComponent("forecaster.log") }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.python.path) }

    private init() {
        store = SystemMonitor.shared.store
    }

    // MARK: Lifecycle

    func start() {
        copyBundledFiles()
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.reload()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        launchWorkerIfPossible()
    }

    func stop() {
        worker?.terminate()
        worker = nil
        installer?.terminate()
    }

    /// Asks the running worker to recompute now instead of at its next minute, then picks up the
    /// result. Used when the power source changes so the battery forecast follows right away.
    func requestRefresh(reason: String) {
        guard let worker, worker.isRunning else { return }
        kill(worker.processIdentifier, SIGUSR1)
        Log.info(.forecast, "Refresh requested: \(reason)")
        Task { [weak self] in
            for delay in [1.5, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                await self?.reload()
            }
        }
    }

    func restartWorker() {
        worker?.terminate()
        worker = nil
        launchWorkerIfPossible()
    }

    private func launchWorkerIfPossible() {
        guard UserDefaults.standard.bool(forKey: SettingsKey.forecastEnabled) else {
            status = .disabled
            return
        }
        guard isInstalled else {
            status = .notInstalled
            return
        }
        guard worker == nil else { return }
        #if DEBUG
        if UserDefaults.standard.string(forKey: "TempraSnapshotDir") != nil
            && !UserDefaults.standard.bool(forKey: "TempraSnapshotForecaster") {
            // Snapshot runs read the installed app's forecasts; a second worker would race it.
            status = .running
            return
        }
        #endif

        let model = UserDefaults.standard.string(forKey: SettingsKey.forecastModel) ?? ForecastModel.small.rawValue
        let process = Process()
        process.executableURL = Self.python
        process.currentDirectoryURL = Self.directory
        process.arguments = [
            Self.directory.appendingPathComponent("worker.py").path,
            "--db", HistoryStore.databaseURL.path,
            "--model", model,
            "--interval", "60",
            "--parent-pid", String(ProcessInfo.processInfo.processIdentifier),
        ]
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        FileManager.default.createFile(atPath: Self.logURL.path, contents: nil)
        if let log = try? FileHandle(forWritingTo: Self.logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                Log.notice(.forecast, "Forecaster process \(proc.processIdentifier) exited (code \(proc.terminationStatus))")
                guard let self, self.worker === proc else { return }
                self.worker = nil
                if proc.terminationReason != .exit || proc.terminationStatus != 0 {
                    let message = await self.store.meta("forecaster_error").flatMap { $0.isEmpty ? nil : $0 }
                    self.status = .failed(message ?? "worker exited (code \(proc.terminationStatus)), see forecaster.log")
                }
            }
        }
        do {
            try process.run()
            worker = process
            status = .starting
            Log.notice(.forecast, "Forecaster started (pid \(process.processIdentifier), \(model)); output in \(Self.logURL.path)")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Install

    /// Runs `setup.sh`, which creates a private venv with PyTorch and Timestral.
    func install() {
        guard installer == nil else { return }
        copyBundledFiles()
        Log.notice(.forecast, "Installing forecasting engine")
        status = .installing
        installLog = ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [Self.directory.appendingPathComponent("setup.sh").path, Self.directory.path]
        var env = ProcessInfo.processInfo.environment
        // GUI apps get a minimal PATH; add the usual Homebrew / user locations.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:\(NSHomeDirectory())/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.installLog += text }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                pipe.fileHandleForReading.readabilityHandler = nil
                self.installer = nil
                if proc.terminationStatus == 0 {
                    Log.notice(.forecast, "Forecasting engine installed")
                    self.status = .notInstalled
                    self.launchWorkerIfPossible()
                } else {
                    Log.error(.forecast, "Installation failed:\n" + self.installLog.split(separator: "\n").suffix(15).joined(separator: "\n"))
                    self.status = .failed("installation failed, see the log below")
                }
            }
        }
        do {
            try process.run()
            installer = process
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: Reading

    func reload() async {
        let raw = await store.forecasts()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var decoded: [String: Forecast] = [:]
        for (key, data) in raw {
            if let forecast = try? decoder.decode(Forecast.self, from: data) {
                decoded[key] = forecast
            }
        }
        if let old = forecasts[ForecastKey.battery]?.summary?.kind, let new = decoded[ForecastKey.battery],
           let kind = new.summary?.kind, kind != old {
            Log.notice(.forecast, "Battery forecast: \(old) → \(kind): \(new.batteryText ?? "—")")
        }
        forecasts = decoded
        if let json = await store.meta("forecast_accuracy"),
           let value = try? decoder.decode([String: ForecastAccuracy].self, from: Data(json.utf8)) {
            accuracy = value
        }

        if let value = await store.meta("forecaster_last_run"), let t = Double(value) {
            lastRun = Date(timeIntervalSince1970: t)
            if worker != nil, status == .starting { status = .running }
        }
        if worker != nil, let error = await store.meta("forecaster_error"), !error.isEmpty {
            status = .failed(error)
        } else if worker != nil, case .failed = status {
            status = .running
        }
    }

    func forecast(for metric: Metric) -> Forecast? {
        if metric == .batteryPercent { return currentBatteryForecast }
        return ForecastKey.forMetric(metric).flatMap { forecasts[$0] }
    }

    /// The battery forecast, or nil while it describes a power state the Mac has already left
    /// (e.g. "held at 80%" just after unplugging). A fresh one follows within seconds.
    var currentBatteryForecast: Forecast? {
        guard let forecast = forecasts[ForecastKey.battery] else { return nil }
        let monitor = SystemMonitor.shared
        if let change = monitor.lastAdapterChange, forecast.generatedDate < change { return nil }
        guard let b = monitor.latest.battery, let kind = forecast.summary?.kind else { return forecast }
        let expected = !b.onAC ? "time_to_empty" : (b.isCharging ? "time_to_full" : "held")
        return kind == expected ? forecast : nil
    }

    /// Text for the battery forecast; "Updating forecast…" while the current one is stale.
    var batteryForecastText: String? {
        guard forecasts[ForecastKey.battery] != nil else { return nil }
        return currentBatteryForecast.map { $0.batteryText ?? "—" } ?? "Updating forecast…"
    }

    /// Copies the worker sources out of the app bundle so the venv can live next to them.
    private func copyBundledFiles() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        for name in ["worker.py", "pyproject.toml", "setup.sh"] {
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let source = Bundle.main.url(forResource: parts[0], withExtension: parts[1]) else { continue }
            let target = Self.directory.appendingPathComponent(name)
            if let a = try? Data(contentsOf: source), let b = try? Data(contentsOf: target), a == b { continue }
            try? fm.removeItem(at: target)
            try? fm.copyItem(at: source, to: target)
        }
    }
}
