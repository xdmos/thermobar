import ThermoBarCore

enum PreviewFixtures {
    static let nowNanoseconds: UInt64 = 1_000_000_000_000

    static let nominal = snapshot(
        timestamp: nowNanoseconds - 1_000_000_000,
        cpuPercent: 26.4,
        memory: .init(usedBytes: 12_884_901_888, totalBytes: 25_769_803_776),
        gpuPercent: 18.7,
        temperature: .init(
            cpuAverageCelsius: 49.6,
            gpuAverageCelsius: 46.4,
            chipHotspotCelsius: 53.8,
            cpuError: nil,
            gpuError: nil
        ),
        fan: .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .nominal,
        publicError: nil,
        privateError: nil
    )

    static let serious = snapshot(
        timestamp: nowNanoseconds - 1_000_000_000,
        cpuPercent: 92.1,
        memory: .init(usedBytes: 22_548_578_304, totalBytes: 25_769_803_776),
        gpuPercent: 86.5,
        temperature: .init(
            cpuAverageCelsius: 88.4,
            gpuAverageCelsius: 81.2,
            chipHotspotCelsius: 96.7,
            cpuError: nil,
            gpuError: nil
        ),
        fan: .available(fastestRPM: 5_840, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .serious,
        publicError: nil,
        privateError: nil
    )

    static let stale = snapshot(
        timestamp: nowNanoseconds - 6_000_000_001,
        cpuPercent: 38.2,
        memory: .init(usedBytes: 14_000_000_000, totalBytes: 25_769_803_776),
        gpuPercent: 28.5,
        temperature: .init(
            cpuAverageCelsius: 57.2,
            gpuAverageCelsius: 54.8,
            chipHotspotCelsius: 61.3,
            cpuError: nil,
            gpuError: nil
        ),
        fan: .available(fastestRPM: 3_120, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .fair,
        publicError: nil,
        privateError: nil
    )

    static let unsupportedSchema = snapshot(
        timestamp: nowNanoseconds - 1_000_000_000,
        cpuPercent: 19.5,
        memory: .init(usedBytes: 10_737_418_240, totalBytes: 25_769_803_776),
        gpuPercent: nil,
        temperature: .init(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: nil,
            chipHotspotCelsius: nil,
            cpuError: .unsupportedPrivateMetricSchema,
            gpuError: .unsupportedPrivateMetricSchema
        ),
        fan: .unavailable(.unsupportedPrivateMetricSchema),
        thermalLevel: .nominal,
        publicError: nil,
        privateError: .unsupportedPrivateMetricSchema
    )

    static let partialSensorFailure = snapshot(
        timestamp: nowNanoseconds - 1_000_000_000,
        cpuPercent: 43.0,
        memory: .init(usedBytes: 16_106_127_360, totalBytes: 25_769_803_776),
        gpuPercent: 32.7,
        temperature: .init(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: 58.8,
            chipHotspotCelsius: nil,
            cpuError: .missingExpectedKey("Tp0m"),
            gpuError: nil
        ),
        fan: .available(fastestRPM: 2_780, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .fair,
        publicError: nil,
        privateError: .missingExpectedKey("Tp0m")
    )

    private static func snapshot(
        timestamp: UInt64,
        cpuPercent: Double?,
        memory: MemoryMetric?,
        gpuPercent: Double?,
        temperature: TemperatureMetric,
        fan: FanMetric,
        thermalLevel: ThermalLevel,
        publicError: MetricError?,
        privateError: MetricError?
    ) -> SystemSnapshot {
        SystemSnapshot(
            monotonicNanoseconds: timestamp,
            cpuPercent: cpuPercent,
            memory: memory,
            gpuPercent: gpuPercent,
            temperature: temperature,
            fan: fan,
            thermalLevel: thermalLevel,
            publicMetricError: publicError,
            privateMetricError: privateError
        )
    }
}
