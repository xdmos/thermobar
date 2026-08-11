import Darwin
import Foundation
import Testing
@testable import ThermoBarCore

@Test func parserReturnsMaximumFromExactKeyValues() {
    let result = GPUUsageParser.maximumPercent(
        in: [
            ["Device Utilization %": 12],
            ["Device Utilization %": NSNumber(value: 34)]
        ],
        key: "Device Utilization %"
    )

    #expect(result == 34)
}

@Test func parserAcceptsZero() {
    let result = GPUUsageParser.maximumPercent(
        in: [["Device Utilization %": NSNumber(value: 0)]],
        key: "Device Utilization %"
    )

    #expect(result == 0)
}

@Test func parserAcceptsOneHundred() {
    let result = GPUUsageParser.maximumPercent(
        in: [["Device Utilization %": NSNumber(value: 100)]],
        key: "Device Utilization %"
    )

    #expect(result == 100)
}

@Test func parserRejectsOutOfRangeAndNonFiniteValues() {
    let result = GPUUsageParser.maximumPercent(
        in: [
            ["Device Utilization %": NSNumber(value: -1)],
            ["Device Utilization %": NSNumber(value: 101)],
            ["Device Utilization %": NSNumber(value: Double.nan)],
            ["Device Utilization %": NSNumber(value: Double.infinity)]
        ],
        key: "Device Utilization %"
    )

    #expect(result == nil)
}

@Test func parserRejectsStringNullAndBooleanValues() {
    let result = GPUUsageParser.maximumPercent(
        in: [
            ["Device Utilization %": "34"],
            ["Device Utilization %": NSNull()],
            ["Device Utilization %": true],
            ["Device Utilization %": kCFBooleanTrue!]
        ],
        key: "Device Utilization %"
    )

    #expect(result == nil)
}

@Test func parserIgnoresInvalidAcceleratorsWhenAnotherHasValidExactKey() {
    let result = GPUUsageParser.maximumPercent(
        in: [
            [:],
            ["Device Utilization %": "invalid"],
            ["Device Utilization %": NSNumber(value: 61)],
            ["Device Utilization %": NSNumber(value: 12)]
        ],
        key: "Device Utilization %"
    )

    #expect(result == 61)
}

@Test func parserDoesNotUseSimilarlyNamedKeysAsFallback() {
    let result = GPUUsageParser.maximumPercent(
        in: [
            ["GPU Utilization %": NSNumber(value: 75)],
            ["Device Utilization": NSNumber(value: 68)]
        ],
        key: "Device Utilization %"
    )

    #expect(result == nil)
}

@Test func parserReturnsNilWhenEveryAcceleratorIsMissingTheExactKey() {
    let result = GPUUsageParser.maximumPercent(
        in: [[:], ["GPU Utilization %": NSNumber(value: 70)]],
        key: "Device Utilization %"
    )

    #expect(result == nil)
}

@Test func parserPreservesFiniteFractionalNSNumberWithinBounds() {
    let result = GPUUsageParser.maximumPercent(
        in: [["Device Utilization %": NSNumber(value: 34.125)]],
        key: "Device Utilization %"
    )

    #expect(result == 34.125)
}

@Test func thermalStateReaderMapsKnownStates() {
    #expect(ThermalStateReader.thermalLevel(for: .nominal) == .nominal)
    #expect(ThermalStateReader.thermalLevel(for: .fair) == .fair)
    #expect(ThermalStateReader.thermalLevel(for: .serious) == .serious)
    #expect(ThermalStateReader.thermalLevel(for: .critical) == .critical)
}

@Suite("GPUUsageLiveTests", .enabled(if: ProcessInfo.processInfo.environment["THERMOBAR_RUN_LIVE_SENSORS"] == "1"))
struct GPUUsageLiveTests {
    @Test func targetGPUUtilizationIsFiniteAndBounded() throws {
        let model = try gpuSysctlString(named: "hw.model")
        let build = try gpuSysctlString(named: "kern.osversion")
        let schema = try #require(PrivateMetricSchemaRegistry.schema(model: model, build: build))
        let value = try #require(GPUUsageReader(schema: schema).read())

        #expect(value.isFinite)
        #expect((0 ... 100).contains(value))
    }
}

private func gpuSysctlString(named name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        throw GPUSysctlError.readFailed
    }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        throw GPUSysctlError.readFailed
    }

    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
}

private enum GPUSysctlError: Error {
    case readFailed
}
