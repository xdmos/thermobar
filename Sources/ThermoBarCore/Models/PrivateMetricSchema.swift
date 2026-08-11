public struct FanKeyPair: Equatable, Sendable {
    public let actualKey: String
    public let maximumKey: String

    public init(actualKey: String, maximumKey: String) {
        self.actualKey = actualKey
        self.maximumKey = maximumKey
    }
}

public struct PrivateMetricSchema: Equatable, Sendable {
    public let model: String
    public let osBuild: String
    public let cpuTemperatureKeys: [String]
    public let gpuTemperatureKeys: [String]
    public let gpuUtilizationKey: String
    public let fanCountKey: String
    public let expectedFanCount: Int
    public let fanKeys: [FanKeyPair]

    public init(
        model: String,
        osBuild: String,
        cpuTemperatureKeys: [String],
        gpuTemperatureKeys: [String],
        gpuUtilizationKey: String,
        fanCountKey: String = "",
        expectedFanCount: Int = 0,
        fanKeys: [FanKeyPair] = []
    ) {
        self.model = model
        self.osBuild = osBuild
        self.cpuTemperatureKeys = cpuTemperatureKeys
        self.gpuTemperatureKeys = gpuTemperatureKeys
        self.gpuUtilizationKey = gpuUtilizationKey
        self.fanCountKey = fanCountKey
        self.expectedFanCount = expectedFanCount
        self.fanKeys = fanKeys
    }
}

public enum PrivateMetricSchemaRegistry {
    public static func schema(model: String, build: String) -> PrivateMetricSchema? {
        guard model == "Mac17,9", build == "26A5388g" else {
            return nil
        }

        return PrivateMetricSchema(
            model: model,
            osBuild: build,
            cpuTemperatureKeys: [
                "Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U",
                "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y"
            ],
            gpuTemperatureKeys: ["Tg0U", "Tg0X", "Tg0d", "Tg0g", "Tg0j", "Tg1Y", "Tg1c"],
            gpuUtilizationKey: "Device Utilization %",
            fanCountKey: "FNum",
            expectedFanCount: 2,
            fanKeys: [
                FanKeyPair(actualKey: "F0Ac", maximumKey: "F0Mx"),
                FanKeyPair(actualKey: "F1Ac", maximumKey: "F1Mx")
            ]
        )
    }
}
