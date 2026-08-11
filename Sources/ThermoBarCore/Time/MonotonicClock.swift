import Darwin

public enum MonotonicClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        precondition(mach_timebase_info(&info) == KERN_SUCCESS)
        precondition(info.denom != 0)
        return info
    }()

    public static func nowNanoseconds() -> UInt64 {
        guard let nanoseconds = nanoseconds(
            ticks: mach_continuous_time(),
            numerator: UInt64(timebase.numer),
            denominator: UInt64(timebase.denom)
        ) else {
            preconditionFailure("Mach timebase conversion overflowed")
        }

        return nanoseconds
    }

    static func nanoseconds(ticks: UInt64, numerator: UInt64, denominator: UInt64) -> UInt64? {
        guard denominator != 0 else {
            return nil
        }

        let quotient = ticks / denominator
        let remainder = ticks % denominator

        let quotientProduct = quotient.multipliedReportingOverflow(by: numerator)
        let remainderProduct = remainder.multipliedReportingOverflow(by: numerator)
        guard !quotientProduct.overflow, !remainderProduct.overflow else {
            return nil
        }

        let remainderNanoseconds = remainderProduct.partialValue / denominator
        let result = quotientProduct.partialValue.addingReportingOverflow(remainderNanoseconds)
        return result.overflow ? nil : result.partialValue
    }
}
