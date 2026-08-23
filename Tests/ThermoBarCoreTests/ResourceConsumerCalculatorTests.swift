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
    #expect(rows.map(\.pid) == [2, 1, 4, 3]); #expect(rows[0].percent == 390)
}

@Test func calculatorBreaksEqualComputeLoadTiesByHigherCPU() {
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
        .init(pid: 1, name: "CPU heavy", percent: 80, gpuPercent: 10),
        .init(pid: 2, name: "Local model", percent: 20, gpuPercent: 80),
        .init(pid: 3, name: "Neither", percent: 10, gpuPercent: nil)
    ])
}

@Test func calculatorRanksGPUHeavyProcessAheadOfHigherCPUProcesses() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(1, "CPU moderate", 0, 1, gpu: 0),
        record(2, "GPU heavy", 0, 1, gpu: 0),
        record(3, "CPU high", 0, 1, gpu: 0)
    ]))

    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(1, "CPU moderate", 60, 1, gpu: 10),
        record(2, "GPU heavy", 10, 1, gpu: 90),
        record(3, "CPU high", 80, 1, gpu: 5)
    ]))

    guard case let .available(rows) = result.cpu else { Issue.record(); return }
    #expect(rows.map(\.pid) == [2, 3, 1])
}

@Test func calculatorUsesComputeLoadForTheFiveProcessComposition() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(1, "One", 0, 1), record(2, "Two", 0, 1), record(3, "Three", 0, 1),
        record(4, "Four", 0, 1), record(5, "Five", 0, 1), record(6, "GPU heavy", 0, 1, gpu: 0)
    ]))

    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(1, "One", 90, 1), record(2, "Two", 80, 1), record(3, "Three", 70, 1),
        record(4, "Four", 60, 1), record(5, "Five", 50, 1), record(6, "GPU heavy", 10, 1, gpu: 95)
    ]))

    guard case let .available(rows) = result.cpu else { Issue.record(); return }
    #expect(rows.map(\.pid) == [6, 1, 2, 3, 4])
}

@Test func calculatorKeepsCPUAndGPUPerProcessWhileAggregatingMemoryByApplication() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 100, records: [
        record(7, "Google Chrome", 10, 30, gpu: 100, group: "app:/Applications/Google Chrome.app", processName: "Google Chrome Helper"),
        record(3, "Google Chrome", 20, 40, gpu: 200, group: "app:/Applications/Google Chrome.app", processName: "Google Chrome Helper (Renderer)"),
        record(8, "ChatGPT", 10, 60, group: "app:/Applications/ChatGPT.app")
    ]))
    let result = calculator.consume(.init(monotonicNanoseconds: 200, records: [
        record(7, "Google Chrome", 110, 50, gpu: 150, group: "app:/Applications/Google Chrome.app", processName: "Google Chrome Helper"),
        record(3, "Google Chrome", 220, 70, gpu: 250, group: "app:/Applications/Google Chrome.app", processName: "Google Chrome Helper (Renderer)"),
        record(8, "ChatGPT", 110, 60, group: "app:/Applications/ChatGPT.app")
    ]))
    #expect(result.memory == .available([.init(pid: 3, name: "Google Chrome", physicalFootprintBytes: 120), .init(pid: 8, name: "ChatGPT", physicalFootprintBytes: 60)]))
    #expect(result.cpu == .available([
        .init(pid: 3, name: "Google Chrome Helper (Renderer)", percent: 200, gpuPercent: 50),
        .init(pid: 8, name: "ChatGPT", percent: 100),
        .init(pid: 7, name: "Google Chrome Helper", percent: 100, gpuPercent: 50)
    ]))
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

@Test func calculatorShowsTheFiveLargestMemoryApplicationGroups() {
    var calculator = ResourceConsumerCalculator()
    let result = calculator.consume(.init(monotonicNanoseconds: 1, records: [
        record(1, "One", 0, 60, group: "app:/One.app"), record(2, "Two", 0, 50, group: "app:/Two.app"),
        record(3, "Three", 0, 40, group: "app:/Three.app"), record(4, "Four", 0, 30, group: "app:/Four.app"),
        record(5, "Five", 0, 20, group: "app:/Five.app"), record(6, "Six", 0, 10, group: "app:/Six.app")
    ]))
    guard case let .available(rows) = result.memory else { Issue.record(); return }
    #expect(rows.count == 5)
    #expect(rows.map(\.pid) == [1, 2, 3, 4, 5])
    #expect(rows.map(\.physicalFootprintBytes) == [60, 50, 40, 30, 20])
}

@Test func calculatorUsesGroupIDForMemoryAndPIDForComputeTies() {
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
    #expect(cpu.map(\.pid) == [1, 2])
}

@Test func calculatorTreatsChangedGroupForSamePIDAndStartAsFreshBaseline() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "One", 100, 1, group: "app:/One.app")]))
    #expect(calculator.consume(.init(monotonicNanoseconds: 20, records: [record(1, "Two", 200, 1, group: "app:/Two.app")])).cpu == .measuring)
    guard case let .available(rows) = calculator.consume(.init(monotonicNanoseconds: 30, records: [record(1, "Two", 300, 1, group: "app:/Two.app")])).cpu else { Issue.record(); return }
    #expect(rows == [.init(pid: 1, name: "Two", percent: 1_000)])
}

@Test func calculatorUsesThePIDThatProducedTheCPUDelta() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(9, "Google Chrome", 100, 1, group: "app:/Applications/Google Chrome.app")]))
    let result = calculator.consume(.init(monotonicNanoseconds: 20, records: [
        record(2, "Google Chrome", 50, 1, group: "app:/Applications/Google Chrome.app"),
        record(9, "Google Chrome", 200, 1, group: "app:/Applications/Google Chrome.app")
    ]))
    #expect(result.cpu == .available([.init(pid: 9, name: "Google Chrome", percent: 1_000)]))
}

@Test func calculatorRejectsConflictingNamesAndIsolatesMemoryOverflows() {
    var calculator = ResourceConsumerCalculator()
    let conflicting = ConsumerUsageReading(monotonicNanoseconds: 1, records: [record(1, "A", 0, 1, group: "app:/Same.app"), record(2, "B", 0, 1, group: "app:/Same.app")])
    #expect(calculator.consume(conflicting) == .init(cpu: .unavailable, memory: .unavailable))

    _ = calculator.consume(.init(monotonicNanoseconds: 10, records: [record(1, "A", 0, .max, group: "app:/A.app"), record(2, "A", 0, 1, group: "app:/A.app")]))
    let memoryOverflow = calculator.consume(.init(monotonicNanoseconds: 20, records: [record(1, "A", 10, .max, group: "app:/A.app"), record(2, "A", 10, 1, group: "app:/A.app")]))
    #expect(memoryOverflow.memory == .unavailable)
    #expect(memoryOverflow.cpu == .available([.init(pid: 1, name: "A", percent: 100), .init(pid: 2, name: "A", percent: 100)]))
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

@Test func calculatorShowsTheFiveHighestCPUProcesses() {
    var calculator = ResourceConsumerCalculator()
    _ = calculator.consume(.init(monotonicNanoseconds: 1, records: [record(1, "Ż", 0, 1), record(2, "A", 0, 2), record(3, "A", 0, 3), record(4, "B", 0, 4), record(5, "C", 0, 5), record(6, "D", 0, 6)]))
    let metric = calculator.consume(.init(monotonicNanoseconds: 101, records: [record(1, "Ż", 100, 1), record(2, "A", 400, 2), record(3, "A", 400, 3), record(4, "B", 300, 4), record(5, "C", 200, 5), record(6, "D", 100, 6)]))
    guard case let .available(rows) = metric.cpu else { Issue.record(); return }
    #expect(rows.map(\.pid) == [2, 3, 4, 5, 6])
}

private func record(_ pid: Int32, _ name: String, _ cpu: UInt64, _ memory: UInt64, gpu: UInt64? = nil, start: UInt64 = 1, group: String? = nil, processName: String? = nil) -> ConsumerUsageRecord { .init(pid: pid, startTime: start, groupID: group ?? "pid:\(pid):\(start)", name: name, processName: processName, cumulativeCPUTimeNanoseconds: cpu, physicalFootprintBytes: memory, cumulativeGPUTimeNanoseconds: gpu) }
