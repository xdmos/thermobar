internal struct FanReader {
    private let schema: PrivateMetricSchema
    private let reader: any SMCReading

    init(schema: PrivateMetricSchema, reader: any SMCReading) {
        self.schema = schema
        self.reader = reader
    }

    func read() -> FanMetric {
        guard PrivateMetricSchemaRegistry.schema(model: schema.model, build: schema.osBuild) == schema,
              !schema.fanCountKey.isEmpty,
              schema.expectedFanCount > 0,
              schema.expectedFanCount <= Int(UInt8.max),
              schema.fanKeys.count == schema.expectedFanCount else {
            return .unavailable(.unsupportedPrivateMetricSchema)
        }

        switch readCount() {
        case .success(let count):
            guard count == schema.expectedFanCount else {
                return .unavailable(.invalidValue)
            }
        case .failure(let error):
            return .unavailable(error)
        }

        var fastest: (actual: Double, maximum: Double)?
        for keys in schema.fanKeys {
            let actual: Double
            switch readFloat(key: keys.actualKey) {
            case .success(let value): actual = value
            case .failure(let error): return .unavailable(error)
            }

            let maximum: Double
            switch readFloat(key: keys.maximumKey) {
            case .success(let value): maximum = value
            case .failure(let error): return .unavailable(error)
            }

            guard maximum > 0, actual >= 0, actual <= maximum else {
                return .unavailable(.invalidValue)
            }
            if fastest.map({ actual > $0.actual }) ?? true {
                fastest = (actual, maximum)
            }
        }

        guard let fastest else { return .unavailable(.invalidValue) }
        return .available(
            fastestRPM: fastest.actual,
            fastestMaximumRPM: fastest.maximum,
            validatedFanCount: schema.expectedFanCount
        )
    }

    private func readCount() -> FanReadResult<Int> {
        let raw: SMCValue
        do {
            raw = try reader.read(key: schema.fanCountKey)
        } catch {
            return .failure(metricError(for: error, key: schema.fanCountKey))
        }
        guard raw.key == schema.fanCountKey else {
            return .failure(.missingExpectedKey(schema.fanCountKey))
        }
        guard raw.dataType == "ui8 ", raw.bytes.count == 1 else {
            return .failure(.unexpectedType(schema.fanCountKey))
        }
        return .success(Int(raw.bytes[0]))
    }

    private func readFloat(key: String) -> FanReadResult<Double> {
        let raw: SMCValue
        do {
            raw = try reader.read(key: key)
        } catch {
            return .failure(metricError(for: error, key: key))
        }
        guard raw.key == key else { return .failure(.missingExpectedKey(key)) }
        guard raw.dataType == "flt ", raw.bytes.count == 4 else {
            return .failure(.unexpectedType(key))
        }
        guard let value = SMCFloatDecoder.decodeFinite(type: raw.dataType, bytes: raw.bytes) else {
            return .failure(.invalidValue)
        }
        return .success(value)
    }

    private func metricError(for error: any Error, key: String) -> MetricError {
        guard let error = error as? SMCError else {
            return .missingExpectedKey(key)
        }
        switch error {
        case .call, .closed, .unavailable, .open:
            return .readFailed
        case .invalidKey, .keyUnavailable:
            return .missingExpectedKey(key)
        case .invalidSize, .invalidDataType, .invalidResponse:
            return .unexpectedType(key)
        }
    }
}

private enum FanReadResult<Value> {
    case success(Value)
    case failure(MetricError)
}
