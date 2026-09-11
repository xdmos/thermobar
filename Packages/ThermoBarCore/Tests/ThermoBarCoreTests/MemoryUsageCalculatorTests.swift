import Testing
@testable import ThermoBarCore

@Test func memoryPageOracleProducesBytes() {
    let pages = VMPageCounts(
        active: 100,
        inactive: 50,
        speculative: 10,
        wired: 20,
        compressed: 30,
        purgeable: 5,
        external: 15
    )

    #expect(
        MemoryUsageCalculator.compute(
            pages: pages,
            pageSize: 16_384,
            totalBytes: 8_388_608
        )?.usedBytes == 3_112_960
    )
}

@Test func memoryAdditionOverflowIsRejected() {
    let pages = VMPageCounts(
        active: .max,
        inactive: 1,
        speculative: 0,
        wired: 0,
        compressed: 0,
        purgeable: 0,
        external: 0
    )

    #expect(
        MemoryUsageCalculator.compute(pages: pages, pageSize: 1, totalBytes: .max) == nil
    )
}

@Test func memorySubtractionUnderflowIsRejected() {
    let pages = VMPageCounts(
        active: 0,
        inactive: 0,
        speculative: 0,
        wired: 0,
        compressed: 0,
        purgeable: 1,
        external: 0
    )

    #expect(
        MemoryUsageCalculator.compute(pages: pages, pageSize: 1, totalBytes: .max) == nil
    )
}

@Test func memoryPageMultiplicationOverflowIsRejected() {
    let pages = VMPageCounts(
        active: .max,
        inactive: 0,
        speculative: 0,
        wired: 0,
        compressed: 0,
        purgeable: 0,
        external: 0
    )

    #expect(
        MemoryUsageCalculator.compute(pages: pages, pageSize: 2, totalBytes: .max) == nil
    )
}

@Test func memoryOverTotalIsRejected() {
    let pages = VMPageCounts(
        active: 2,
        inactive: 0,
        speculative: 0,
        wired: 0,
        compressed: 0,
        purgeable: 0,
        external: 0
    )

    #expect(
        MemoryUsageCalculator.compute(pages: pages, pageSize: 1, totalBytes: 1) == nil
    )
}

@Test func memoryZeroPageSizeIsRejected() {
    #expect(
        MemoryUsageCalculator.compute(
            pages: VMPageCounts(active: 0, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 0, external: 0),
            pageSize: 0,
            totalBytes: 1
        ) == nil
    )
}

@Test func memoryZeroTotalBytesIsRejected() {
    #expect(
        MemoryUsageCalculator.compute(
            pages: VMPageCounts(active: 0, inactive: 0, speculative: 0, wired: 0, compressed: 0, purgeable: 0, external: 0),
            pageSize: 1,
            totalBytes: 0
        ) == nil
    )
}
