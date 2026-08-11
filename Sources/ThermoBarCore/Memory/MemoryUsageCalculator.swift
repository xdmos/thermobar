public struct VMPageCounts: Equatable, Sendable {
    public let active: UInt64
    public let inactive: UInt64
    public let speculative: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let purgeable: UInt64
    public let external: UInt64

    public init(
        active: UInt64,
        inactive: UInt64,
        speculative: UInt64,
        wired: UInt64,
        compressed: UInt64,
        purgeable: UInt64,
        external: UInt64
    ) {
        self.active = active
        self.inactive = inactive
        self.speculative = speculative
        self.wired = wired
        self.compressed = compressed
        self.purgeable = purgeable
        self.external = external
    }
}

public enum MemoryUsageCalculator {
    public static func compute(pages: VMPageCounts, pageSize: UInt64, totalBytes: UInt64) -> MemoryMetric? {
        guard pageSize != 0, totalBytes != 0 else {
            return nil
        }

        guard
            let activeInactive = sum(pages.active, pages.inactive),
            let activeInactiveSpeculative = sum(activeInactive, pages.speculative),
            let resident = sum(activeInactiveSpeculative, pages.wired),
            let residentCompressed = sum(resident, pages.compressed),
            let withoutPurgeable = difference(residentCompressed, pages.purgeable),
            let usedPages = difference(withoutPurgeable, pages.external)
        else {
            return nil
        }

        let byteResult = usedPages.multipliedReportingOverflow(by: pageSize)
        guard !byteResult.overflow, byteResult.partialValue <= totalBytes else {
            return nil
        }

        return MemoryMetric(usedBytes: byteResult.partialValue, totalBytes: totalBytes)
    }

    private static func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }

    private static func difference(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.subtractingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
