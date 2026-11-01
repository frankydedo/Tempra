import Foundation

/// Real-time power readings, refreshed every sample (unlike the battery gauge, which updates
/// every 30–60 s). No privileges are needed for any of them.
struct PowerReading: Sendable {
    /// Whole system, from the SMC (`PSTR`).
    var system: Double?
    /// The whole chip (CPU, GPU and the rest of the SoC), from the SMC (`PHPC`).
    var soc: Double?
    /// GPU, from IOReport energy counters.
    var gpu: Double?
    /// Power coming in from the adapter, from the SMC (`PDTR`). Only meaningful on the adapter.
    var adapterInput: Double?

    /// Chip power not used by the GPU: mostly the CPU, plus memory controller and fabric.
    var cpuAndRest: Double? {
        guard let soc, let gpu else { return nil }
        return max(soc - gpu, 0)
    }
}

final class PowerReader {
    private let smc = tempra_smc_open() == 0
    private let ioreport = tempra_ioreport_open() == 0

    func read() -> PowerReading {
        var reading = PowerReading()
        if smc {
            reading.system = value("PSTR")
            reading.soc = value("PHPC")
            reading.adapterInput = value("PDTR")
        }
        if ioreport {
            let gpu = tempra_ioreport_gpu_watts()
            if gpu >= 0 { reading.gpu = gpu }
        }
        return reading
    }

    private func value(_ key: String) -> Double? {
        var result = 0.0
        guard tempra_smc_read(key, &result) == 0, result.isFinite, result >= 0 else { return nil }
        return result
    }
}
