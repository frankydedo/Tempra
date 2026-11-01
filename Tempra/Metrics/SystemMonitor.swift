import Foundation
import Observation

/// Owns the readers. Runs off the main thread so sampling never stalls the UI.
actor Sampler {
    private let cpu = CPUReader()
    private let thermal = ThermalReader()
    private let io = IOReader()

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
        }

        let t = thermal.read()
        s.socTemp = t.socAverage
        s.socTempMax = t.socMax
        s.batteryTemp = t.battery
        s.ssdTemp = t.ssd
        s.thermalState = ProcessInfo.processInfo.thermalState

        s.battery = BatteryReader.read()

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

    let store = HistoryStore()

    /// Set by the dashboard while the Processes view is visible.
    var processesVisible = false {
        didSet { if processesVisible { Task { await refreshProcesses() } } }
    }

    private let sampler = Sampler()
    private var loop: Task<Void, Never>?
    private var lastRollUp = Date.distantPast
    private var lastHealthRecord = Date.distantPast

    private init() {}

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
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
        latest = snapshot
        hasSample = true
        appendLive(snapshot)

        await store.insert(snapshot)
        if snapshot.date.timeIntervalSince(lastRollUp) >= 60 {
            lastRollUp = snapshot.date
            await store.rollUpAndPrune(now: snapshot.date)
        }
        if let battery = snapshot.battery, snapshot.date.timeIntervalSince(lastHealthRecord) >= 3600 {
            lastHealthRecord = snapshot.date
            await store.recordBatteryHealth(battery, at: snapshot.date)
        }
        if processesVisible {
            await refreshProcesses()
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

    private func refreshProcesses() async {
        processes = await ProcessReader.all()
    }
}
