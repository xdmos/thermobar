public struct CPUTicks: Equatable, Sendable {
    public let user: UInt64
    public let system: UInt64
    public let nice: UInt64
    public let idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }
}

public struct CPUUsageCalculator: Sendable {
    private var previous: [CPUTicks]?

    public init() {}

    public mutating func reset() {
        previous = nil
    }

    public mutating func consume(_ current: [CPUTicks]) -> Double? {
        defer { previous = current }

        guard let previous, !current.isEmpty, previous.count == current.count else {
            return nil
        }

        var busyDelta: UInt64 = 0
        var totalDelta: UInt64 = 0

        for (old, new) in zip(previous, current) {
            guard
                let userDelta = difference(new.user, old.user),
                let systemDelta = difference(new.system, old.system),
                let niceDelta = difference(new.nice, old.nice),
                let idleDelta = difference(new.idle, old.idle),
                let busy = sum(userDelta, systemDelta),
                let cpuBusyDelta = sum(busy, niceDelta),
                let cpuTotalDelta = sum(cpuBusyDelta, idleDelta),
                let nextBusyDelta = sum(busyDelta, cpuBusyDelta),
                let nextTotalDelta = sum(totalDelta, cpuTotalDelta)
            else {
                return nil
            }

            busyDelta = nextBusyDelta
            totalDelta = nextTotalDelta
        }

        guard totalDelta != 0 else {
            return nil
        }

        let percent = 100 * Double(busyDelta) / Double(totalDelta)
        guard percent.isFinite, (0 ... 100).contains(percent) else {
            return nil
        }

        return percent
    }

    private func difference(_ new: UInt64, _ old: UInt64) -> UInt64? {
        let result = new.subtractingReportingOverflow(old)
        return result.overflow ? nil : result.partialValue
    }

    private func sum(_ lhs: UInt64, _ rhs: UInt64) -> UInt64? {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? nil : result.partialValue
    }
}
