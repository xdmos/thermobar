import Foundation
import IOKit

/// Reads Metal's cumulative GPU-time counters exposed by the active accelerator.
/// The registry is read-only and does not require elevated privileges.
struct GPUClientUsageReader: Sendable {
    struct Usage: Equatable, Sendable {
        let pid: Int32
        let cumulativeGPUTimeNanoseconds: UInt64
    }

    func read() -> [Int32: UInt64] {
        guard let matching = IOServiceMatching("IOAccelerator") else { return [:] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }

        var result: [Int32: UInt64] = [:]
        var invalidPIDs = Set<Int32>()
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            collect(from: service, into: &result, invalidPIDs: &invalidPIDs)
        }
        for pid in invalidPIDs { result.removeValue(forKey: pid) }
        return result
    }

    private func collect(from entry: io_registry_entry_t, into result: inout [Int32: UInt64], invalidPIDs: inout Set<Int32>) {
        if let properties = properties(for: entry), let usage = Self.parse(properties) {
            let sum = result[usage.pid, default: 0].addingReportingOverflow(usage.cumulativeGPUTimeNanoseconds)
            if sum.overflow { invalidPIDs.insert(usage.pid) } else { result[usage.pid] = sum.partialValue }
        }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }
        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            collect(from: child, into: &result, invalidPIDs: &invalidPIDs)
            IOObjectRelease(child)
        }
    }

    private func properties(for entry: io_registry_entry_t) -> [String: Any]? {
        var result: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &result, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let result else { return nil }
        return result.takeRetainedValue() as? [String: Any]
    }

    static func parse(_ properties: [String: Any]) -> Usage? {
        guard let creator = properties["IOUserClientCreator"] as? String,
              let pid = parsePID(creator),
              let usages = properties["AppUsage"] as? [[String: Any]],
              !usages.isEmpty else { return nil }
        var cumulative: UInt64 = 0
        for usage in usages {
            guard usage["API"] as? String == "Metal",
                  let time = unsignedInteger(usage["accumulatedGPUTime"]) else { return nil }
            let sum = cumulative.addingReportingOverflow(time)
            guard !sum.overflow else { return nil }
            cumulative = sum.partialValue
        }
        return .init(pid: pid, cumulativeGPUTimeNanoseconds: cumulative)
    }

    private static func parsePID(_ creator: String) -> Int32? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix { $0.isNumber }
        guard !digits.isEmpty, let value = Int32(digits), value > 0 else { return nil }
        return value
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber else { return nil }
        let signed = number.int64Value
        guard signed >= 0, NSNumber(value: signed).compare(number) == .orderedSame else { return nil }
        return UInt64(signed)
    }
}
