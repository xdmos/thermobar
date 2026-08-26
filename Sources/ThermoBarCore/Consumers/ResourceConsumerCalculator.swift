import Foundation

struct ConsumerUsageRecord: Equatable, Sendable {
    let pid: Int32; let startTime: UInt64; let groupID: String; let name: String; let processName: String; let iconPath: String?; let cumulativeCPUTimeNanoseconds: UInt64; let cumulativeGPUTimeNanoseconds: UInt64?; let physicalFootprintBytes: UInt64

    init(pid: Int32, startTime: UInt64, groupID: String, name: String, processName: String? = nil, iconPath: String? = nil, cumulativeCPUTimeNanoseconds: UInt64, physicalFootprintBytes: UInt64, cumulativeGPUTimeNanoseconds: UInt64? = nil) {
        self.pid = pid; self.startTime = startTime; self.groupID = groupID; self.name = name; self.processName = processName ?? name; self.iconPath = iconPath; self.cumulativeCPUTimeNanoseconds = cumulativeCPUTimeNanoseconds; self.physicalFootprintBytes = physicalFootprintBytes; self.cumulativeGPUTimeNanoseconds = cumulativeGPUTimeNanoseconds
    }
}
struct ConsumerUsageReading: Equatable, Sendable { let monotonicNanoseconds: UInt64; let records: [ConsumerUsageRecord] }

struct ResourceConsumerCalculator: Sendable {
    private struct Baseline: Sendable { let startTime: UInt64; let groupID: String; let cpu: UInt64; let gpu: UInt64? }
    private struct Aggregate: Sendable {
        let groupID: String
        let name: String
        let iconPath: String?
        var representativePID: Int32
        var value: UInt64
    }
    private var timestamp: UInt64?
    private var baselines: [Int32: Baseline] = [:]

    mutating func reset() -> ResourceConsumerMetric { timestamp = nil; baselines.removeAll(); return .inactive }
    mutating func consume(_ reading: ConsumerUsageReading?) -> ResourceConsumerMetric {
        guard let reading, !reading.records.isEmpty, Set(reading.records.map(\.pid)).count == reading.records.count else { timestamp = nil; baselines.removeAll(); return .init(cpu: .unavailable, memory: .unavailable) }
        guard Self.validateGroups(reading.records) else {
            timestamp = nil; baselines.removeAll()
            return .init(cpu: .unavailable, memory: .unavailable)
        }
        let memory: ResourceConsumerSection<ResourceConsumerMemoryEntry>
        if let memoryGroups = Self.aggregate(reading.records, value: \.physicalFootprintBytes) {
            memory = .available(Array(memoryGroups.sorted(by: Self.aggregateOrder).prefix(5).map(Self.memoryEntry)))
        } else {
            memory = .unavailable
        }
        guard let priorTimestamp = timestamp, reading.monotonicNanoseconds > priorTimestamp else {
            advanceBaselines(with: reading)
            return .init(cpu: .measuring, memory: memory)
        }
        let elapsed = reading.monotonicNanoseconds - priorTimestamp
        var cpuDeltas: [(ConsumerUsageRecord, UInt64)] = []
        var gpuDeltas: [(ConsumerUsageRecord, UInt64)] = []
        for record in reading.records {
            guard let prior = baselines[record.pid], prior.startTime == record.startTime, prior.groupID == record.groupID else { continue }
            if record.cumulativeCPUTimeNanoseconds >= prior.cpu {
                cpuDeltas.append((record, record.cumulativeCPUTimeNanoseconds - prior.cpu))
            }
            if let priorGPU = prior.gpu, let currentGPU = record.cumulativeGPUTimeNanoseconds, currentGPU >= priorGPU {
                gpuDeltas.append((record, currentGPU - priorGPU))
            }
        }
        advanceBaselines(with: reading)
        let gpuPercentByPID = Dictionary(uniqueKeysWithValues: gpuDeltas.compactMap { record, value -> (Int32, Double)? in
            let percent = Double(value) / Double(elapsed) * 100
            guard percent.isFinite, percent >= 0 else { return nil }
            return (record.pid, percent)
        })
        let cpuRows = cpuDeltas.compactMap { record, value -> ResourceConsumerCPUEntry? in
            let percent = Double(value) / Double(elapsed) * 100
            guard percent.isFinite, percent >= 0 else { return nil }
            return .init(pid: record.pid, name: record.processName, percent: percent, gpuPercent: gpuPercentByPID[record.pid], iconPath: record.iconPath)
        }
        let ranked = cpuRows.sorted(by: Self.computeOrder).prefix(5)
        return .init(cpu: ranked.isEmpty ? .measuring : .available(Array(ranked)), memory: memory)
    }
    private mutating func advanceBaselines(with reading: ConsumerUsageReading) {
        timestamp = reading.monotonicNanoseconds
        baselines = Dictionary(uniqueKeysWithValues: reading.records.map { ($0.pid, Baseline(startTime: $0.startTime, groupID: $0.groupID, cpu: $0.cumulativeCPUTimeNanoseconds, gpu: $0.cumulativeGPUTimeNanoseconds)) })
    }
    private static func aggregate(_ records: [ConsumerUsageRecord], value: KeyPath<ConsumerUsageRecord, UInt64>) -> [Aggregate]? { aggregate(records, values: records.map { $0[keyPath: value] }) }
    private static func validateGroups(_ records: [ConsumerUsageRecord]) -> Bool {
        var names: [String: String] = [:]
        for record in records {
            guard !record.groupID.isEmpty, !record.name.isEmpty, !record.processName.isEmpty else { return false }
            if let name = names[record.groupID], name != record.name { return false }
            names[record.groupID] = record.name
        }
        return true
    }
    private static func aggregate(_ records: [ConsumerUsageRecord], values: [UInt64]) -> [Aggregate]? {
        guard records.count == values.count else { return nil }
        var aggregates: [String: Aggregate] = [:]
        for (record, value) in zip(records, values) {
            guard !record.groupID.isEmpty, !record.name.isEmpty else { return nil }
            if var existing = aggregates[record.groupID] {
                guard existing.name == record.name, existing.iconPath == record.iconPath else { return nil }
                let sum = existing.value.addingReportingOverflow(value)
                guard !sum.overflow else { return nil }
                existing.value = sum.partialValue
                existing.representativePID = min(existing.representativePID, record.pid)
                aggregates[record.groupID] = existing
            } else {
                aggregates[record.groupID] = .init(groupID: record.groupID, name: record.name, iconPath: record.iconPath, representativePID: record.pid, value: value)
            }
        }
        return Array(aggregates.values)
    }
    private static func memoryEntry(_ group: Aggregate) -> ResourceConsumerMemoryEntry { .init(pid: group.representativePID, name: group.name, physicalFootprintBytes: group.value, iconPath: group.iconPath) }
    private static func nameOrder(_ lhs: String, _ rhs: String) -> Bool { lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) }
    private static func aggregateOrder(_ lhs: Aggregate, _ rhs: Aggregate) -> Bool { lhs.value != rhs.value ? lhs.value > rhs.value : lhs.name != rhs.name ? nameOrder(lhs.name, rhs.name) : lhs.groupID < rhs.groupID }
    private static func computeOrder(_ lhs: ResourceConsumerCPUEntry, _ rhs: ResourceConsumerCPUEntry) -> Bool {
        // Max keeps the largest load visible regardless of the unit carrying it.
        let lhsLoad = max(lhs.percent, lhs.gpuPercent ?? 0); let rhsLoad = max(rhs.percent, rhs.gpuPercent ?? 0)
        return lhsLoad != rhsLoad ? lhsLoad > rhsLoad : lhs.percent != rhs.percent ? lhs.percent > rhs.percent : lhs.name != rhs.name ? nameOrder(lhs.name, rhs.name) : lhs.pid < rhs.pid
    }
}
