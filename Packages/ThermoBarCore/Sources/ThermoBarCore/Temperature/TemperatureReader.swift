internal struct TemperatureReader {
    private let schema: PrivateMetricSchema
    private let reader: any SMCReading

    init(schema: PrivateMetricSchema, reader: any SMCReading) {
        self.schema = schema
        self.reader = reader
    }

    func read() -> TemperatureMetric {
        guard PrivateMetricSchemaRegistry.schema(model: schema.model, build: schema.osBuild) == schema else {
            return unsupportedSchemaMetric()
        }

        let cpu = readGroup(keys: schema.cpuTemperatureKeys)
        guard case .connectionFailure = cpu else {
            let gpu = readGroup(keys: schema.gpuTemperatureKeys)
            guard case .connectionFailure = gpu else {
                return metric(cpu: cpu, gpu: gpu)
            }
            return connectionFailureMetric()
        }
        return connectionFailureMetric()
    }

    private func metric(cpu: GroupResult, gpu: GroupResult) -> TemperatureMetric {
        let cpuSuccess = cpu.success
        let gpuSuccess = gpu.success

        return TemperatureMetric(
            cpuAverageCelsius: cpuSuccess?.average,
            gpuAverageCelsius: gpuSuccess?.average,
            chipHotspotCelsius: hotspot(cpu: cpuSuccess, gpu: gpuSuccess),
            cpuError: cpu.error,
            gpuError: gpu.error
        )
    }

    private func hotspot(cpu: GroupSuccess?, gpu: GroupSuccess?) -> Double? {
        guard let cpu, let gpu else {
            return nil
        }
        return (cpu.values + gpu.values).max()
    }

    private func connectionFailureMetric() -> TemperatureMetric {
        TemperatureMetric(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: nil,
            chipHotspotCelsius: nil,
            cpuError: .readFailed,
            gpuError: .readFailed
        )
    }

    private func unsupportedSchemaMetric() -> TemperatureMetric {
        TemperatureMetric(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: nil,
            chipHotspotCelsius: nil,
            cpuError: .unsupportedPrivateMetricSchema,
            gpuError: .unsupportedPrivateMetricSchema
        )
    }

    private func readGroup(keys: [String]) -> GroupResult {
        guard !keys.isEmpty else {
            return .failure(.invalidValue)
        }

        var values: [Double] = []
        values.reserveCapacity(keys.count)

        for key in keys {
            let raw: SMCValue
            do {
                raw = try reader.read(key: key)
            } catch {
                if isConnectionFailure(error) {
                    return .connectionFailure
                }
                return .failure(metricError(for: error, key: key))
            }

            guard raw.key == key else {
                return .failure(.missingExpectedKey(key))
            }
            guard raw.dataType == "flt ", raw.bytes.count == 4 else {
                return .failure(.unexpectedType(key))
            }
            guard let value = SMCFloatDecoder.decode(type: raw.dataType, bytes: raw.bytes) else {
                return .failure(.invalidValue)
            }
            values.append(value)
        }

        return .success(GroupSuccess(
            average: values.reduce(0, +) / Double(keys.count),
            values: values
        ))
    }

    private func isConnectionFailure(_ error: any Error) -> Bool {
        guard let error = error as? SMCError else {
            return false
        }
        switch error {
        case .call, .closed, .unavailable, .open:
            return true
        case .invalidKey, .invalidSize, .keyUnavailable, .invalidDataType, .invalidResponse:
            return false
        }
    }

    private func metricError(for error: any Error, key: String) -> MetricError {
        guard let error = error as? SMCError else {
            return .missingExpectedKey(key)
        }
        switch error {
        case .invalidSize, .invalidDataType, .invalidResponse:
            return .unexpectedType(key)
        case .invalidKey, .keyUnavailable:
            return .missingExpectedKey(key)
        case .call, .closed, .unavailable, .open:
            return .readFailed
        }
    }
}

private struct GroupSuccess {
    let average: Double
    let values: [Double]
}

private enum GroupResult {
    case success(GroupSuccess)
    case failure(MetricError)
    case connectionFailure

    var success: GroupSuccess? {
        guard case let .success(success) = self else {
            return nil
        }
        return success
    }

    var error: MetricError? {
        guard case let .failure(error) = self else {
            return nil
        }
        return error
    }
}
