import Testing
@testable import ThermoBarCore

@Test func exactTargetSchemaIsSupported() {
    #expect(PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5388g") != nil)
}

@Test(arguments: [("Mac17,8", "26A5388g"), ("Mac17,9", "26A5389a"), ("", "")])
func unmatchedPairsAreRejected(pair: (String, String)) {
    #expect(PrivateMetricSchemaRegistry.schema(model: pair.0, build: pair.1) == nil)
}

@Test func memoryMetricIsAtomic() {
    let memory = MemoryMetric(usedBytes: 3_112_960, totalBytes: 8_388_608)
    #expect(memory.usedFraction == 0.37109375)
}
