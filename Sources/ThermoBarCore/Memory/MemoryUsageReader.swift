@preconcurrency import Darwin

public struct MemoryUsageReader: Sendable {
    public init() {}

    public func read() -> MemoryMetric? {
        var basicInfo = host_basic_info_data_t()
        var basicInfoCount = mach_msg_type_number_t(
            MemoryLayout<host_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let basicInfoResult = withUnsafeMutablePointer(to: &basicInfo) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicInfoCount)) {
                host_info(mach_host_self(), HOST_BASIC_INFO, $0, &basicInfoCount)
            }
        }

        guard basicInfoResult == KERN_SUCCESS else {
            return nil
        }

        var statistics = vm_statistics64_data_t()
        var statisticsCount = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let statisticsResult = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(statisticsCount)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &statisticsCount)
            }
        }

        guard statisticsResult == KERN_SUCCESS else {
            return nil
        }

        let pageSize = UInt64(vm_page_size)
        let pages = VMPageCounts(
            active: UInt64(statistics.active_count),
            inactive: UInt64(statistics.inactive_count),
            speculative: UInt64(statistics.speculative_count),
            wired: UInt64(statistics.wire_count),
            compressed: UInt64(statistics.compressor_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            external: UInt64(statistics.external_page_count)
        )

        return MemoryUsageCalculator.compute(
            pages: pages,
            pageSize: pageSize,
            totalBytes: basicInfo.max_mem
        )
    }
}
