import Darwin
import Foundation
import Testing
@testable import ThermoBarCore

@Test func completeFixedSchemaAggregatesTemperatures() {
    let schema = targetSchema()
    let reader = FakeSMCReader(values: validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius))

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == 50)
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.chipHotspotCelsius == 50)
    #expect(result.cpuError == nil)
    #expect(result.gpuError == nil)
    #expect(reader.requestedKeys == schema.cpuTemperatureKeys + schema.gpuTemperatureKeys)
}

@Test func missingCPUKeyInvalidatesOnlyCPUAndHotspot() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values.removeValue(forKey: "Tp00")
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == .missingExpectedKey("Tp00"))
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(reader.requestedKeys == ["Tp00"] + schema.gpuTemperatureKeys)
}

@Test func missingGPUKeyInvalidatesOnlyGPUAndHotspot() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values.removeValue(forKey: "Tg0U")
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == 50)
    #expect(result.cpuError == nil)
    #expect(result.gpuAverageCelsius == nil)
    #expect(result.gpuError == .missingExpectedKey("Tg0U"))
    #expect(result.chipHotspotCelsius == nil)
    #expect(reader.requestedKeys == schema.cpuTemperatureKeys + ["Tg0U"])
}

@Test func cpuKeyUnavailablePreservesGPU() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .failure(SMCError.keyUnavailable)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == .missingExpectedKey("Tp00"))
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(reader.requestedKeys == ["Tp00"] + schema.gpuTemperatureKeys)
}

@Test func gpuKeyUnavailablePreservesCPU() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tg0U"] = .failure(SMCError.keyUnavailable)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == 50)
    #expect(result.cpuError == nil)
    #expect(result.gpuAverageCelsius == nil)
    #expect(result.gpuError == .missingExpectedKey("Tg0U"))
    #expect(result.chipHotspotCelsius == nil)
    #expect(reader.requestedKeys == schema.cpuTemperatureKeys + ["Tg0U"])
}

@Test(arguments: [SMCError.invalidSize, .invalidDataType, .invalidResponse])
func perKeySMCMetadataFailureIsLocal(input: SMCError) {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .failure(input)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == .unexpectedType("Tp00"))
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
    #expect(result.chipHotspotCelsius == nil)
}

@Test func callValidationDistinguishesTransportAndShortResponses() {
    let expectedSize = MemoryLayout<SMCKeyData>.size

    #expect(smcError {
        try SMCClient.validateCallResult(result: KERN_FAILURE, outputSize: expectedSize)
    } == .call)
    #expect(smcError {
        try SMCClient.validateCallResult(result: KERN_SUCCESS, outputSize: expectedSize - 1)
    } == .invalidResponse)
    #expect(smcError {
        try SMCClient.validateCallResult(result: KERN_SUCCESS, outputSize: expectedSize + 1)
    } == .invalidResponse)
    #expect(smcError {
        try SMCClient.validateCallResult(result: KERN_SUCCESS, outputSize: expectedSize)
    } == nil)
}

@Test(arguments: [
    ("wrong data type", SMCValue(key: "Tp00", dataType: "sp78", bytes: fiftyCelsius), MetricError.unexpectedType("Tp00")),
    ("wrong byte count", SMCValue(key: "Tp00", dataType: "flt ", bytes: [0x00, 0x00, 0x48]), MetricError.unexpectedType("Tp00"))
])
func malformedCPUReadingInvalidatesOnlyCPU(input: (String, SMCValue, MetricError)) {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .success(input.1)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == input.2)
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(reader.requestedKeys == ["Tp00"] + schema.gpuTemperatureKeys)
}

@Test(arguments: [
    ("NaN", [UInt8](arrayLiteral: 0x00, 0x00, 0xC0, 0x7F)),
    ("above range", [UInt8](arrayLiteral: 0x00, 0x00, 0xE8, 0x42))
])
func invalidCPUValueInvalidatesOnlyCPU(input: (String, [UInt8])) {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .success(SMCValue(key: "Tp00", dataType: "flt ", bytes: input.1))
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == .invalidValue)
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
    #expect(result.chipHotspotCelsius == nil)
}

@Test func aggregatesExactAveragesAndIndividualHotspot() {
    let schema = targetSchema()
    let cpuBytes: [[UInt8]] = [
        [0x00, 0x00, 0x20, 0x42], [0x00, 0x00, 0x24, 0x42], [0x00, 0x00, 0x28, 0x42],
        [0x00, 0x00, 0x2C, 0x42], [0x00, 0x00, 0x30, 0x42], [0x00, 0x00, 0x34, 0x42],
        [0x00, 0x00, 0x38, 0x42], [0x00, 0x00, 0x3C, 0x42], [0x00, 0x00, 0x40, 0x42],
        [0x00, 0x00, 0x44, 0x42], [0x00, 0x00, 0x48, 0x42], [0x00, 0x00, 0x4C, 0x42],
        [0x00, 0x00, 0x50, 0x42], [0x00, 0x00, 0x54, 0x42], [0x00, 0x00, 0x58, 0x42],
        [0x00, 0x00, 0x5C, 0x42], [0x00, 0x00, 0x60, 0x42], [0x00, 0x00, 0xBA, 0x42]
    ]
    let gpuBytes: [[UInt8]] = [
        [0x00, 0x00, 0x34, 0x42], [0x00, 0x00, 0x38, 0x42], [0x00, 0x00, 0x3C, 0x42],
        [0x00, 0x00, 0x40, 0x42], [0x00, 0x00, 0x44, 0x42], [0x00, 0x00, 0x48, 0x42],
        [0x00, 0x00, 0x4C, 0x42]
    ]
    var values: [String: Result<SMCValue, any Error>] = [:]
    for (key, bytes) in zip(schema.cpuTemperatureKeys, cpuBytes) {
        values[key] = .success(SMCValue(key: key, dataType: "flt ", bytes: bytes))
    }
    for (key, bytes) in zip(schema.gpuTemperatureKeys, gpuBytes) {
        values[key] = .success(SMCValue(key: key, dataType: "flt ", bytes: bytes))
    }
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == 50.5)
    #expect(result.gpuAverageCelsius == 48)
    #expect(result.chipHotspotCelsius == 93)
    #expect(result.cpuError == nil)
    #expect(result.gpuError == nil)
}

@Test(arguments: [SMCError.call, .closed])
func connectionFailureInvalidatesBothGroups(input: SMCError) {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .failure(input)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.gpuAverageCelsius == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(result.cpuError == .readFailed)
    #expect(result.gpuError == .readFailed)
    #expect(reader.requestedKeys == ["Tp00"])
}

@Test func connectionFailureInGPUInvalidatesAlreadyReadCPU() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tg0U"] = .failure(SMCError.call)
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.gpuAverageCelsius == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(result.cpuError == .readFailed)
    #expect(result.gpuError == .readFailed)
    #expect(reader.requestedKeys == schema.cpuTemperatureKeys + ["Tg0U"])
}

@Test func emptyTemperatureSchemaFailsBeforeSMCRead() {
    let valid = targetSchema()
    let schema = PrivateMetricSchema(
        model: valid.model,
        osBuild: valid.osBuild,
        cpuTemperatureKeys: [],
        gpuTemperatureKeys: valid.gpuTemperatureKeys,
        gpuUtilizationKey: valid.gpuUtilizationKey
    )

    assertUnsupportedSchema(schema)
}

@Test func duplicateTemperatureKeyFailsBeforeSMCRead() {
    let valid = targetSchema()
    let schema = PrivateMetricSchema(
        model: valid.model,
        osBuild: valid.osBuild,
        cpuTemperatureKeys: ["Tp00", "Tp00"] + Array(valid.cpuTemperatureKeys.dropFirst(2)),
        gpuTemperatureKeys: valid.gpuTemperatureKeys,
        gpuUtilizationKey: valid.gpuUtilizationKey
    )

    assertUnsupportedSchema(schema)
}

@Test func crossGroupTemperatureKeyFailsBeforeSMCRead() {
    let valid = targetSchema()
    let schema = PrivateMetricSchema(
        model: valid.model,
        osBuild: valid.osBuild,
        cpuTemperatureKeys: valid.cpuTemperatureKeys,
        gpuTemperatureKeys: ["Tp00"] + Array(valid.gpuTemperatureKeys.dropFirst()),
        gpuUtilizationKey: valid.gpuUtilizationKey
    )

    assertUnsupportedSchema(schema)
}

@Test func onlySchemaKeysAreRequestedAndFailedGroupStopsAtFirstFailure() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp04"] = .failure(FakeReadError.missing)
    values["not-a-schema-key"] = .success(SMCValue(key: "not-a-schema-key", dataType: "flt ", bytes: fiftyCelsius))
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuError == .missingExpectedKey("Tp04"))
    #expect(result.gpuError == nil)
    #expect(reader.requestedKeys == ["Tp00", "Tp04"] + schema.gpuTemperatureKeys)
    #expect(!reader.requestedKeys.contains("not-a-schema-key"))
}

@Test func mismatchedReturnedKeyFailsClosedAsMissingExpectedKey() {
    let schema = targetSchema()
    var values = validValues(schema: schema, cpuBytes: fiftyCelsius, gpuBytes: fortyFiveCelsius)
    values["Tp00"] = .success(SMCValue(key: "Tg0U", dataType: "flt ", bytes: fiftyCelsius))
    let reader = FakeSMCReader(values: values)

    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.cpuError == .missingExpectedKey("Tp00"))
    #expect(result.gpuAverageCelsius == 45)
    #expect(result.gpuError == nil)
}

@Suite("TemperatureLiveTests", .enabled(if: ProcessInfo.processInfo.environment["THERMOBAR_RUN_LIVE_SENSORS"] == "1"))
struct TemperatureLiveTests {
    @Test func targetSMCTemperaturesAreCompleteAndValid() throws {
        let model = try sysctlString(named: "hw.model")
        let build = try sysctlString(named: "kern.osversion")
        let schema = try #require(PrivateMetricSchemaRegistry.schema(model: model, build: build))
        let client = try SMCClient()
        defer { client.close() }

        let metric = TemperatureReader(schema: schema, reader: client).read()

        #expect(metric.cpuAverageCelsius != nil)
        #expect(metric.gpuAverageCelsius != nil)
        #expect(metric.chipHotspotCelsius != nil)
        #expect(metric.cpuError == nil)
        #expect(metric.gpuError == nil)
    }
}

private let fiftyCelsius: [UInt8] = [0x00, 0x00, 0x48, 0x42]
private let fortyFiveCelsius: [UInt8] = [0x00, 0x00, 0x34, 0x42]

private func targetSchema() -> PrivateMetricSchema {
    PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5388g")!
}

private func validValues(
    schema: PrivateMetricSchema,
    cpuBytes: [UInt8],
    gpuBytes: [UInt8]
) -> [String: Result<SMCValue, any Error>] {
    var values: [String: Result<SMCValue, any Error>] = [:]
    for key in schema.cpuTemperatureKeys {
        values[key] = .success(SMCValue(key: key, dataType: "flt ", bytes: cpuBytes))
    }
    for key in schema.gpuTemperatureKeys {
        values[key] = .success(SMCValue(key: key, dataType: "flt ", bytes: gpuBytes))
    }
    return values
}

private func assertUnsupportedSchema(_ schema: PrivateMetricSchema) {
    let reader = FakeSMCReader(values: [:])
    let result = TemperatureReader(schema: schema, reader: reader).read()

    #expect(result.cpuAverageCelsius == nil)
    #expect(result.gpuAverageCelsius == nil)
    #expect(result.chipHotspotCelsius == nil)
    #expect(result.cpuError == .unsupportedPrivateMetricSchema)
    #expect(result.gpuError == .unsupportedPrivateMetricSchema)
    #expect(reader.requestedKeys.isEmpty)
}

private func smcError(_ operation: () throws -> Void) -> SMCError? {
    do {
        try operation()
        return nil
    } catch let error as SMCError {
        return error
    } catch {
        return nil
    }
}

private enum FakeReadError: Error {
    case missing
}

private final class FakeSMCReader: SMCReading, @unchecked Sendable {
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

        guard let result else {
            throw FakeReadError.missing
        }
        return try result.get()
    }

    func close() {}
}

private func sysctlString(named name: String) throws -> String {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else {
        throw SysctlError.readFailed
    }

    var buffer = [CChar](repeating: 0, count: size)
    guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
        throw SysctlError.readFailed
    }
    let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
    return String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

private enum SysctlError: Error {
    case readFailed
}
