public struct ResourceConsumerCPUEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let percent: Double
    public let gpuPercent: Double?
    public let iconPath: String?

    public init(
        pid: Int32,
        name: String,
        percent: Double,
        gpuPercent: Double? = nil,
        iconPath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.percent = percent
        self.gpuPercent = gpuPercent
        self.iconPath = iconPath
    }
}

public struct ResourceConsumerMemoryEntry: Equatable, Sendable {
    public let pid: Int32
    public let name: String
    public let physicalFootprintBytes: UInt64
    public let iconPath: String?

    public init(
        pid: Int32,
        name: String,
        physicalFootprintBytes: UInt64,
        iconPath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.physicalFootprintBytes = physicalFootprintBytes
        self.iconPath = iconPath
    }
}

public enum ResourceConsumerSection<Row: Equatable & Sendable>: Equatable, Sendable {
    case inactive, measuring, available([Row]), unavailable
}

public struct ResourceConsumerMetric: Equatable, Sendable {
    public let cpu: ResourceConsumerSection<ResourceConsumerCPUEntry>
    public let memory: ResourceConsumerSection<ResourceConsumerMemoryEntry>
    public init(cpu: ResourceConsumerSection<ResourceConsumerCPUEntry>, memory: ResourceConsumerSection<ResourceConsumerMemoryEntry>) { self.cpu = cpu; self.memory = memory }
    public static let inactive = Self(cpu: .inactive, memory: .inactive)
}
