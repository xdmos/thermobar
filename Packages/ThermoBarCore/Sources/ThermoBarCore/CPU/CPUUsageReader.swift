import Darwin

public struct CPUUsageReader: Sendable {
    public init() {}

    public func readTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )

        guard result == KERN_SUCCESS, let processorInfo else {
            return nil
        }

        let allocationSize = vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: processorInfo)),
                allocationSize
            )
        }

        let ticksPerProcessor = MemoryLayout<processor_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size
        let expectedCount = processorCount.multipliedReportingOverflow(by: natural_t(ticksPerProcessor))
        guard
            !expectedCount.overflow,
            processorCount > 0,
            processorInfoCount == expectedCount.partialValue,
            let count = Int(exactly: processorCount)
        else {
            return nil
        }

        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(count)

        for processor in 0 ..< count {
            let offset = processor * ticksPerProcessor
            let user = UInt64(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_USER)]))
            let system = UInt64(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_SYSTEM)]))
            let idle = UInt64(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_IDLE)]))
            let nice = UInt64(UInt32(bitPattern: processorInfo[offset + Int(CPU_STATE_NICE)]))
            ticks.append(CPUTicks(user: user, system: system, nice: nice, idle: idle))
        }

        return ticks
    }
}
