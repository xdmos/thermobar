import Testing
@testable import ThermoBarCore

@Test func firstReadingMeasuresCPUAndRanksMemory() {
    var calculator = ResourceConsumerCalculator()
    let result = calculator.consume(.init(monotonicNanoseconds: 100, records: [record(1, "A", 10, 30)]))
    #expect(result.cpu == .measuring)
    #expect(result.memory == .available([.init(pid: 1, name: "A", physicalFootprintBytes: 30)]))
}

@Test func intervalRanksAndPreservesMulticoreValues() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [record(1, "same", 10, 3), record(2, "Alpha", 10, 4), record(3, "Ż", 10, 2), record(4, "same", 10, 1)]))
    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [record(1, "same", 400, 3), record(2, "Alpha", 400, 4), record(3, "Ż", 20, 2), record(4, "same", 400, 1)]))
    guard case let .available(rows) = result.cpu else { Issue.record(); return }
    #expect(rows.map(\.pid) == [2, 1, 4]); #expect(rows[0].percent == 390)
}

@Test func calculatorRanksCombinedConsumersByGPUThenCPU() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(1, "CPU heavy", 10, 1, gpu: 100),
        record(2, "Local model", 10, 1, gpu: 100),
        record(3, "Neither", 10, 1, gpu: nil)
    ]))

    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(1, "CPU heavy", 90, 1, gpu: 110),
        record(2, "Local model", 30, 1, gpu: 180),
        record(3, "Neither", 20, 1, gpu: nil)
    ]))

    guard case let .available(rows) = result.cpu else { Issue.record(); return }
    #expect(rows == [
        .init(pid: 2, name: "Local model", percent: 20, gpuPercent: 80),
        .init(pid: 1, name: "CPU heavy", percent: 80, gpuPercent: 10),
        .init(pid: 3, name: "Neither", percent: 10, gpuPercent: nil)
    ])
}

@Test func calculatorAggregatesCPUAndMemoryByApplicationGroup() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(7, "Google Chrome", 10, 30, gpu: 100, group: "app:/Applications/Google Chrome.app"),
        record(3, "Google Chrome", 20, 40, gpu: 200, group: "app:/Applications/Google Chrome.app"),
        record(8, "ChatGPT", 10, 60, group: "app:/Applications/ChatGPT.app")
    ]))
    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(7, "Google Chrome", 110, 50, gpu: 150, group: "app:/Applications/Google Chrome.app"),
        record(3, "Google Chrome", 220, 70, gpu: 250, group: "app:/Applications/Google Chrome.app"),
        record(8, "ChatGPT", 110, 60, group: "app:/Applications/ChatGPT.app")
    ]))
    #expect(result.memory == .available([.init(pid: 3, name: "Google Chrome", physicalFootprintBytes: 120), .init(pid: 8, name: "ChatGPT", physicalFootprintBytes: 60)]))
    #expect(result.cpu == .available([.init(pid: 3, name: "Google Chrome", percent: 300, gpuPercent: 100), .init(pid: 8, name: "ChatGPT", percent: 100)]))
}

@Test func calculatorSeparatesGroupsWithTheSameDisplayNameAndGroupsStandaloneExecutables() {
    var calculator = ResourceConsumerCalculator()
    let reading = ConsumerUsageReading(monotonicNanoseconds: 1, records: [
        record(2, "worker", 0, 3, group: "exe:/usr/local/bin/worker"),
        record(3, "worker", 0, 5, group: "exe:/usr/local/bin/worker"),
        record(1, "worker", 0, 4, group: "exe:/opt/tools/worker")
    ])
    #expect(calculator.consume(reading).memory == .available([.init(pid: 2, name: "worker", physicalFootprintBytes: 8), .init(pid: 1, name: "worker", physicalFootprintBytes: 4)]))
}

@Test func calculatorBreaksEqualResourceAndNameTiesByGroupID() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [
        record(1, "worker", 0, 4, group: "exe:/z/worker"),
        record(2, "worker", 0, 4, group: "exe:/a/worker")
    ]))
    let result = calculator.consume(.init(monotonicNanoseconds: 20, records: [
        record(1, "worker", 10, 4, group: "exe:/z/worker"),
        record(2, "worker", 10, 4, group: "exe:/a/worker")
    ]))
    guard case let .available(memory) = result.memory, case let .available(cpu) = result.cpu else { Issue.record(); return }
    #expect(memory.map(\.pid) == [2, 1])
    #expect(cpu.map(\.pid) == [2, 1])
}

@Test func calculatorTreatsChangedGroupForSamePIDAndStartAsFreshBaseline() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "One", 100, 1, group: "app:/One.app")]))
    #expect(calculator.consume(.init(monotonicNanoseconds: 20, records: [record(1, "Two", 200, 1, group: "app:/Two.app")])).cpu == .measuring)
    guard case let .available(rows) = calculator.consume(.init(monotonicNanoseconds: 30, records: [record(1, "Two", 300, 1, group: "app:/Two.app")])).cpu else { Issue.record(); return }
    #expect(rows == [.init(pid: 1, name: "Two", percent: 1_000)])
}

@Test func calculatorUsesSmallestCurrentGroupPIDWhenOnlyAnotherMemberHasCPUDelta() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(9, "Google Chrome", 100, 1, group: "app:/Applications/Google Chrome.app")]))
    let result = calculator.consume(.init(monotonicNanoseconds: 20, records: [
        record(2, "Google Chrome", 50, 1, group: "app:/Applications/Google Chrome.app"),
        record(9, "Google Chrome", 200, 1, group: "app:/Applications/Google Chrome.app")
    ]))
    #expect(result.cpu == .available([.init(pid: 2, name: "Google Chrome", percent: 1_000)]))
}

@Test func calculatorRejectsConflictingNamesAndIsolatesSectionOverflows() {
    var calculator = ResourceConsumerCalculator()
    let conflicting = ConsumerUsageReading(monotonicNanoseconds: 1, records: [record(1, "A", 0, 1, group: "app:/Same.app"), record(2, "B", 0, 1, group: "app:/Same.app")])
    #expect(calculator.consume(conflicting) == .init(cpu: .unavailable, memory: .unavailable))

    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "A", 0, .max, group: "app:/A.app"), record(2, "A", 0, 1, group: "app:/A.app")]))
    let memoryOverflow = calculator.consume(.init(monotonicNanoseconds: 20, records: [record(1, "A", 10, .max, group: "app:/A.app"), record(2, "A", 10, 1, group: "app:/A.app")]))
    #expect(memoryOverflow.memory == .unavailable)
    #expect(memoryOverflow.cpu == .available([.init(pid: 1, name: "A", percent: 200)]))

    _ = calculator.consume(.init(monotonicNanoseconds: 30, records: [record(1, "A", 0, 1, group: "app:/A.app"), record(2, "A", 0, 1, group: "app:/A.app")]))
    let cpuOverflow = calculator.consume(.init(monotonicNanoseconds: 40, records: [record(1, "A", .max, 1, group: "app:/A.app"), record(2, "A", 1, 1, group: "app:/A.app")]))
    #expect(cpuOverflow.cpu == .unavailable)
    #expect(cpuOverflow.memory == .available([.init(pid: 1, name: "A", physicalFootprintBytes: 2)]))
    guard case let .available(recovered) = calculator.consume(.init(monotonicNanoseconds: 50, records: [record(1, "A", .max, 1, group: "app:/A.app"), record(2, "A", 2, 1, group: "app:/A.app")])).cpu else { Issue.record(); return }
    #expect(recovered == [.init(pid: 1, name: "A", percent: 10)])
}

@Test func badIntervalsAndFailuresClearBaseline() {
    var calculator = ResourceConsumerCalculator(); _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "A", 10, 1)]))
    #expect(calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "A", 20, 1)])).cpu == .measuring)
    #expect(calculator.consume(nil) == .init(cpu: .unavailable, memory: .unavailable))
    #expect(calculator.reset() == .inactive)
}

@Test func calculatorHandlesPIDReuseRegressionDuplicatesAndRecovery() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "same", 100, 1)]))
    #expect(calculator.consume(.init(monotonicNanoseconds: 20, records: [record(1, "same", 50, 1)])).cpu == .measuring)
    #expect(calculator.consume(.init(monotonicNanoseconds: 30, records: [record(1, "new", 100, 1, start: 2)])).cpu == .measuring)
    #expect(calculator.consume(.init(monotonicNanoseconds: 40, records: [record(1, "new", 300, 1, start: 2), record(1, "duplicate", 400, 2)])).cpu == .unavailable)
    let recovered = calculator.consume(.init(monotonicNanoseconds: 50, records: [record(1, "new", 500, 1, start: 2)]))
    #expect(recovered.cpu == .measuring)
    guard case let .available(rows) = calculator.consume(.init(monotonicNanoseconds: 60, records: [record(1, "new", 800, 1, start: 2)])).cpu else { Issue.record(); return }
    #expect(rows.count == 1)
}

@Test func calculatorKeepsOneTwoAndThreeSortedRows() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 1, records: [record(1, "Ż", 0, 1), record(2, "A", 0, 2), record(3, "A", 0, 3), record(4, "B", 0, 4)]))
    let metric = calculator.consume(.init(monotonicNanoseconds: 101, records: [record(1, "Ż", 100, 1), record(2, "A", 400, 2), record(3, "A", 400, 3), record(4, "B", 300, 4)]))
    guard case let .available(rows) = metric.cpu else { Issue.record(); return }
    #expect(rows.map(\.pid) == [2, 3, 4])
}

private func record(_ pid: Int32, _ name: String, _ cpu: UInt64, _ memory: UInt64, gpu: UInt64? = nil, start: UInt64 = 1, group: String? = nil) -> ConsumerUsageRecord { .init(pid: pid, startTime: start, groupID: group ?? "pid:\(pid):\(start)", name: name, cumulativeCPUTimeNanoseconds: cpu, physicalFootprintBytes: memory, cumulativeGPUTimeNanoseconds: gpu) }
