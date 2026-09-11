public enum SamplingMode: Equatable, Sendable {
    case visible
    case menuBarOnly
    case sleeping

    var intervalNanoseconds: UInt64? {
        switch self {
        case .visible: 2_000_000_000
        case .menuBarOnly: 10_000_000_000
        case .sleeping: nil
        }
    }
}

public enum SnapshotFreshness {
    public static func isFresh(snapshot: SystemSnapshot, mode: SamplingMode, nowNanoseconds: UInt64) -> Bool {
        guard nowNanoseconds >= snapshot.monotonicNanoseconds else {
            return false
        }
        return isFresh(ageNanoseconds: nowNanoseconds - snapshot.monotonicNanoseconds, mode: mode)
    }

    public static func isFresh(ageNanoseconds: UInt64, mode: SamplingMode) -> Bool {
        guard let maximumAge = maximumAge(for: mode) else { return false }
        return ageNanoseconds <= maximumAge
    }

    public static func isFresh(_ snapshot: SystemSnapshot, mode: SamplingMode, nowNanoseconds: UInt64) -> Bool {
        isFresh(snapshot: snapshot, mode: mode, nowNanoseconds: nowNanoseconds)
    }

    /// The first monotonic nanosecond at which a snapshot is stale.
    /// Saturates rather than wrapping when the clock is close to `UInt64.max`.
    public static func staleDeadlineNanoseconds(snapshot: SystemSnapshot, mode: SamplingMode) -> UInt64? {
        guard let maximumAge = maximumAge(for: mode) else { return nil }
        let inclusiveAge = maximumAge.addingReportingOverflow(1)
        guard !inclusiveAge.overflow else { return .max }
        let deadline = snapshot.monotonicNanoseconds.addingReportingOverflow(inclusiveAge.partialValue)
        return deadline.overflow ? .max : deadline.partialValue
    }

    private static func maximumAge(for mode: SamplingMode) -> UInt64? {
        switch mode {
        case .visible: 6_000_000_000
        case .menuBarOnly: 30_000_000_000
        case .sleeping: nil
        }
    }
}
