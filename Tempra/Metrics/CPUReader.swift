import Darwin
import Foundation

/// Computes CPU utilisation from the delta of per-core tick counters between two reads.
final class CPUReader {
    private var previous: [[UInt32]] = []
    let efficiencyCoreCount: Int = CPUReader.sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    struct Reading {
        var total: Double
        var user: Double
        var system: Double
        var cores: [Double]
    }

    func read() -> Reading? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }

        var current: [[UInt32]] = []
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * Int(CPU_STATE_MAX)
            current.append((0..<Int(CPU_STATE_MAX)).map { UInt32(bitPattern: info[base + $0]) })
        }
        defer { previous = current }
        guard previous.count == current.count else { return nil }

        var cores: [Double] = []
        var userSum: UInt64 = 0, systemSum: UInt64 = 0, busySum: UInt64 = 0, totalSum: UInt64 = 0
        for (now, before) in zip(current, previous) {
            let d = (0..<Int(CPU_STATE_MAX)).map { UInt64(now[$0] &- before[$0]) }
            let user = d[Int(CPU_STATE_USER)] + d[Int(CPU_STATE_NICE)]
            let system = d[Int(CPU_STATE_SYSTEM)]
            let total = d.reduce(0, +)
            cores.append(total > 0 ? Double(user + system) / Double(total) : 0)
            userSum += user; systemSum += system; busySum += user + system; totalSum += total
        }
        guard totalSum > 0 else { return nil }
        return Reading(total: Double(busySum) / Double(totalSum),
                       user: Double(userSum) / Double(totalSum),
                       system: Double(systemSum) / Double(totalSum),
                       cores: cores)
    }

    static func loadAverage() -> (Double, Double, Double) {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return (0, 0, 0) }
        return (loads[0], loads[1], loads[2])
    }

    /// e.g. "Apple M4"
    static let chipName: String = {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        let name = String(cString: buffer)
        return name.isEmpty ? "Mac" : name
    }()

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
