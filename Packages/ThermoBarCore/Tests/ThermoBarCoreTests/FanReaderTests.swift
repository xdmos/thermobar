import Foundation
import Testing
@testable import ThermoBarCore

@Test func targetFanSchemaIsExactAndSelectsFastestFanWithItsOwnMaximum() throws {
    let schema = try #require(targetFanSchema())
    let reader = FanFakeSMCReader(values: fanValues(
        schema: schema,
        actual: [2_316, 2_500],
        maximum: [7_800, 7_900]
    ))

    let metric = FanReader(schema: schema, reader: reader).read()

    #expect(schema.fanCountKey == "FNum")
    #expect(schema.expectedFanCount == 2)
    #expect(schema.fanKeys == [
        FanKeyPair(actualKey: "F0Ac", maximumKey: "F0Mx"),
        FanKeyPair(actualKey: "F1Ac", maximumKey: "F1Mx")
    ])
    #expect(metric.fastestRPM == 2_500)
    #expect(metric.fastestMaximumRPM == 7_900)
    #expect(metric.validatedFanCount == 2)
    #expect(metric.error == nil)
    #expect(reader.requestedKeys == ["FNum", "F0Ac", "F0Mx", "F1Ac", "F1Mx"])
}

@Test func changedOrderingAndTiesAreDeterministic() throws {
    let schema = try #require(targetFanSchema())

    let changed = FanReader(
        schema: schema,
        reader: FanFakeSMCReader(values: fanValues(
            schema: schema,
            actual: [3_100, 2_500],
            maximum: [7_800, 7_900]
        ))
    ).read()
    #expect(changed.fastestRPM == 3_100)
    #expect(changed.fastestMaximumRPM == 7_800)

    let tied = FanReader(
        schema: schema,
        reader: FanFakeSMCReader(values: fanValues(
            schema: schema,
            actual: [2_500, 2_500],
            maximum: [7_800, 7_900]
        ))
    ).read()
    #expect(tied.fastestRPM == 2_500)
    #expect(tied.fastestMaximumRPM == 7_800)
}

@Test func zeroRPMIsAValidStoppedFanValue() throws {
    let schema = try #require(targetFanSchema())
    let metric = FanReader(
        schema: schema,
        reader: FanFakeSMCReader(values: fanValues(
            schema: schema,
            actual: [0, 0],
            maximum: [7_800, 7_900]
        ))
    ).read()

    #expect(metric.fastestRPM == 0)
    #expect(metric.fastestMaximumRPM == 7_800)
    #expect(metric.validatedFanCount == 2)
    #expect(metric.error == nil)
}

@Test func fanCountMustMatchTheRegisteredSchema() throws {
    let schema = try #require(targetFanSchema())
    var values = fanValues(schema: schema, actual: [2_000, 2_100], maximum: [7_800, 7_900])
    values[schema.fanCountKey] = .success(.init(key: schema.fanCountKey, dataType: "ui8 ", bytes: [1]))
    let reader = FanFakeSMCReader(values: values)

    let metric = FanReader(schema: schema, reader: reader).read()

    #expect(metric.fastestRPM == nil)
    #expect(metric.fastestMaximumRPM == nil)
    #expect(metric.validatedFanCount == nil)
    #expect(metric.error == .invalidValue)
    #expect(reader.requestedKeys == ["FNum"])
}

@Test(arguments: [
    ("negative actual", [-1.0, 2_100], [7_800.0, 7_900]),
    ("actual above maximum", [7_801.0, 2_100], [7_800.0, 7_900]),
    ("zero maximum", [2_000.0, 2_100], [0.0, 7_900]),
    ("nonfinite actual", [Double.nan, 2_100], [7_800.0, 7_900]),
    ("nonfinite maximum", [2_000.0, 2_100], [Double.infinity, 7_900])
])
func invalidFanValuesFailAtomically(input: (String, [Double], [Double])) throws {
    let schema = try #require(targetFanSchema())
    let metric = FanReader(
        schema: schema,
        reader: FanFakeSMCReader(values: fanValues(
            schema: schema,
            actual: input.1,
            maximum: input.2
        ))
    ).read()

    #expect(metric.fastestRPM == nil)
    #expect(metric.fastestMaximumRPM == nil)
    #expect(metric.validatedFanCount == nil)
    #expect(metric.error == .invalidValue)
}

@Test func fanMetadataAndMissingKeyFailuresArePrecise() throws {
    let schema = try #require(targetFanSchema())
    var wrongType = fanValues(schema: schema, actual: [2_000, 2_100], maximum: [7_800, 7_900])
    wrongType["F0Ac"] = .success(.init(key: "F0Ac", dataType: "sp78", bytes: fanFloatBytes(2_000)))
    let wrongTypeMetric = FanReader(schema: schema, reader: FanFakeSMCReader(values: wrongType)).read()
    #expect(wrongTypeMetric.error == .unexpectedType("F0Ac"))

    var wrongKey = fanValues(schema: schema, actual: [2_000, 2_100], maximum: [7_800, 7_900])
    wrongKey["F0Ac"] = .success(.init(key: "F9Ac", dataType: "flt ", bytes: fanFloatBytes(2_000)))
    let wrongKeyMetric = FanReader(schema: schema, reader: FanFakeSMCReader(values: wrongKey)).read()
    #expect(wrongKeyMetric.error == .missingExpectedKey("F0Ac"))

    var missing = fanValues(schema: schema, actual: [2_000, 2_100], maximum: [7_800, 7_900])
    missing.removeValue(forKey: "F1Ac")
    let missingMetric = FanReader(schema: schema, reader: FanFakeSMCReader(values: missing)).read()
    #expect(missingMetric.error == .missingExpectedKey("F1Ac"))
}

@Test func connectionFailureIsDistinguishedFromFanLocalFailure() throws {
    let schema = try #require(targetFanSchema())
    var values = fanValues(schema: schema, actual: [2_000, 2_100], maximum: [7_800, 7_900])
    values["F0Ac"] = .failure(SMCError.call)

    let metric = FanReader(schema: schema, reader: FanFakeSMCReader(values: values)).read()

    #expect(metric.error == .readFailed)
}

@Test func alteredFanSchemaFailsBeforeAnySMCRead() throws {
    let valid = try #require(targetFanSchema())
    let altered = PrivateMetricSchema(
        model: valid.model,
        osBuild: valid.osBuild,
        cpuTemperatureKeys: valid.cpuTemperatureKeys,
        gpuTemperatureKeys: valid.gpuTemperatureKeys,
        gpuUtilizationKey: valid.gpuUtilizationKey,
        fanCountKey: "Bad!",
        expectedFanCount: valid.expectedFanCount,
        fanKeys: valid.fanKeys
    )
    let reader = FanFakeSMCReader(values: [:])

    let metric = FanReader(schema: altered, reader: reader).read()

    #expect(metric.error == .unsupportedPrivateMetricSchema)
    #expect(reader.requestedKeys.isEmpty)
}

@Suite("FanLiveTests", .enabled(if: ProcessInfo.processInfo.environment["THERMOBAR_RUN_LIVE_SENSORS"] == "1"))
struct FanLiveTests {
    @Test func targetFansAreCompleteAndValid() throws {
        let model = try fanSysctlString(named: "hw.model")
        let build = try fanSysctlString(named: "kern.osversion")
        let schema = try #require(PrivateMetricSchemaRegistry.schema(model: model, build: build))
        let client = try SMCClient()
        defer { client.close() }

        let metric = FanReader(schema: schema, reader: client).read()

        #expect(metric.fastestRPM != nil)
        #expect(metric.fastestMaximumRPM != nil)
        #expect(metric.validatedFanCount == 2)
        #expect(metric.error == nil)
    }
}

private func targetFanSchema() -> PrivateMetricSchema? {
    PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5388g")
}

private func fanValues(
    schema: PrivateMetricSchema,
    actual: [Double],
    maximum: [Double]
) -> [String: Result<SMCValue, any Error>] {
    var values: [String: Result<SMCValue, any Error>] = [
        schema.fanCountKey: .success(.init(
            key: schema.fanCountKey,
            dataType: "ui8 ",
            bytes: [UInt8(schema.expectedFanCount)]
        ))
    ]
    for (index, keys) in schema.fanKeys.enumerated() {
        values[keys.actualKey] = .success(.init(
            key: keys.actualKey,
            dataType: "flt ",
            bytes: fanFloatBytes(actual[index])
        ))
        values[keys.maximumKey] = .success(.init(
            key: keys.maximumKey,
            dataType: "flt ",
            bytes: fanFloatBytes(maximum[index])
        ))
    }
    return values
}

private func fanFloatBytes(_ value: Double) -> [UInt8] {
    let bits = Float(value).bitPattern
    return [
        UInt8(truncatingIfNeeded: bits),
        UInt8(truncatingIfNeeded: bits >> 8),
        UInt8(truncatingIfNeeded: bits >> 16),
        UInt8(truncatingIfNeeded: bits >> 24)
    ]
}

private final class FanFakeSMCReader: SMCReading, @unchecked Sendable {
    private let lock = NSLock()
    private let values: [String: Result<SMCValue, any Error>]
    private var requests: [String] = []

    init(values: [String: Result<SMCValue, any Error>]) {
        self.values = values
    }

    var requestedKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func read(key: String) throws -> SMCValue {
        lock.lock()
        requests.append(key)
        let result = values[key]
        lock.unlock()
        guard let result else { throw FanFakeReadError.missing }
        return try result.get()
    }

    func close() {}
}

private enum FanFakeReadError: Error { case missing }

private func fanSysctlString(named name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        throw FanProbeError.failed
    }
    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        throw FanProbeError.failed
    }
    return String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
}

private enum FanProbeError: Error { case failed }
