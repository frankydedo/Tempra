import Foundation
import Observation

/// Owns the readers. Runs off the main thread so sampling never stalls the UI.
actor Sampler {
    private let cpu = CPUReader()
    private let thermal = ThermalReader()
    private let io = IOReader()
    private let fan = FanReader()
    private let powerReader = PowerReader()
    private var lastSwapOut: (bytes: UInt64, date: Date)?

    func sample() -> Snapshot {
        var s = Snapshot()
        if let c = cpu.read() {
            s.cpuTotal = c.total
            s.cpuUser = c.user
            s.cpuSystem = c.system
            s.cpuCores = c.cores
        }
        s.efficiencyCoreCount = cpu.efficiencyCoreCount
        s.loadAverage = CPUReader.loadAverage()

        if let g = GPUReader.read() {
            s.gpu = g.utilization
            s.gpuRenderer = g.renderer
            s.gpuTiler = g.tiler
            s.gpuMemoryInUse = g.memoryInUse
            s.gpuMemoryAllocated = g.memoryAllocated
        }

        if let m = MemoryReader.read() {
            s.memTotal = m.total
            s.memUsed = m.used
            s.memApp = m.app
            s.memWired = m.wired
            s.memCompressed = m.compressed
            s.memCached = m.cached
            s.swapUsed = m.swapUsed
            s.swapTotal = m.swapTotal
            s.memPressure = m.pressure
            s.memPressureLevel = m.pressureLevel
            if let last = lastSwapOut, m.swappedOut >= last.bytes {
                s.swapOutRate = Double(m.swappedOut - last.bytes) / max(s.date.timeIntervalSince(last.date), 0.001)
            }
            lastSwapOut = (m.swappedOut, s.date)
        }

        let t = thermal.read()
        s.socTemp = t.socAverage
        s.socTempMax = t.socMax
        s.batteryTemp = t.battery
        s.ssdTemp = t.ssd
        s.thermalState = ProcessInfo.processInfo.thermalState
        s.fans = fan.read()

        s.battery = BatteryReader.read()
        s.power = powerReader.read()
        // The SMC's system power is real time; the battery gauge's only refreshes every 30–60 s.
        if let system = s.power.system, system > 0 { s.battery?.systemPower = system }

        let i = io.read()
        s.netIn = i.netIn
        s.netOut = i.netOut
        s.diskRead = i.diskRead
        s.diskWrite = i.diskWrite
        s.diskFree = i.diskFree
        s.diskTotal = i.diskTotal
        return s
    }
}

/// Samples the system on a timer, keeps a short in-memory history for sparklines
/// and persists every sample to `HistoryStore`.
@MainActor
@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()

    /// How much live history to keep in memory for sparklines.
    static let liveWindow: TimeInterval = 10 * 60

    private(set) var latest = Snapshot()
    private(set) var hasSample = false
    private(set) var live: [Metric: [ChartPoint]] = [:]
    private(set) var processes: [ProcessSample] = []
    /// When the power adapter was last plugged in or unplugged (nil until it happens).
    private(set) var lastAdapterChange: Date?

    let store = HistoryStore()

    /// Set by the dashboard while the Processes view is visible.
    var processesVisible = false {
        didSet { if processesVisible { Task { await refreshProcesses() } } }
    }

    private let sampler = Sampler()
    private var loop: Task<Void, Never>?
    private var lastRollUp = Date.distantPast
    private var lastHealthRecord = Date.distantPast
    /// Displayed health per metric, with hysteresis (see `updateHealth`).
    private(set) var healthStates: [HealthMetric: HealthState] = [:]
    private var calmerSince: [HealthMetric: Date] = [:]

    private init() {}

    func start() {
        let interval = UserDefaults.standard.double(forKey: SettingsKey.sampleInterval)
        Log.notice(.monitor, "Sampling every \(Int(interval > 0 ? interval : SettingsKey.defaultSampleInterval)) s")
        loop?.cancel()
        loop = Task { [weak self] in
            await self?.seedLive()
            // The first CPU/IO read only primes the delta counters.
            _ = await self?.sampler.sample()
            try? await Task.sleep(for: .seconds(1))
            while !Task.isCancelled {
                await self?.tick()
                let interval = UserDefaults.standard.double(forKey: SettingsKey.sampleInterval)
                try? await Task.sleep(for: .seconds(interval > 0 ? interval : SettingsKey.defaultSampleInterval))
            }
        }
    }

    func restart() { start() }

    private func tick() async {
        let snapshot = await sampler.sample()
        if hasSample {
            logChanges(from: latest, to: snapshot)
            await refreshForecastsIfPowerSourceChanged(from: latest, to: snapshot)
        }
        latest = snapshot
        hasSample = true
        appendLive(snapshot)
        updateHealth(snapshot)

        await store.insert(snapshot)
        if snapshot.date.timeIntervalSince(lastRollUp) >= 60 {
            lastRollUp = snapshot.date
            await store.rollUpAndPrune(now: snapshot.date)
            if let battery = snapshot.battery {
                await publishBatteryState(battery)
            }
        }
        if let battery = snapshot.battery, snapshot.date.timeIntervalSince(lastHealthRecord) >= 3600 {
            lastHealthRecord = snapshot.date
            await store.recordBatteryHealth(battery, at: snapshot.date)
        }
        if processesVisible {
            // `top` needs about a second for its CPU sample: refresh alongside, never delaying sampling.
            Task { await refreshProcesses() }
        }
    }

    /// Publishes the new battery state and wakes the forecaster as soon as the adapter is plugged
    /// or unplugged (or charging starts/stops), instead of waiting for the next minute.
    private func refreshForecastsIfPowerSourceChanged(from old: Snapshot, to new: Snapshot) async {
        guard let before = old.battery, let after = new.battery,
              before.onAC != after.onAC || before.isCharging != after.isCharging else { return }
        if before.onAC != after.onAC { lastAdapterChange = new.date }
        await publishBatteryState(after)
        ForecastService.shared.requestRefresh(reason: after.onAC ? (after.isCharging ? "charging" : "on adapter") : "on battery")
    }

    /// Logs adapter and charging changes, and every health state transition with the values behind it.
    private func logChanges(from old: Snapshot, to new: Snapshot) {
        if let before = old.battery, let after = new.battery {
            if before.onAC != after.onAC {
                Log.notice(.battery, (after.onAC ? "Adapter connected" : "Adapter disconnected")
                    + String(format: " at %.0f%% (battery gauge: %.2f A, system %.1f W)", after.percent, after.amperage, after.systemPower ?? 0))
            }
            if before.isCharging != after.isCharging {
                Log.notice(.battery, (after.isCharging ? "Charging started" : "Charging stopped") + String(format: " at %.0f%%", after.percent))
            }
        }
    }

    /// Updates the displayed health states. Getting worse shows immediately; getting better only
    /// after the calmer state has held for `HealthRules.recoveryDelay`, so a metric hovering around
    /// a threshold (memory pressure does) doesn't flicker between colours. Battery and power states
    /// follow plug/unplug at once. Every displayed transition is logged, and so is any non-Normal
    /// state at launch.
    private func updateHealth(_ snapshot: Snapshot) {
        for metric in HealthMetric.allCases {
            let raw = snapshot.health(metric, live: live)
            guard let shown = healthStates[metric] else {
                healthStates[metric] = raw
                if raw != .normal {
                    Log.notice(.health, "\(metric): \(raw.label) at launch (\(snapshot.healthDetail(metric, live: live)))")
                }
                continue
            }
            var next = shown
            if raw >= shown || !HealthRules.hysteresis.contains(metric) {
                next = raw
                calmerSince[metric] = nil
            } else {
                // Recovery restarts whenever the metric is back near the level shown.
                let calm = max(raw, snapshot.calmHealth(metric, live: live))
                if calm >= shown {
                    calmerSince[metric] = nil
                } else if let since = calmerSince[metric] {
                    if snapshot.date.timeIntervalSince(since) >= HealthRules.recoveryDelay { next = calm }
                } else {
                    calmerSince[metric] = snapshot.date
                }
            }
            guard next != shown else { continue }
            calmerSince[metric] = nil
            healthStates[metric] = next
            let message = "\(metric): \(shown.label) → \(next.label) (\(snapshot.healthDetail(metric, live: live)))"
            next == .normal ? Log.info(.health, message) : Log.notice(.health, message)
        }
    }

    /// Fills the sparklines from recorded history so they aren't empty right after launch.
    private func seedLive() async {
        guard live.isEmpty else { return }
        let now = Date()
        for metric in Metric.allCases {
            let points = await store.series(metric, from: now.addingTimeInterval(-Self.liveWindow), to: now,
                                            bucket: SettingsKey.defaultSampleInterval)
            if !points.isEmpty { live[metric] = points }
        }
    }

    private func appendLive(_ snapshot: Snapshot) {
        let cutoff = snapshot.date.addingTimeInterval(-Self.liveWindow)
        for metric in Metric.allCases {
            guard let value = metric.value(from: snapshot), value.isFinite else { continue }
            var points = live[metric, default: []]
            points.append(ChartPoint(date: snapshot.date, value: value))
            if let first = points.firstIndex(where: { $0.date >= cutoff }), first > 0 {
                points.removeFirst(first)
            }
            live[metric] = points
        }
    }

    /// Tells the forecaster the battery's current state and energy, which it needs to turn a
    /// power forecast into a battery level forecast.
    private func publishBatteryState(_ b: BatteryInfo) async {
        var state: [String: Any] = [
            "percent": b.percent, "on_ac": b.onAC, "charging": b.isCharging,
            "nominal_mah": b.nominalCapacity, "voltage": b.voltage,
            "battery_power": b.batteryPower,
            "not_charging_reason": b.notChargingReason, "slow_charging_reason": b.slowChargingReason,
        ]
        if b.onAC, let watts = b.adapterWatts { state["adapter_watts"] = watts }
        if let minutes = b.minutesToFull { state["macos_minutes_to_full"] = minutes }
        if let minutes = b.minutesToEmpty { state["macos_minutes_to_empty"] = minutes }
        guard b.nominalCapacity > 0, b.voltage > 0,
              let data = try? JSONSerialization.data(withJSONObject: state) else { return }
        await store.setMeta("battery_state", String(decoding: data, as: UTF8.self))
    }

    private var refreshingProcesses = false

    private func refreshProcesses() async {
        guard !refreshingProcesses else { return }
        refreshingProcesses = true
        defer { refreshingProcesses = false }
        processes = await ProcessReader.all()
    }
}
