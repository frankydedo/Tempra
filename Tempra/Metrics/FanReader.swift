import Foundation

struct FanReading: Sendable {
    let rpm: Double
    let minRPM: Double
    let maxRPM: Double

    var isSpinning: Bool { rpm > 0 }
    /// 0...1 between the fan's minimum and maximum speed (0 when stopped).
    var fraction: Double { maxRPM > minRPM && rpm > 0 ? min(max((rpm - minRPM) / (maxRPM - minRPM), 0), 1) : 0 }
}

/// Reads fan speeds from the SMC (keys FNum, F<n>Ac/Mn/Mx). Apple Silicon fans stop entirely
/// at low load, so 0 rpm is normal. Fanless Macs (e.g. MacBook Air) report no fans.
final class FanReader {
    private let available = tempra_smc_open() == 0

    func read() -> [FanReading] {
        guard available, let count = value("FNum"), count > 0 else { return [] }
        return (0..<min(Int(count), 4)).compactMap { i in
            guard let rpm = value("F\(i)Ac") else { return nil }
            return FanReading(rpm: max(rpm, 0), minRPM: value("F\(i)Mn") ?? 0, maxRPM: value("F\(i)Mx") ?? 0)
        }
    }

    private func value(_ key: String) -> Double? {
        var result = 0.0
        return tempra_smc_read(key, &result) == 0 ? result : nil
    }
}
