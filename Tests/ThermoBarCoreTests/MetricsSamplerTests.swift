import Foundation
import Testing
@testable import ThermoBarCore

@Test func initialModeImmediateSampleAndIdempotency() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    #expect(await sampler.mode == .sleeping)
    await sampler.setMode(.visible)
    await c.waitForWaiter()
    #expect(c.snapshot.reads == 1); #expect(c.snapshot.waiters == 1)
    await sampler.setMode(.visible)
    #expect(c.snapshot.reads == 1); #expect(c.snapshot.waiters == 1)
}

@Test func modeChangeHasOneWaiterAndSleepClosesWithoutLateSample() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter()
    await sampler.setMode(.menuBarOnly)
    await c.waitForWaiter()
    #expect(c.snapshot.reads == 2); #expect(c.snapshot.waiters == 1); #expect(c.snapshot.cancelled == 1)
    await sampler.setMode(.sleeping)
    #expect(c.snapshot.waiters == 0); #expect(c.snapshot.closed == 1); #expect(c.snapshot.reads == 2)
    c.fire()
    #expect(c.snapshot.reads == 2)
}

@Test func wakeResetsCPUAndSecondCadenceCalculates() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await sampler.setMode(.sleeping); await sampler.setMode(.visible)
    #expect((await sampler.latestSnapshot)?.cpuPercent == nil)
    await c.waitForWaiter(); c.fire(); await c.waitForReads(3)
    #expect((await sampler.latestSnapshot)?.cpuPercent == 50)
}

@Test func privateErrorAndDiagnosticsAreSourceSpecific() async {
    let c = SamplerControl(gpuFails: true); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible)
    #expect((await sampler.latestSnapshot)?.privateMetricError == .readFailed)
    #expect((await sampler.currentDiagnostics()).map(\.source) == [.gpuUtilization])
    c.setGPUFails(false); await c.waitForWaiter(); c.fire(); await c.waitForReads(2)
    #expect(await sampler.currentDiagnostics().isEmpty)
}

@Test func connectionAndLocalTemperatureFailuresHaveExactMappings() async {
    let c = SamplerControl(); c.setOpenFails(true); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible)
    #expect((await sampler.currentDiagnostics()).map(\.source) == [.smcConnection])
    #expect((await sampler.latestSnapshot)?.temperature.cpuError == .readFailed)
    c.setOpenFails(false); await c.waitForWaiter(); c.fire(); await c.waitForReads(2)
    c.setTemperatureErrors(cpu: .missingExpectedKey("Tp00"), gpu: .unexpectedType("Tg0U"))
    await c.waitForWaiter(); c.fire(); await c.waitForReads(3)
    let value = await sampler.latestSnapshot
    #expect(value?.privateMetricError == .missingExpectedKey("Tp00"))
    #expect((await sampler.currentDiagnostics()).map(\.source) == [.cpuTemperature, .gpuTemperature])
}

@Test func localFanFailureDoesNotInvalidateTemperaturesAndIsSourceSpecific() async {
    let c = SamplerControl(); c.setFanError(.missingExpectedKey("F1Ac"))
    let sampler = MetricsSampler(dependencies: c.dependencies)

    await sampler.setMode(.visible)

    let snapshot = await sampler.latestSnapshot
    #expect(snapshot?.temperature.cpuAverageCelsius == 50)
    #expect(snapshot?.temperature.gpuAverageCelsius == 45)
    #expect(snapshot?.fan.error == .missingExpectedKey("F1Ac"))
    #expect(snapshot?.privateMetricError == .missingExpectedKey("F1Ac"))
    #expect((await sampler.currentDiagnostics()).map(\.source) == [.fanSpeed])
}

@Test func fanConnectionFailureInvalidatesTheSharedSMCTransactionAndReconnects() async {
    let c = SamplerControl(); c.setFanError(.readFailed)
    let sampler = MetricsSampler(dependencies: c.dependencies)

    await sampler.setMode(.visible)

    let failed = await sampler.latestSnapshot
    #expect(failed?.temperature.cpuError == .readFailed)
    #expect(failed?.temperature.gpuError == .readFailed)
    #expect(failed?.fan.error == .readFailed)
    #expect((await sampler.currentDiagnostics()).map(\.source) == [.smcConnection])
    #expect(c.snapshot.closed == 1)

    c.setFanError(nil)
    await c.waitForWaiter(); c.fire(); await c.waitForReads(2)
    #expect((await sampler.latestSnapshot)?.fan.fastestRPM == 2_500)
    #expect(!(await sampler.currentDiagnostics()).contains { $0.source == .smcConnection })
}

@Test func failuresBecomePersistentAtThreeAndSchemaSkipsPrivateReaders() async {
    let c = SamplerControl(memoryFails: true, schema: nil); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible)
    #expect(c.snapshot.privateCalls == 0); #expect((await sampler.latestSnapshot)?.privateMetricError == .unsupportedPrivateMetricSchema)
    await c.waitForWaiter(); c.fire(); await c.waitForReads(2)
    let second = await sampler.currentDiagnostics().first { $0.source == .memory }
    #expect(second?.consecutiveFailures == 2); #expect(second?.isPersistent == false)
    await c.waitForWaiter(); c.fire(); await c.waitForReads(3)
    let memory = await sampler.currentDiagnostics().first { $0.source == .memory }
    #expect(memory?.consecutiveFailures == 3); #expect(memory?.isPersistent == true); #expect(memory?.error == .readFailed)
}

@Test func smcConnectionPersistsOnlyAfterThreeFailedTransactionsThenClears() async {
    let c = SamplerControl(); c.setTemperatureErrors(cpu: .readFailed, gpu: .readFailed)
    let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter(); c.fire(); await c.waitForReads(2)
    let second = await sampler.currentDiagnostics().first { $0.source == .smcConnection }
    #expect(second?.consecutiveFailures == 2); #expect(second?.isPersistent == false)
    await c.waitForWaiter(); c.fire(); await c.waitForReads(3)
    let third = await sampler.currentDiagnostics().first { $0.source == .smcConnection }
    #expect(third?.consecutiveFailures == 3); #expect(third?.isPersistent == true)
    c.setTemperatureErrors(cpu: nil, gpu: nil); await c.waitForWaiter(); c.fire(); await c.waitForReads(4)
    #expect(!(await sampler.currentDiagnostics()).contains { $0.source == .smcConnection })
}

@Test func concurrentIdenticalTransitionPublishesOneResultAfterRetirement() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter(); c.setPauseCancellation(true)
    let first = Task { await sampler.setMode(.menuBarOnly) }
    await c.waitForCancelled(1)
    let second = Task { await sampler.setMode(.menuBarOnly); c.markCompletion() }
    await c.waitForJoinedTransition()
    #expect(!c.snapshot.didComplete)
    c.releaseCancelled(); await first.value; await second.value; await c.waitForWaiter()
    #expect(await sampler.mode == .menuBarOnly); #expect(c.snapshot.reads == 2); #expect(c.snapshot.waiters == 1)
}

@Test func sleepingWinsOverPausedActiveTransition() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter(); c.setPauseCancellation(true)
    let menu = Task { await sampler.setMode(.menuBarOnly) }
    await c.waitForCancelled(1)
    let sleeping = Task { await sampler.setMode(.sleeping) }
    c.releaseCancelled(); await menu.value; await sleeping.value
    #expect(await sampler.mode == .sleeping); #expect(c.snapshot.reads == 1); #expect(c.snapshot.waiters == 0); #expect(c.snapshot.closed == 1)
}

@Test func latestActiveTransitionOwnsSingleLoopAfterRetirement() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter(); c.setPauseCancellation(true)
    let menu = Task { await sampler.setMode(.menuBarOnly) }
    await c.waitForCancelled(1)
    let visible = Task { await sampler.setMode(.visible) }
    c.releaseCancelled(); await menu.value; await visible.value; await c.waitForWaiter()
    #expect(await sampler.mode == .visible); #expect(c.snapshot.reads == 2); #expect(c.snapshot.waiters == 1)
}

@Test func cancelledWinningCallerStillCommitsImmediateSampleForJoinedCaller() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    await sampler.setMode(.visible); await c.waitForWaiter(); c.setPauseCancellation(true)
    let winning = Task { await sampler.setMode(.menuBarOnly) }
    await c.waitForCancelled(1)
    let joined = Task { await sampler.setMode(.menuBarOnly); c.markCompletion() }
    await c.waitForJoinedTransition(); winning.cancel(); #expect(!c.snapshot.didComplete)
    c.releaseCancelled(); await winning.value; await joined.value; await c.waitForWaiter()
    #expect(c.snapshot.reads == 2); #expect(c.snapshot.waiters == 1); #expect(await sampler.mode == .menuBarOnly)
}

@Test func activeSamplerReleasesLoopAndSMCWithoutExplicitSleep() async {
    let c = SamplerControl(); weak var weakSampler: MetricsSampler?
    do {
        var sampler: MetricsSampler? = MetricsSampler(dependencies: c.dependencies)
        weakSampler = sampler
        await sampler?.setMode(.visible)
        await c.waitForWaiter()
        sampler = nil
    }
    #expect(weakSampler == nil)
    await c.waitForCancelled(1)
    #expect(c.snapshot.waiters == 0); #expect(c.snapshot.closed == 1)
}

@Test(.timeLimit(.minutes(1))) func samplerTeardownFinishesActiveStreamConsumer() async {
    let c = SamplerControl(); weak var weakSampler: MetricsSampler?
    var sampler: MetricsSampler? = MetricsSampler(dependencies: c.dependencies); weakSampler = sampler
    let stream = await sampler!.snapshots(); let probe = StreamProbe()
    let reader = Task { var iterator = stream.makeAsyncIterator(); await probe.record(await iterator.next()); await probe.record(await iterator.next()) }
    await sampler!.setMode(.visible); await probe.waitForValues(1); await c.waitForWaiter()
    sampler = nil; await reader.value
    #expect(weakSampler == nil); #expect(await probe.values.count == 1)
}

@Test(.timeLimit(.minutes(1))) func streamDeliversExactlyTwoSnapshotsThenOldStreamFinishesOnReplacement() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    let stream = await sampler.snapshots(); let probe = StreamProbe()
    let reader = Task { var iterator = stream.makeAsyncIterator(); for _ in 0..<3 { await probe.record(await iterator.next()) } }
    await sampler.setMode(.visible); await probe.waitForValues(1)
    await c.waitForWaiter(); c.fire(); await probe.waitForValues(2)
    _ = await sampler.snapshots()
    await reader.value
    #expect(await probe.values.count == 2)
}

@Test(.timeLimit(.minutes(1))) func oldTerminationCannotClearReplacementStream() async {
    let c = SamplerControl(); let sampler = MetricsSampler(dependencies: c.dependencies)
    let old = await sampler.snapshots(); let oldProbe = StreamProbe()
    let oldReader = Task { var iterator = old.makeAsyncIterator(); await oldProbe.record(await iterator.next()) }
    let replacement = await sampler.snapshots()
    await c.waitForStreamTermination(); await oldReader.value
    let probe = StreamProbe(); let reader = Task { var iterator = replacement.makeAsyncIterator(); for _ in 0..<2 { await probe.record(await iterator.next()) } }
    await sampler.setMode(.visible); await probe.waitForValues(1)
    await c.waitForWaiter(); c.fire(); await probe.waitForValues(2)
    await sampler.setMode(.sleeping); await reader.value
    #expect(await probe.values.count == 2)
}

private actor StreamProbe {
    private(set) var values: [SystemSnapshot] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    func record(_ value: SystemSnapshot?) { guard let value else { return }; values.append(value); let continuations = waiters.removeValue(forKey: values.count) ?? []; continuations.forEach { $0.resume() } }
    func waitForValues(_ count: Int) async { guard values.count < count else { return }; await withCheckedContinuation { waiters[count, default: []].append($0) } }
}

private final class SamplerControl: @unchecked Sendable {
    struct Snapshot: Sendable { let reads, waiters, closed, cancelled, privateCalls: Int; let didComplete: Bool }
    private struct State {
        var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]
        var cancelledIDs: Set<UUID> = []
        var cancelledContinuations: [CheckedContinuation<Void, Never>] = []
        var waiterObservers: [CheckedContinuation<Void, Never>] = []
        var joinObservers: [CheckedContinuation<Void, Never>] = []
        var streamTerminationObservers: [CheckedContinuation<Void, Never>] = []
        var streamTerminations = 0
        var cancellationObservers: [CheckedContinuation<Void, Never>] = []
        var readObservers: [Int: [CheckedContinuation<Void, Never>]] = [:]
        var reads = 0; var closed = 0; var cancelled = 0; var joins = 0; var privateCalls = 0
        var openFails = false; var memoryFails = false; var gpuFails = false
        var cpuTemperatureError: MetricError?; var gpuTemperatureError: MetricError?; var fanError: MetricError?
        var pauseCancellation = false; var completion = false
    }
    private let lock = NSLock()
    private var state = State()
    let schema: PrivateMetricSchema?
    init(memoryFails: Bool = false, gpuFails: Bool = false, schema: PrivateMetricSchema? = PrivateMetricSchemaRegistry.schema(model: "Mac17,9", build: "26A5388g")) { self.schema = schema; withState { $0.memoryFails = memoryFails; $0.gpuFails = gpuFails } }
    private func withState<T>(_ body: (inout State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&state) }
    private func readState<T>(_ body: (State) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(state) }
    var snapshot: Snapshot { readState { Snapshot(reads: $0.reads, waiters: $0.sleepers.count, closed: $0.closed, cancelled: $0.cancelled, privateCalls: $0.privateCalls, didComplete: $0.completion) } }
    func setGPUFails(_ value: Bool) { withState { $0.gpuFails = value } }
    func setOpenFails(_ value: Bool) { withState { $0.openFails = value } }
    func setPauseCancellation(_ value: Bool) { withState { $0.pauseCancellation = value } }
    func setTemperatureErrors(cpu: MetricError?, gpu: MetricError?) { withState { $0.cpuTemperatureError = cpu; $0.gpuTemperatureError = gpu } }
    func setFanError(_ value: MetricError?) { withState { $0.fanError = value } }
    var dependencies: MetricsSampler.Dependencies { MetricsSampler.Dependencies(schema: { self.schema }, cpuTicks: { self.ticks() }, memory: { self.readState { $0.memoryFails ? nil : MemoryMetric(usedBytes: 1, totalBytes: 2) } }, gpu: { self.gpu() }, thermal: { .nominal }, smc: { if self.readState({ $0.openFails }) { throw SMCError.open }; return FakeSMC(control: self) }, temperatures: { _, _ in self.temperature() }, fans: { _, _ in self.fan() }, clock: { UInt64(self.snapshot.reads) }, sleeper: FakeSleeper(control: self), transitionWaiterRegistered: { self.transitionJoin() }, streamTerminationObserved: { self.streamTermination() }) }
    func ticks() -> [CPUTicks] { let result: (Int, [CheckedContinuation<Void, Never>]) = withState { state in state.reads += 1; let waiters = state.readObservers.removeValue(forKey: state.reads) ?? []; return (state.reads, waiters) }; result.1.forEach { $0.resume() }; return [CPUTicks(user: UInt64(result.0 * 10), system: 0, nice: 0, idle: UInt64(result.0 * 10))] }
    func gpu() -> Double? { withState { state in state.privateCalls += 1; return state.gpuFails ? nil : 25 } }
    func temperature() -> TemperatureMetric { let errors = readState { ($0.cpuTemperatureError, $0.gpuTemperatureError) }; return TemperatureMetric(cpuAverageCelsius: errors.0 == nil ? 50 : nil, gpuAverageCelsius: errors.1 == nil ? 45 : nil, chipHotspotCelsius: errors.0 == nil && errors.1 == nil ? 50 : nil, cpuError: errors.0, gpuError: errors.1) }
    func fan() -> FanMetric { readState { state in state.fanError.map(FanMetric.unavailable) ?? .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2) } }
    func sleep(id: UUID) async { await withTaskCancellationHandler(operation: { await withCheckedContinuation { continuation in self.add(id, continuation) } }, onCancel: { self.cancel(id) }) }
    func add(_ id: UUID, _ continuation: CheckedContinuation<Void, Never>) { let result = withState { state -> (Bool, [CheckedContinuation<Void, Never>]) in if state.cancelledIDs.remove(id) != nil { return (true, []) }; state.sleepers[id] = continuation; let observers = state.waiterObservers; state.waiterObservers.removeAll(); return (false, observers) }; if result.0 { continuation.resume() }; result.1.forEach { $0.resume() } }
    func cancel(_ id: UUID) { let result = withState { state -> (CheckedContinuation<Void, Never>?, [CheckedContinuation<Void, Never>]) in let continuation = state.sleepers.removeValue(forKey: id); if continuation == nil { state.cancelledIDs.insert(id) }; state.cancelled += 1; let observers = state.cancellationObservers; state.cancellationObservers.removeAll(); if let continuation, state.pauseCancellation { state.cancelledContinuations.append(continuation); return (nil, observers) }; return (continuation, observers) }; result.0?.resume(); result.1.forEach { $0.resume() } }
    func releaseCancelled() { let values = withState { state in let values = state.cancelledContinuations; state.cancelledContinuations.removeAll(); return values }; values.forEach { $0.resume() } }
    func fire() { let value = withState { state in state.sleepers.keys.first.flatMap { state.sleepers.removeValue(forKey: $0) } }; value?.resume() }
    func waitForWaiter() async { if snapshot.waiters > 0 { return }; await withCheckedContinuation { continuation in let ready = withState { state -> Bool in if !state.sleepers.isEmpty { return true }; state.waiterObservers.append(continuation); return false }; if ready { continuation.resume() } } }
    func waitForReads(_ target: Int) async { if snapshot.reads >= target { return }; await withCheckedContinuation { continuation in let ready = withState { state -> Bool in if state.reads >= target { return true }; state.readObservers[target, default: []].append(continuation); return false }; if ready { continuation.resume() } } }
    func waitForCancelled(_ target: Int) async { if snapshot.cancelled >= target { return }; await withCheckedContinuation { continuation in let ready = withState { state -> Bool in if state.cancelled >= target { return true }; state.cancellationObservers.append(continuation); return false }; if ready { continuation.resume() } } }
    func transitionJoin() { let values = withState { state in state.joins += 1; let values = state.joinObservers; state.joinObservers.removeAll(); return values }; values.forEach { $0.resume() } }
    func waitForJoinedTransition() async { if readState({ $0.joins > 0 }) { return }; await withCheckedContinuation { continuation in let ready = withState { state -> Bool in if state.joins > 0 { return true }; state.joinObservers.append(continuation); return false }; if ready { continuation.resume() } } }
    func streamTermination() { let values = withState { state in state.streamTerminations += 1; let values = state.streamTerminationObservers; state.streamTerminationObservers.removeAll(); return values }; values.forEach { $0.resume() } }
    func waitForStreamTermination() async { if readState({ $0.streamTerminations > 0 }) { return }; await withCheckedContinuation { continuation in let ready = withState { state -> Bool in if state.streamTerminations > 0 { return true }; state.streamTerminationObservers.append(continuation); return false }; if ready { continuation.resume() } } }
    func markCompletion() { withState { $0.completion = true } }
}
private struct FakeSleeper: SamplingSleeper { let control: SamplerControl; func sleep(nanoseconds: UInt64) async { await control.sleep(id: UUID()) } }
private final class FakeSMC: SMCReading, @unchecked Sendable { let control: SamplerControl; init(control: SamplerControl) { self.control = control }; func read(key: String) throws -> SMCValue { fatalError() }; func close() { control.lockClose() } }
private extension SamplerControl { func lockClose() { withState { $0.closed += 1 } } }
