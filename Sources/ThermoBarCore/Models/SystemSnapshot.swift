public enum ThermalLevel: Int, CaseIterable, Equatable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum MetricError: Equatable, Sendable {
    case readFailed
    case invalidValue
    case stale
    case unsupportedPrivateMetricSchema
    case missingExpectedKey(String)
    case unexpectedType(String)
}

public struct MemoryMetric: Equatable, Sendable {
    public let usedBytes: UInt64
    public let totalBytes: UInt64

    public init(usedBytes: UInt64, totalBytes: UInt64) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
    }

    public var usedFraction: Double {
        Double(usedBytes) / Double(totalBytes)
    }
}

public struct TemperatureMetric: Equatable, Sendable {
    public let cpuAverageCelsius: Double?
    public let gpuAverageCelsius: Double?
    public let chipHotspotCelsius: Double?
    public let cpuError: MetricError?
    public let gpuError: MetricError?

    public init(
        cpuAverageCelsius: Double?,
        gpuAverageCelsius: Double?,
        chipHotspotCelsius: Double?,
        cpuError: MetricError?,
        gpuError: MetricError?
    ) {
        self.cpuAverageCelsius = cpuAverageCelsius
        self.gpuAverageCelsius = gpuAverageCelsius
        self.chipHotspotCelsius = chipHotspotCelsius
        self.cpuError = cpuError
        self.gpuError = gpuError
    }
}

public enum FanMetric: Equatable, Sendable {
    case available(fastestRPM: Double, fastestMaximumRPM: Double, validatedFanCount: Int)
    case unavailable(MetricError)

    public var fastestRPM: Double? {
        guard case let .available(value, _, _) = self else { return nil }
        return value
    }

    public var fastestMaximumRPM: Double? {
        guard case let .available(_, value, _) = self else { return nil }
        return value
    }

    public var validatedFanCount: Int? {
        guard case let .available(_, _, value) = self else { return nil }
        return value
    }

    public var error: MetricError? {
        guard case let .unavailable(error) = self else { return nil }
        return error
    }
}

public struct SystemSnapshot: Equatable, Sendable {
    public let monotonicNanoseconds: UInt64
    public let cpuPercent: Double?
    public let memory: MemoryMetric?
    public let gpuPercent: Double?
    public let temperature: TemperatureMetric
    public let fan: FanMetric
    public let thermalLevel: ThermalLevel
    public let publicMetricError: MetricError?
    public let privateMetricError: MetricError?
    public let resourceConsumers: ResourceConsumerMetric

    public init(
        monotonicNanoseconds: UInt64,
        cpuPercent: Double?,
        memory: MemoryMetric?,
        gpuPercent: Double?,
        temperature: TemperatureMetric,
        fan: FanMetric,
        thermalLevel: ThermalLevel,
        publicMetricError: MetricError?,
        privateMetricError: MetricError?,
        resourceConsumers: ResourceConsumerMetric = .inactive
    ) {
        self.monotonicNanoseconds = monotonicNanoseconds
        self.cpuPercent = cpuPercent
        self.memory = memory
        self.gpuPercent = gpuPercent
        self.temperature = temperature
        self.fan = fan
        self.thermalLevel = thermalLevel
        self.publicMetricError = publicMetricError
        self.privateMetricError = privateMetricError
        self.resourceConsumers = resourceConsumers
    }

    public func replacing(resourceConsumers: ResourceConsumerMetric) -> Self {
        .init(monotonicNanoseconds: monotonicNanoseconds, cpuPercent: cpuPercent, memory: memory, gpuPercent: gpuPercent, temperature: temperature, fan: fan, thermalLevel: thermalLevel, publicMetricError: publicMetricError, privateMetricError: privateMetricError, resourceConsumers: resourceConsumers)
    }
}
