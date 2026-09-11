import Testing
@testable import ThermoBarCore

@Test(arguments: [
    "26A5388g",
    "26A5406e",
    "26A5416b",
    "26A5421a",
    "26A5425a"
])
func supportedModelIsAcceptedOnEveryVerifiedBuild(build: String) {
    let schema = PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: build)

    #expect(schema?.osBuild == build)
}

@Test func supportedModelIsAcceptedOnAnUnseenBuild() {
    let schema = PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "27B9999z")

    #expect(schema?.osBuild == "27B9999z")
    #expect(schema?.cpuTemperatureKeys.first == "Tp00")
    #expect(schema?.expectedFanCount == 2)
}

@Test(arguments: [
    ("Mac17,8", "26A5425a"),
    ("Mac16,9", "26A5425a"),
    ("mac17,9", "26A5425a"),
    ("Mac17,9 ", "26A5425a"),
    ("Mac17,9", ""),
    ("Mac17,9", "   "),
    ("", "26A5425a"),
    ("", "")
])
func unsupportedPairsAreRejected(pair: (String, String)) {
    #expect(PrivateMetricSchemaRegistry.schema(model: pair.0, build: pair.1) == nil)
}

@Test func memoryMetricIsAtomic() {
    let memory = MemoryMetric(usedBytes: 3_112_960, totalBytes: 8_388_608)
    #expect(memory.usedFraction == 0.37109375)
}
