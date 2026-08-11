import Testing
@testable import ThermoBarCore

@Test func freshnessUsesInclusiveMonotonicBoundaries() {
    let snapshot = snapshot(at: 100)
    #expect(SnapshotFreshness.isFresh(snapshot: snapshot, mode: .visible, nowNanoseconds: 6_000_000_100))
    #expect(!SnapshotFreshness.isFresh(snapshot: snapshot, mode: .visible, nowNanoseconds: 6_000_000_101))
    #expect(SnapshotFreshness.isFresh(snapshot: snapshot, mode: .menuBarOnly, nowNanoseconds: 30_000_000_100))
    #expect(!SnapshotFreshness.isFresh(snapshot: snapshot, mode: .menuBarOnly, nowNanoseconds: 30_000_000_101))
}

@Test func sleepingAndFutureSnapshotsFailClosed() {
    let value = snapshot(at: 1_000)
    #expect(!SnapshotFreshness.isFresh(snapshot: value, mode: .sleeping, nowNanoseconds: 1_000))
    #expect(!SnapshotFreshness.isFresh(snapshot: value, mode: .visible, nowNanoseconds: 999))
}

@Test func ageAPIUsesSameInclusiveBoundaries() {
    #expect(SnapshotFreshness.isFresh(ageNanoseconds: 6_000_000_000, mode: .visible))
    #expect(!SnapshotFreshness.isFresh(ageNanoseconds: 6_000_000_001, mode: .visible))
    #expect(!SnapshotFreshness.isFresh(ageNanoseconds: 0, mode: .sleeping))
}

@Test func staleDeadlineIsFirstStaleNanosecondAndSaturates() {
    #expect(SnapshotFreshness.staleDeadlineNanoseconds(snapshot: snapshot(at: 100), mode: .visible) == 6_000_000_101)
    #expect(SnapshotFreshness.staleDeadlineNanoseconds(snapshot: snapshot(at: 100), mode: .menuBarOnly) == 30_000_000_101)
    #expect(SnapshotFreshness.staleDeadlineNanoseconds(snapshot: snapshot(at: .max), mode: .visible) == .max)
    #expect(SnapshotFreshness.staleDeadlineNanoseconds(snapshot: snapshot(at: 100), mode: .sleeping) == nil)
}

private func snapshot(at timestamp: UInt64) -> SystemSnapshot {
    SystemSnapshot(monotonicNanoseconds: timestamp, cpuPercent: nil, memory: nil, gpuPercent: nil,
                   temperature: TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: nil, gpuError: nil),
                   fan: .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2),
                   thermalLevel: .nominal, publicMetricError: nil, privateMetricError: nil)
}
