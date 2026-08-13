import Foundation

struct ConsumerUsageRecord: Equatable, Sendable {
    let pid: Int32; let startTime: UInt64; let groupID: String; let name: String; let cumulativeCPUTimeNanoseconds: UInt64; let physicalFootprintBytes: UInt64
}
struct ConsumerUsageReading: Equatable, Sendable { let monotonicNanoseconds: UInt64; let records: [ConsumerUsageRecord] }

struct ResourceConsumerCalculator: Sendable {
    private struct Baseline: Sendable { let startTime: UInt64; let groupID: String; let cpu: UInt64 }
    private struct Aggregate: Sendable {
        let groupID: String
        let name: String
        var representativePID: Int32
        var value: UInt64
    }
    private struct CPUAggregate: Sendable {
        let aggregate: Aggregate
        let percent: Double
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
        let currentGroups = Dictionary(uniqueKeysWithValues: Self.metadata(for: reading.records).map { ($0.groupID, $0) })
        let memory: ResourceConsumerSection<ResourceConsumerMemoryEntry>
        if let memoryGroups = Self.aggregate(reading.records, value: \.physicalFootprintBytes) {
            memory = .available(Array(memoryGroups.sorted(by: Self.aggregateOrder).prefix(3).map(Self.memoryEntry)))
        } else {
            memory = .unavailable
        }
        guard let priorTimestamp = timestamp, reading.monotonicNanoseconds > priorTimestamp else {
            advanceBaselines(with: reading)
            return .init(cpu: .measuring, memory: memory)
        }
        let elapsed = reading.monotonicNanoseconds - priorTimestamp
        var cpuDeltas: [(ConsumerUsageRecord, UInt64)] = []
        for record in reading.records {
            guard let prior = baselines[record.pid], prior.startTime == record.startTime, prior.groupID == record.groupID, record.cumulativeCPUTimeNanoseconds >= prior.cpu else { continue }
            cpuDeltas.append((record, record.cumulativeCPUTimeNanoseconds - prior.cpu))
        }
        advanceBaselines(with: reading)
        guard let cpuGroups = Self.aggregate(cpuDeltas.map(\.0), values: cpuDeltas.map(\.1)) else {
            return .init(cpu: .unavailable, memory: memory)
        }
        let cpuRows = cpuGroups.compactMap { group -> CPUAggregate? in
            let percent = Double(group.value) / Double(elapsed) * 100
            guard percent.isFinite, percent >= 0, let current = currentGroups[group.groupID] else { return nil }
            return .init(aggregate: .init(groupID: group.groupID, name: group.name, representativePID: current.representativePID, value: group.value), percent: percent)
        }
        let ranked = cpuRows.sorted(by: Self.cpuAggregateOrder).prefix(3).map { ResourceConsumerCPUEntry(pid: $0.aggregate.representativePID, name: $0.aggregate.name, percent: $0.percent) }
        return .init(cpu: ranked.isEmpty ? .measuring : .available(Array(ranked)), memory: memory)
    }
    private mutating func advanceBaselines(with reading: ConsumerUsageReading) {
        timestamp = reading.monotonicNanoseconds
        baselines = Dictionary(uniqueKeysWithValues: reading.records.map { ($0.pid, Baseline(startTime: $0.startTime, groupID: $0.groupID, cpu: $0.cumulativeCPUTimeNanoseconds)) })
    }
    private static func aggregate(_ records: [ConsumerUsageRecord], value: KeyPath<ConsumerUsageRecord, UInt64>) -> [Aggregate]? { aggregate(records, values: records.map { $0[keyPath: value] }) }
    private static func validateGroups(_ records: [ConsumerUsageRecord]) -> Bool {
        var names: [String: String] = [:]
        for record in records {
            guard !record.groupID.isEmpty, !record.name.isEmpty else { return false }
            if let name = names[record.groupID], name != record.name { return false }
            names[record.groupID] = record.name
        }
        return true
    }
    private static func metadata(for records: [ConsumerUsageRecord]) -> [Aggregate] {
        var metadata: [String: Aggregate] = [:]
        for record in records {
            if var existing = metadata[record.groupID] {
                existing.representativePID = min(existing.representativePID, record.pid)
                metadata[record.groupID] = existing
            } else {
                metadata[record.groupID] = .init(groupID: record.groupID, name: record.name, representativePID: record.pid, value: 0)
            }
        }
        return Array(metadata.values)
    }
    private static func aggregate(_ records: [ConsumerUsageRecord], values: [UInt64]) -> [Aggregate]? {
        guard records.count == values.count else { return nil }
        var aggregates: [String: Aggregate] = [:]
        for (record, value) in zip(records, values) {
            guard !record.groupID.isEmpty, !record.name.isEmpty else { return nil }
            if var existing = aggregates[record.groupID] {
                guard existing.name == record.name else { return nil }
                let sum = existing.value.addingReportingOverflow(value)
                guard !sum.overflow else { return nil }
                existing.value = sum.partialValue
                existing.representativePID = min(existing.representativePID, record.pid)
                aggregates[record.groupID] = existing
            } else {
                aggregates[record.groupID] = .init(groupID: record.groupID, name: record.name, representativePID: record.pid, value: value)
            }
        }
        return Array(aggregates.values)
    }
    private static func memoryEntry(_ group: Aggregate) -> ResourceConsumerMemoryEntry { .init(pid: group.representativePID, name: group.name, physicalFootprintBytes: group.value) }
    private static func nameOrder(_ lhs: String, _ rhs: String) -> Bool { lhs.unicodeScalars.lexicographicallyPrecedes(rhs.unicodeScalars) }
    private static func aggregateOrder(_ lhs: Aggregate, _ rhs: Aggregate) -> Bool { lhs.value != rhs.value ? lhs.value > rhs.value : lhs.name != rhs.name ? nameOrder(lhs.name, rhs.name) : lhs.groupID < rhs.groupID }
    private static func cpuAggregateOrder(_ lhs: CPUAggregate, _ rhs: CPUAggregate) -> Bool { lhs.percent != rhs.percent ? lhs.percent > rhs.percent : lhs.aggregate.name != rhs.aggregate.name ? nameOrder(lhs.aggregate.name, rhs.aggregate.name) : lhs.aggregate.groupID < rhs.aggregate.groupID }
}
