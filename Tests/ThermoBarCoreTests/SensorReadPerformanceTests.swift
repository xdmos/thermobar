import Darwin
import Foundation
import Testing
@testable import ThermoBarCore

@Suite("SensorReadPerformanceTests", .enabled(if: performanceMeasurementsAreEnabled))
struct SensorReadPerformanceTests {
    @Test func releaseCompleteSensorReadP95IsWithinBudget() throws {
        let schema = try #require(performanceSchema)

        let cpuReader = CPUUsageReader()
        let memoryReader = MemoryUsageReader()
        let thermalReader = ThermalStateReader()
        let gpuReader = GPUUsageReader(schema: schema)
        let smc = try SMCClient()
        defer { smc.close() }

        var cpuCalculator = CPUUsageCalculator()
        var successfulCPUCalculations = 0
        for _ in 0 ..< 20 {
            let snapshot = try completeRead(
                schema: schema,
                smc: smc,
                cpuReader: cpuReader,
                cpuCalculator: &cpuCalculator,
                memoryReader: memoryReader,
                thermalReader: thermalReader,
                gpuReader: gpuReader
            )
            if snapshot.cpuPercent != nil {
                successfulCPUCalculations += 1
            }
        }

        var durations = [UInt64]()
        durations.reserveCapacity(600)
        for _ in 0 ..< 600 {
            let start = MonotonicClock.nowNanoseconds()
            let snapshot = try completeRead(
                schema: schema,
                smc: smc,
                cpuReader: cpuReader,
                cpuCalculator: &cpuCalculator,
                memoryReader: memoryReader,
                thermalReader: thermalReader,
                gpuReader: gpuReader
            )
            if snapshot.cpuPercent != nil {
                successfulCPUCalculations += 1
            }
            let end = MonotonicClock.nowNanoseconds()
            durations.append(end - start)
        }

        _ = try #require(successfulCPUCalculations > 0)
        durations.sort()
        let p95Nanoseconds = durations[569] // ceil(0.95 * 600) - 1
        print("SensorReadPerformanceTests samples=600 p95_ns=\(p95Nanoseconds)")
        #expect(p95Nanoseconds <= 25_000_000)
    }

    private func completeRead(
        schema: PrivateMetricSchema,
        smc: SMCClient,
        cpuReader: CPUUsageReader,
        cpuCalculator: inout CPUUsageCalculator,
        memoryReader: MemoryUsageReader,
        thermalReader: ThermalStateReader,
        gpuReader: GPUUsageReader
    ) throws -> SystemSnapshot {
        let ticks = try #require(cpuReader.readTicks())
        let memory = try #require(memoryReader.read())
        let gpu = try #require(gpuReader.read())
        let cpuPercent = cpuCalculator.consume(ticks)
        let temperature = TemperatureReader(schema: schema, reader: smc).read()
        let fan = FanReader(schema: schema, reader: smc).read()

        guard temperature.cpuAverageCelsius != nil,
              temperature.gpuAverageCelsius != nil,
              temperature.chipHotspotCelsius != nil else {
            throw PerformanceMeasurementError.temperatureUnavailable
        }
        #expect(temperature.cpuError == nil)
        #expect(temperature.gpuError == nil)
        guard fan.fastestRPM != nil,
              fan.fastestMaximumRPM != nil,
              fan.validatedFanCount == schema.expectedFanCount else {
            throw PerformanceMeasurementError.fanUnavailable
        }
        #expect(fan.error == nil)

        return SystemSnapshot(
            monotonicNanoseconds: MonotonicClock.nowNanoseconds(),
            cpuPercent: cpuPercent,
            memory: memory,
            gpuPercent: gpu,
            temperature: temperature,
            fan: fan,
            thermalLevel: thermalReader.read(),
            publicMetricError: nil,
            privateMetricError: nil
        )
    }
}

#if DEBUG
private let performanceMeasurementsAreEnabled = false
#else
private let performanceMeasurementsAreEnabled =
    ProcessInfo.processInfo.environment["THERMOBAR_RUN_PERFORMANCE"] == "1"
#endif

private let performanceSchema: PrivateMetricSchema? = {
    guard let model = try? performanceSysctlString(named: "hw.model"),
          let build = try? performanceSysctlString(named: "kern.osversion") else {
        return nil
    }
    return PrivateMetricSchemaRegistry.schema(model: model, build: build)
}()

private func performanceSysctlString(named name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
        throw PerformanceSysctlError.readFailed
    }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        throw PerformanceSysctlError.readFailed
    }

    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

private enum PerformanceSysctlError: Error {
    case readFailed
}

private enum PerformanceMeasurementError: Error {
    case temperatureUnavailable
    case fanUnavailable
}
