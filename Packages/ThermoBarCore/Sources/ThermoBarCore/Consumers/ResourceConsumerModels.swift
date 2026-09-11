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
    /// How many processes the row sums. RAM rows aggregate every process of one
    /// application bundle or executable, so a single row can stand for dozens.
    public let processCount: Int
    public let iconPath: String?

    public init(
        pid: Int32,
        name: String,
        physicalFootprintBytes: UInt64,
        processCount: Int = 1,
        iconPath: String? = nil
    ) {
        self.pid = pid
        self.name = name
        self.physicalFootprintBytes = physicalFootprintBytes
        self.processCount = processCount
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
