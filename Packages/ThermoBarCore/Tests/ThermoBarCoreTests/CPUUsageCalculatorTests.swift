import Testing
import Darwin
@testable import ThermoBarCore

@Test func cpuDeltaOracleIsFiftySixPercent() {
    var calculator = CPUUsageCalculator()

    #expect(calculator.consume([CPUTicks(user: 100, system: 50, nice: 0, idle: 850)]) == nil)

    let value = calculator.consume([CPUTicks(user: 180, system: 100, nice: 10, idle: 960)])
    #expect(value == 56)
}

@Test func cpuRegressionResetsBaseline() {
    var calculator = CPUUsageCalculator()

    _ = calculator.consume([CPUTicks(user: 10, system: 10, nice: 0, idle: 80)])
    #expect(calculator.consume([CPUTicks(user: 1, system: 1, nice: 0, idle: 8)]) == nil)

    #expect(calculator.consume([CPUTicks(user: 3, system: 2, nice: 1, idle: 14)]) == 40)
}

@Test func cpuCountChangeReplacesBaseline() {
    var calculator = CPUUsageCalculator()

    _ = calculator.consume([CPUTicks(user: 10, system: 10, nice: 0, idle: 80)])
    #expect(
        calculator.consume([
            CPUTicks(user: 1, system: 1, nice: 0, idle: 8),
            CPUTicks(user: 1, system: 1, nice: 0, idle: 8)
        ]) == nil
    )

    #expect(
        calculator.consume([
            CPUTicks(user: 2, system: 2, nice: 0, idle: 16),
            CPUTicks(user: 2, system: 2, nice: 0, idle: 16)
        ]) == 20
    )
}

@Test func cpuResetClearsBaseline() {
    var calculator = CPUUsageCalculator()

    _ = calculator.consume([CPUTicks(user: 10, system: 10, nice: 0, idle: 80)])
    calculator.reset()

    #expect(calculator.consume([CPUTicks(user: 20, system: 20, nice: 0, idle: 160)]) == nil)
}

@Test func cpuEmptyInputReplacesBaseline() {
    var calculator = CPUUsageCalculator()

    _ = calculator.consume([CPUTicks(user: 10, system: 10, nice: 0, idle: 80)])
    #expect(calculator.consume([]) == nil)
    #expect(calculator.consume([CPUTicks(user: 20, system: 20, nice: 0, idle: 160)]) == nil)
}

@Test func cpuZeroTotalDeltaIsRejected() {
    var calculator = CPUUsageCalculator()
    let ticks = CPUTicks(user: 10, system: 10, nice: 0, idle: 80)

    _ = calculator.consume([ticks])

    #expect(calculator.consume([ticks]) == nil)
}

@Test func cpuAggregateOverflowIsRejected() {
    var calculator = CPUUsageCalculator()

    _ = calculator.consume([
        CPUTicks(user: 0, system: 0, nice: 0, idle: 0),
        CPUTicks(user: 0, system: 0, nice: 0, idle: 0)
    ])

    #expect(
        calculator.consume([
            CPUTicks(user: .max, system: 0, nice: 0, idle: 0),
            CPUTicks(user: .max, system: 0, nice: 0, idle: 0)
        ]) == nil
    )
}

@Test func monotonicConversionIncludesWholeAndFractionalNanoseconds() {
    #expect(MonotonicClock.nanoseconds(ticks: 10, numerator: 3, denominator: 4) == 7)
}

@Test func monotonicConversionSplitsLargeTickValuesBeforeMultiplication() {
    #expect(
        MonotonicClock.nanoseconds(ticks: .max, numerator: 2, denominator: 3)
            == 12_297_829_382_473_034_410
    )
}

@Test func monotonicConversionRejectsFractionMultiplicationOverflow() {
    #expect(MonotonicClock.nanoseconds(ticks: 2, numerator: .max, denominator: .max) == nil)
}

@Test func monotonicConversionRejectsWholeOrFinalAdditionOverflow() {
    #expect(MonotonicClock.nanoseconds(ticks: .max, numerator: 2, denominator: 1) == nil)

    let denominator: UInt64 = 1 << 32
    #expect(
        MonotonicClock.nanoseconds(
            ticks: .max,
            numerator: denominator + 1,
            denominator: denominator
        ) == nil
    )
}

@Test func monotonicConversionRejectsZeroDenominator() {
    #expect(MonotonicClock.nanoseconds(ticks: 1, numerator: 1, denominator: 0) == nil)
}

/// Pins that the mach-tick overload actually applies the process timebase. An
/// implementation that returned its argument unchanged would be correct only where the
/// timebase is 1/1 — true on Intel, false on Apple Silicon (125/3), which is exactly how
/// a missing conversion stays invisible until it reaches the hardware that scales.
@Test func machTickConversionAppliesTheProcessTimebase() {
    var timebase = mach_timebase_info_data_t()
    #expect(mach_timebase_info(&timebase) == KERN_SUCCESS)
    #expect(timebase.denom != 0)

    let ticks: UInt64 = 1_000_000
    #expect(
        MonotonicClock.nanoseconds(machTicks: ticks)
            == MonotonicClock.nanoseconds(
                ticks: ticks,
                numerator: UInt64(timebase.numer),
                denominator: UInt64(timebase.denom)
            )
    )

    // Where the timebase scales, the identity implementation is observably wrong.
    if timebase.numer != timebase.denom {
        #expect(MonotonicClock.nanoseconds(machTicks: ticks) != ticks)
    }
}
