import Foundation
import IOKit

/// Reads Apple GPU utilisation from the IOAccelerator's "PerformanceStatistics" (no privileges needed).
enum GPUReader {
    struct Reading {
        var utilization: Double      // 0...1, whole device
        var renderer: Double         // 0...1, fragment/compute work
        var tiler: Double            // 0...1, geometry work
        var memoryInUse: UInt64      // bytes of unified memory used by the GPU
        var memoryAllocated: UInt64
    }

    struct Info {
        var model: String
        var coreCount: Int
    }

    /// GPU model and core count; these never change, so read them once.
    static let info: Info? = {
        guard let service = accelerator() else { return nil }
        defer { IOObjectRelease(service) }
        let model = property(service, "model") as? String
        let cores = (property(service, "gpu-core-count") as? NSNumber)?.intValue
        return Info(model: model ?? "GPU", coreCount: cores ?? 0)
    }()

    static func read() -> Reading? {
        guard let service = accelerator() else { return nil }
        defer { IOObjectRelease(service) }
        guard let stats = property(service, "PerformanceStatistics") as? [String: Any] else { return nil }

        func percent(_ key: String) -> Double { ((stats[key] as? NSNumber)?.doubleValue ?? 0) / 100 }
        func bytes(_ key: String) -> UInt64 { (stats[key] as? NSNumber)?.uint64Value ?? 0 }

        return Reading(utilization: percent("Device Utilization %"),
                       renderer: percent("Renderer Utilization %"),
                       tiler: percent("Tiler Utilization %"),
                       memoryInUse: bytes("In use system memory"),
                       memoryAllocated: bytes("Alloc system memory"))
    }

    private static func accelerator() -> io_service_t? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        return service == 0 ? nil : service
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
