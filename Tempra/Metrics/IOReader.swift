import Darwin
import Foundation
import IOKit

/// Network and disk throughput, computed from cumulative byte counters.
final class IOReader {
    struct Reading {
        var netIn: Double = 0
        var netOut: Double = 0
        var diskRead: Double = 0
        var diskWrite: Double = 0
        var diskFree: Int64 = 0
        var diskTotal: Int64 = 0
    }

    private var lastNet: (inBytes: UInt64, outBytes: UInt64)?
    private var lastDisk: (read: UInt64, write: UInt64)?
    private var lastDate: Date?

    func read() -> Reading {
        let now = Date()
        let net = networkBytes()
        let disk = diskBytes()
        var reading = Reading()

        if let lastDate, let lastNet, let lastDisk {
            let dt = max(now.timeIntervalSince(lastDate), 0.001)
            reading.netIn = Double(net.inBytes &- lastNet.inBytes) / dt
            reading.netOut = Double(net.outBytes &- lastNet.outBytes) / dt
            reading.diskRead = Double(disk.read &- lastDisk.read) / dt
            reading.diskWrite = Double(disk.write &- lastDisk.write) / dt
        }
        lastNet = net
        lastDisk = disk
        lastDate = now

        let root = URL(fileURLWithPath: "/")
        if let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            reading.diskFree = values.volumeAvailableCapacityForImportantUsage ?? 0
            reading.diskTotal = Int64(values.volumeTotalCapacity ?? 0)
        }
        return reading
    }

    private func networkBytes() -> (inBytes: UInt64, outBytes: UInt64) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return (0, 0) }
        defer { freeifaddrs(head) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = pointer.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0,
                  let data = ifa.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let name = String(cString: ifa.ifa_name)
            // Only physical/user-facing links; skip tunnels and virtual bridges to avoid double counting.
            guard name.hasPrefix("en") || name.hasPrefix("pdp_ip") else { continue }
            inBytes += UInt64(data.pointee.ifi_ibytes)
            outBytes += UInt64(data.pointee.ifi_obytes)
        }
        return (inBytes, outBytes)
    }

    private func diskBytes() -> (read: UInt64, write: UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }

        var read: UInt64 = 0, write: UInt64 = 0
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let stats = IORegistryEntryCreateCFProperty(entry, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { continue }
            read += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            write += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, write)
    }
}
