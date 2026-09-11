import Testing
import Foundation
@testable import ThermoBarCore

@Test func gpuClientReaderParsesAndSumsMetalUsageForEachPID() {
    let usage = GPUClientUsageReader.parse([
        "IOUserClientCreator": "pid 42, Local Model",
        "AppUsage": [
            ["API": "Metal", "accumulatedGPUTime": 120 as NSNumber],
            ["API": "Metal", "accumulatedGPUTime": 80 as NSNumber]
        ]
    ])

    #expect(usage == .init(pid: 42, cumulativeGPUTimeNanoseconds: 200))
}

@Test func gpuClientReaderRejectsMalformedOrOverflowingClientProperties() {
    #expect(GPUClientUsageReader.parse(["IOUserClientCreator": "pid nope, Model", "AppUsage": []]) == nil)
    #expect(GPUClientUsageReader.parse(["IOUserClientCreator": "pid 42, Model", "AppUsage": [["API": "Metal", "accumulatedGPUTime": -1 as NSNumber]]]) == nil)
    #expect(GPUClientUsageReader.parse(["IOUserClientCreator": "pid 42, Model", "AppUsage": [["API": "Metal", "accumulatedGPUTime": UInt64.max as NSNumber], ["API": "Metal", "accumulatedGPUTime": 1 as NSNumber]]]) == nil)
}

@Test(.enabled(if: getenv("THERMOBAR_LIVE_GPU_CLIENT_READER") != nil))
func liveGPUClientReaderReturnsOnlyValidCountersWhenEnabled() {
    let usage = GPUClientUsageReader().read()
    #expect(!usage.isEmpty)
    #expect(usage.keys.allSatisfy { $0 > 0 })
}
