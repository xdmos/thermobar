import Testing
@testable import ThermoBarCore

@Test func exactTargetSchemaIsSupported() {
    #expect(PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5388g") != nil)
}

@Test func updatedExactTargetSchemaIsSupported() {
    let schema = PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5406e")

    #expect(schema?.osBuild == "26A5406e")
}

@Test(arguments: [
    ("Mac17,8", "26A5388g"),
    ("Mac17,9", "26A5388f"),
    ("Mac17,9", "26A5388h"),
    ("Mac17,9", "26A5406d"),
    ("Mac17,9", "26A5406f"),
    ("Mac17,9", "26A5406e "),
    ("", "")
])
func unmatchedPairsAreRejected(pair: (String, String)) {
    #expect(PrivateMetricSchemaRegistry.schema(model: pair.0, build: pair.1) == nil)
}

@Test func memoryMetricIsAtomic() {
    let memory = MemoryMetric(usedBytes: 3_112_960, totalBytes: 8_388_608)
    #expect(memory.usedFraction == 0.37109375)
}
