import Foundation

public protocol SamplingSleeper: Sendable { func sleep(nanoseconds: UInt64) async }

public struct ContinuousSamplingSleeper: SamplingSleeper {
    public init() {}
    // CancellationError is intentionally swallowed: run() checks cancellation immediately afterwards.
    public func sleep(nanoseconds: UInt64) async { try? await Task.sleep(nanoseconds: nanoseconds) }
}

public enum SamplingSource: Int, CaseIterable, Equatable, Sendable {
    case smcConnection, cpuTemperature, gpuTemperature, fanSpeed, gpuUtilization, cpu, memory
}

public struct SamplingDiagnostic: Equatable, Sendable {
    public let source: SamplingSource
    public let error: MetricError
    public let consecutiveFailures: Int
    public let isPersistent: Bool
    public init(source: SamplingSource, error: MetricError, consecutiveFailures: Int) {
        self.source = source; self.error = error; self.consecutiveFailures = consecutiveFailures
        isPersistent = consecutiveFailures >= 3
    }
}

public actor MetricsSampler {
    public struct Dependencies: Sendable {
        let schema: @Sendable () -> PrivateMetricSchema?
        let cpuTicks: @Sendable () -> [CPUTicks]?
        let memory: @Sendable () -> MemoryMetric?
        let gpu: @Sendable () -> Double?
        let thermal: @Sendable () -> ThermalLevel
        let smc: @Sendable () throws -> any SMCReading
        let temperatures: @Sendable (PrivateMetricSchema, any SMCReading) -> TemperatureMetric
        let fans: @Sendable (PrivateMetricSchema, any SMCReading) -> FanMetric
        let clock: @Sendable () -> UInt64
        let consumerUsage: @Sendable () -> ConsumerUsageReading?
        let sleeper: any SamplingSleeper
        let transitionWaiterRegistered: @Sendable () -> Void
        let streamTerminationObserved: @Sendable () -> Void
        init(schema: @escaping @Sendable () -> PrivateMetricSchema?, cpuTicks: @escaping @Sendable () -> [CPUTicks]?, memory: @escaping @Sendable () -> MemoryMetric?, gpu: @escaping @Sendable () -> Double?, thermal: @escaping @Sendable () -> ThermalLevel, smc: @escaping @Sendable () throws -> any SMCReading, temperatures: @escaping @Sendable (PrivateMetricSchema, any SMCReading) -> TemperatureMetric, fans: @escaping @Sendable (PrivateMetricSchema, any SMCReading) -> FanMetric, clock: @escaping @Sendable () -> UInt64, sleeper: any SamplingSleeper, consumerUsage: @escaping @Sendable () -> ConsumerUsageReading? = { nil }, transitionWaiterRegistered: @escaping @Sendable () -> Void = {}, streamTerminationObserved: @escaping @Sendable () -> Void = {}) {
            self.schema = schema; self.cpuTicks = cpuTicks; self.memory = memory; self.gpu = gpu; self.thermal = thermal; self.smc = smc; self.temperatures = temperatures; self.fans = fans; self.clock = clock; self.sleeper = sleeper; self.consumerUsage = consumerUsage; self.transitionWaiterRegistered = transitionWaiterRegistered; self.streamTerminationObserved = streamTerminationObserved
        }
    }
    private struct FailureState { let count: Int; let error: MetricError }
    private let dependencies: Dependencies
    public private(set) var mode: SamplingMode = .sleeping
    public private(set) var latestSnapshot: SystemSnapshot?
    private var loop: Task<Void, Never>?
    private var activeTransitionID: UUID?
    private var currentModeTransitionID = UUID()
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cpuCalculator = CPUUsageCalculator()
    private var consumerCalculator = ResourceConsumerCalculator()
    private var smc: (any SMCReading)?
    private var failures: [SamplingSource: FailureState] = [:]
    private var continuation: AsyncStream<SamplingSnapshot>.Continuation?
    private var thermalContinuation: AsyncStream<ThermalSample>.Continuation?
    private var streamID: UUID?
    private var thermalStreamID: UUID?

    public init(model: String, build: String) {
        let schema = PrivateMetricSchemaRegistry.schema(model: model, build: build)
        dependencies = Dependencies(schema: { schema }, cpuTicks: { CPUUsageReader().readTicks() }, memory: { MemoryUsageReader().read() }, gpu: { guard let schema else { return nil }; return GPUUsageReader(schema: schema).read() }, thermal: { ThermalStateReader().read() }, smc: { try SMCClient() }, temperatures: { TemperatureReader(schema: $0, reader: $1).read() }, fans: { FanReader(schema: $0, reader: $1).read() }, clock: { MonotonicClock.nowNanoseconds() }, sleeper: ContinuousSamplingSleeper(), consumerUsage: { ResourceConsumerReader().read() })
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    public func snapshots() -> AsyncStream<SamplingSnapshot> {
        continuation?.finish(); let id = UUID(); streamID = id
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.clearContinuation(id: id) } }
        }
    }
    public func thermalSamples() -> AsyncStream<ThermalSample> {
        thermalContinuation?.finish(); let id = UUID(); thermalStreamID = id
        return AsyncStream { continuation in
            self.thermalContinuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.clearThermalContinuation(id: id) } }
        }
    }
    public func currentDiagnostics() -> [SamplingDiagnostic] {
        SamplingSource.allCases.compactMap { source in failures[source].map { SamplingDiagnostic(source: source, error: $0.error, consecutiveFailures: $0.count) } }
    }
    public func setMode(_ newMode: SamplingMode) async { _ = await setMode(newMode, transitionID: UUID()) }
    public func setMode(_ newMode: SamplingMode, transitionID requestedID: UUID) async -> SamplingTransitionReceipt {
        if newMode == mode {
            await waitForTransition()
            return receipt(requestedID)
        }
        // Publish intent before suspension. Concurrent equal requests are then idempotent.
        mode = newMode
        let transitionID = requestedID
        activeTransitionID = transitionID
        currentModeTransitionID = transitionID
        // Sleep intent must erase consumer identities before awaiting retirement of a
        // previously active loop. The newest stream slot replaces any older value.
        if newMode == .sleeping {
            _ = consumerCalculator.reset()
            if let latestSnapshot {
                let redacted = latestSnapshot.replacing(resourceConsumers: .inactive)
                self.latestSnapshot = redacted
                continuation?.yield(.init(value: redacted, transitionID: transitionID))
            }
        }
        // Keep the retiring loop installed until it has exited, so every newer transition
        // cancels and awaits the same task rather than accidentally creating a second cadence.
        let old = loop
        old?.cancel()
        await old?.value
        guard activeTransitionID == transitionID else {
            await waitForTransition()
            return receipt(requestedID)
        }
        loop = nil
        guard let interval = newMode.intervalNanoseconds else {
            smc?.close(); smc = nil; cpuCalculator.reset(); _ = consumerCalculator.reset()
            completeTransition(transitionID); return receipt(requestedID)
        }
        // Source reads are synchronous. Once this actor resumes, sample() cannot interleave with sleep.
        sample()
        guard mode == newMode else { return receipt(requestedID) }
        let sleeper = dependencies.sleeper
        loop = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                await sleeper.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.sampleCadence(expectedMode: newMode)
            }
        }
        completeTransition(transitionID)
        return receipt(requestedID)
    }
    private func sampleCadence(expectedMode: SamplingMode) {
        guard mode == expectedMode else { return }
        sample()
    }
    private func sample() {
        guard mode != .sleeping else { return }
        let ticks = dependencies.cpuTicks()
        let cpu: Double?
        if let ticks { cpu = cpuCalculator.consume(ticks); record(.cpu, error: nil) } else { cpuCalculator.reset(); cpu = nil; record(.cpu, error: .readFailed) }
        let memory = dependencies.memory(); record(.memory, error: memory == nil ? .readFailed : nil)
        let thermal = dependencies.thermal()
        var gpu: Double?; var temperature = emptyTemperature(); var fan = failedFan(); var privateError: MetricError?
        if let schema = validatedSchema(dependencies.schema()) {
            gpu = dependencies.gpu()
            record(.gpuUtilization, error: gpu == nil ? .readFailed : nil)
            if gpu == nil { privateError = .readFailed }
            if smc == nil {
                do { smc = try dependencies.smc() }
                catch { record(.smcConnection, error: .readFailed) }
            }
            if let smc {
                temperature = dependencies.temperatures(schema, smc)
                fan = dependencies.fans(schema, smc)
                let temperatureConnectionFailure = temperature.cpuError == .readFailed && temperature.gpuError == .readFailed
                let connectionFailure = temperatureConnectionFailure || fan.error == .readFailed
                if connectionFailure {
                    temperature = failedTemperature(); fan = failedFan()
                    record(.smcConnection, error: .readFailed); record(.fanSpeed, error: nil)
                    smc.close(); self.smc = nil; privateError = .readFailed
                } else {
                    record(.smcConnection, error: nil)
                    record(.cpuTemperature, error: temperature.cpuError)
                    record(.gpuTemperature, error: temperature.gpuError)
                    record(.fanSpeed, error: fan.error)
                    privateError = privateError ?? temperature.cpuError ?? temperature.gpuError ?? fan.error
                }
            } else { temperature = failedTemperature(); fan = failedFan(); privateError = .readFailed }
        } else { temperature = unsupportedTemperature(); fan = unsupportedFan(); privateError = .unsupportedPrivateMetricSchema }
        let consumers: ResourceConsumerMetric
        if mode == .visible { consumers = consumerCalculator.consume(dependencies.consumerUsage()) }
        else { consumers = consumerCalculator.reset() }
        let snapshot = SystemSnapshot(monotonicNanoseconds: dependencies.clock(), cpuPercent: cpu, memory: memory, gpuPercent: gpu, temperature: temperature, fan: fan, thermalLevel: thermal, publicMetricError: (ticks == nil || memory == nil) ? .readFailed : nil, privateMetricError: privateError, resourceConsumers: consumers)
        guard mode != .sleeping else { return }
        latestSnapshot = snapshot
        continuation?.yield(.init(value: snapshot, transitionID: currentModeTransitionID))
        thermalContinuation?.yield(.init(level: thermal, monotonicNanoseconds: snapshot.monotonicNanoseconds))
    }
    private func record(_ source: SamplingSource, error: MetricError?) {
        guard let error else { failures[source] = nil; return }
        let previous = failures[source]?.count ?? 0
        failures[source] = FailureState(count: previous == .max ? .max : previous + 1, error: error)
    }
    private func waitForTransition() async {
        guard activeTransitionID != nil else { return }
        await withCheckedContinuation { continuation in
            transitionWaiters.append(continuation)
            dependencies.transitionWaiterRegistered()
        }
    }
    private func completeTransition(_ id: UUID) {
        guard activeTransitionID == id else { return }
        activeTransitionID = nil
        let ready = transitionWaiters
        transitionWaiters.removeAll()
        ready.forEach { $0.resume() }
    }
    private func receipt(_ requested: UUID) -> SamplingTransitionReceipt { .init(requestedTransitionID: requested, currentTransitionID: currentModeTransitionID, currentMode: mode, isCurrent: currentModeTransitionID == requested) }
    private func clearContinuation(id: UUID) { dependencies.streamTerminationObserved(); guard streamID == id else { return }; continuation = nil; streamID = nil }
    private func clearThermalContinuation(id: UUID) { guard thermalStreamID == id else { return }; thermalContinuation = nil; thermalStreamID = nil }
    private func validatedSchema(_ value: PrivateMetricSchema?) -> PrivateMetricSchema? { guard let value, PrivateMetricSchemaRegistry.schema(model: value.model, build: value.osBuild) == value else { return nil }; return value }
    private func emptyTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: nil, gpuError: nil) }
    private func failedTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: .readFailed, gpuError: .readFailed) }
    private func unsupportedTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: .unsupportedPrivateMetricSchema, gpuError: .unsupportedPrivateMetricSchema) }
    private func failedFan() -> FanMetric { .unavailable(.readFailed) }
    private func unsupportedFan() -> FanMetric { .unavailable(.unsupportedPrivateMetricSchema) }
    deinit {
        loop?.cancel()
        continuation?.finish()
        thermalContinuation?.finish()
        smc?.close()
        transitionWaiters.forEach { $0.resume() }
    }
}
