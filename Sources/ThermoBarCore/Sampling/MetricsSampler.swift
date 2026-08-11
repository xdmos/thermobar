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
        let sleeper: any SamplingSleeper
        let transitionWaiterRegistered: @Sendable () -> Void
        let streamTerminationObserved: @Sendable () -> Void
        init(schema: @escaping @Sendable () -> PrivateMetricSchema?, cpuTicks: @escaping @Sendable () -> [CPUTicks]?, memory: @escaping @Sendable () -> MemoryMetric?, gpu: @escaping @Sendable () -> Double?, thermal: @escaping @Sendable () -> ThermalLevel, smc: @escaping @Sendable () throws -> any SMCReading, temperatures: @escaping @Sendable (PrivateMetricSchema, any SMCReading) -> TemperatureMetric, fans: @escaping @Sendable (PrivateMetricSchema, any SMCReading) -> FanMetric, clock: @escaping @Sendable () -> UInt64, sleeper: any SamplingSleeper, transitionWaiterRegistered: @escaping @Sendable () -> Void = {}, streamTerminationObserved: @escaping @Sendable () -> Void = {}) {
            self.schema = schema; self.cpuTicks = cpuTicks; self.memory = memory; self.gpu = gpu; self.thermal = thermal; self.smc = smc; self.temperatures = temperatures; self.fans = fans; self.clock = clock; self.sleeper = sleeper; self.transitionWaiterRegistered = transitionWaiterRegistered; self.streamTerminationObserved = streamTerminationObserved
        }
    }
    private struct FailureState { let count: Int; let error: MetricError }
    private let dependencies: Dependencies
    public private(set) var mode: SamplingMode = .sleeping
    public private(set) var latestSnapshot: SystemSnapshot?
    private var loop: Task<Void, Never>?
    private var activeTransitionID: UUID?
    private var transitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var cpuCalculator = CPUUsageCalculator()
    private var smc: (any SMCReading)?
    private var failures: [SamplingSource: FailureState] = [:]
    private var continuation: AsyncStream<SystemSnapshot>.Continuation?
    private var streamID: UUID?

    public init(model: String, build: String) {
        let schema = PrivateMetricSchemaRegistry.schema(model: model, build: build)
        dependencies = Dependencies(schema: { schema }, cpuTicks: { CPUUsageReader().readTicks() }, memory: { MemoryUsageReader().read() }, gpu: { guard let schema else { return nil }; return GPUUsageReader(schema: schema).read() }, thermal: { ThermalStateReader().read() }, smc: { try SMCClient() }, temperatures: { TemperatureReader(schema: $0, reader: $1).read() }, fans: { FanReader(schema: $0, reader: $1).read() }, clock: { MonotonicClock.nowNanoseconds() }, sleeper: ContinuousSamplingSleeper())
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    public func snapshots() -> AsyncStream<SystemSnapshot> {
        continuation?.finish(); let id = UUID(); streamID = id
        return AsyncStream { continuation in
            self.continuation = continuation
            continuation.onTermination = { @Sendable [weak self] _ in Task { await self?.clearContinuation(id: id) } }
        }
    }
    public func currentDiagnostics() -> [SamplingDiagnostic] {
        SamplingSource.allCases.compactMap { source in failures[source].map { SamplingDiagnostic(source: source, error: $0.error, consecutiveFailures: $0.count) } }
    }
    public func setMode(_ newMode: SamplingMode) async {
        if newMode == mode {
            await waitForTransition()
            return
        }
        // Publish intent before suspension. Concurrent equal requests are then idempotent.
        mode = newMode
        let transitionID = UUID()
        activeTransitionID = transitionID
        // Keep the retiring loop installed until it has exited, so every newer transition
        // cancels and awaits the same task rather than accidentally creating a second cadence.
        let old = loop
        old?.cancel()
        await old?.value
        guard activeTransitionID == transitionID else {
            await waitForTransition()
            return
        }
        loop = nil
        guard let interval = newMode.intervalNanoseconds else {
            smc?.close(); smc = nil; cpuCalculator.reset(); completeTransition(transitionID); return
        }
        // Source reads are synchronous. Once this actor resumes, sample() cannot interleave with sleep.
        sample()
        guard mode == newMode else { return }
        let sleeper = dependencies.sleeper
        loop = Task { [weak self, sleeper] in
            while !Task.isCancelled {
                await sleeper.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                await self?.sampleCadence(expectedMode: newMode)
            }
        }
        completeTransition(transitionID)
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
        let snapshot = SystemSnapshot(monotonicNanoseconds: dependencies.clock(), cpuPercent: cpu, memory: memory, gpuPercent: gpu, temperature: temperature, fan: fan, thermalLevel: thermal, publicMetricError: (ticks == nil || memory == nil) ? .readFailed : nil, privateMetricError: privateError)
        guard mode != .sleeping else { return }
        latestSnapshot = snapshot; continuation?.yield(snapshot)
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
    private func clearContinuation(id: UUID) { dependencies.streamTerminationObserved(); guard streamID == id else { return }; continuation = nil; streamID = nil }
    private func validatedSchema(_ value: PrivateMetricSchema?) -> PrivateMetricSchema? { guard let value, PrivateMetricSchemaRegistry.schema(model: value.model, build: value.osBuild) == value else { return nil }; return value }
    private func emptyTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: nil, gpuError: nil) }
    private func failedTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: .readFailed, gpuError: .readFailed) }
    private func unsupportedTemperature() -> TemperatureMetric { TemperatureMetric(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: .unsupportedPrivateMetricSchema, gpuError: .unsupportedPrivateMetricSchema) }
    private func failedFan() -> FanMetric { .unavailable(.readFailed) }
    private func unsupportedFan() -> FanMetric { .unavailable(.unsupportedPrivateMetricSchema) }
    deinit {
        loop?.cancel()
        continuation?.finish()
        smc?.close()
        transitionWaiters.forEach { $0.resume() }
    }
}
