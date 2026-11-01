import Darwin
import Foundation

/// Reads physical memory, swap and memory pressure using the same counters as Activity Monitor.
enum MemoryReader {
    struct Reading {
        var total: UInt64
        var used: UInt64
        var app: UInt64
        var wired: UInt64
        var compressed: UInt64
        var cached: UInt64
        var swapUsed: UInt64
        var swapTotal: UInt64
        /// Cumulative bytes written to swap since boot.
        var swappedOut: UInt64
        var pressure: Double
        var pressureLevel: MemoryPressureLevel
    }

    static let totalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory

    static func read() -> Reading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let app = (UInt64(stats.internal_page_count) - UInt64(stats.purgeable_count)) * page
        let cached = (UInt64(stats.external_page_count) + UInt64(stats.purgeable_count)) * page
        let used = app + wired + compressed

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0)

        let freeLevel = CPUReader.sysctlInt("kern.memorystatus_level") ?? 100
        let level = MemoryPressureLevel(rawValue: CPUReader.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1) ?? .normal

        return Reading(total: totalMemory,
                       used: min(used, totalMemory),
                       app: app,
                       wired: wired,
                       compressed: compressed,
                       cached: cached,
                       swapUsed: swap.xsu_used,
                       swapTotal: swap.xsu_total,
                       swappedOut: UInt64(stats.swapouts) * page,
                       pressure: Double(100 - freeLevel) / 100,
                       pressureLevel: level)
    }
}
