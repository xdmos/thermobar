import Foundation
import IOKit

public struct GPUUsageReader: Sendable {
    private let schema: PrivateMetricSchema

    public init(schema: PrivateMetricSchema) {
        self.schema = schema
    }

    public func read() -> Double? {
        guard PrivateMetricSchemaRegistry.schema(model: schema.model, build: schema.osBuild) == schema else {
            return nil
        }
        guard let matching = IOServiceMatching("IOAccelerator") else {
            return nil
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var accelerators: [[String: Any]] = []
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else {
                break
            }
            defer { IOObjectRelease(service) }

            guard let property = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() else {
                continue
            }
            guard CFGetTypeID(property) == CFDictionaryGetTypeID() else {
                continue
            }

            guard let statistics = property as? NSDictionary else {
                continue
            }
            if let value = statistics.object(forKey: schema.gpuUtilizationKey) {
                accelerators.append([schema.gpuUtilizationKey: value])
            }
        }

        return GPUUsageParser.maximumPercent(in: accelerators, key: schema.gpuUtilizationKey)
    }
}
