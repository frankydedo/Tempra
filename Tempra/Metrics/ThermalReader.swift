import Foundation

/// Reads Apple Silicon temperature sensors through the (private) IOHIDEventSystem API.
///
/// Sensor naming on M-series chips:
///  - "PMU tdie*"  → SoC die sensors (CPU/GPU clusters)
///  - "gas gauge battery" → battery cells
///  - "NAND CH* temp" → SSD
final class ThermalReader {
    struct Reading {
        var socAverage: Double?
        var socMax: Double?
        var battery: Double?
        var ssd: Double?
        var sensors: [String: Double]
    }

    private let client: IOHIDEventSystemClient?

    init() {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault)?.takeRetainedValue()
        if let client {
            // Usage page 0xff00 / usage 5 = AppleVendor temperature sensors.
            let matching = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary
            _ = IOHIDEventSystemClientSetMatching(client, matching)
        }
    }

    func read() -> Reading {
        guard let client,
              let services = IOHIDEventSystemClientCopyServices(client) as? [AnyObject] else {
            return Reading(sensors: [:])
        }

        var sensors: [String: [Double]] = [:]
        let field = Int32(TEMPRA_HID_EVENT_TYPE_TEMPERATURE << 16)
        for service in services {
            let ref = service as! IOHIDServiceClient
            guard let name = IOHIDServiceClientCopyProperty(ref, "Product" as CFString) as? String,
                  let event = IOHIDServiceClientCopyEvent(ref, Int64(TEMPRA_HID_EVENT_TYPE_TEMPERATURE), 0, 0)?.takeRetainedValue()
            else { continue }
            let value = IOHIDEventGetFloatValue(event, field)
            // Unused sensors report large negative values.
            guard value > 0, value < 130 else { continue }
            sensors[name, default: []].append(value)
        }

        let flat = sensors.mapValues { $0.reduce(0, +) / Double($0.count) }
        let die = flat.filter { $0.key.hasPrefix("PMU tdie") }.map(\.value)
        let battery = flat.filter { $0.key.localizedCaseInsensitiveContains("battery") }.map(\.value)
        let ssd = flat.filter { $0.key.hasPrefix("NAND") }.map(\.value)

        return Reading(socAverage: die.average,
                       socMax: die.max(),
                       battery: battery.average,
                       ssd: ssd.average,
                       sensors: flat)
    }
}

extension Array where Element == Double {
    var average: Double? { isEmpty ? nil : reduce(0, +) / Double(count) }
}
