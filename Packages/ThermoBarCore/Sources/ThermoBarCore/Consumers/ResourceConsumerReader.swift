import Darwin

struct ResourceConsumerReader: Sendable {
    static let minimumPIDCapacity = 64
    static let PIDCapacitySlack = 64
    static let maximumPIDCapacity = 32_768
    private static let pathCapacity = 4_096

    struct NativeUsage: Sendable { let user: UInt64; let system: UInt64; let footprint: UInt64?; let startTime: UInt64 }
    struct Dependencies: Sendable {
        let count: @Sendable () -> Int32
        let fill: @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32
        let usage: @Sendable (Int32) -> NativeUsage?
        let shortName: @Sendable (Int32) -> String?
        let path: @Sendable (Int32) -> String?
        let gpuUsage: @Sendable () -> [Int32: UInt64]
        /// Cumulative CPU nanoseconds for processes that refuse `usage`.
        let deniedCPUTimes: @Sendable () -> [Int32: UInt64]
        /// Start time for processes that refuse `usage`; compared only for equality.
        let startTime: @Sendable (Int32) -> UInt64?
        let clock: @Sendable () -> UInt64

        init(
            count: @escaping @Sendable () -> Int32,
            fill: @escaping @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32,
            usage: @escaping @Sendable (Int32) -> NativeUsage?,
            shortName: @escaping @Sendable (Int32) -> String?,
            path: @escaping @Sendable (Int32) -> String?,
            gpuUsage: @escaping @Sendable () -> [Int32: UInt64] = { [:] },
            deniedCPUTimes: @escaping @Sendable () -> [Int32: UInt64] = { [:] },
            startTime: @escaping @Sendable (Int32) -> UInt64? = { _ in nil },
            clock: @escaping @Sendable () -> UInt64
        ) {
            self.count = count; self.fill = fill; self.usage = usage; self.shortName = shortName; self.path = path; self.gpuUsage = gpuUsage; self.deniedCPUTimes = deniedCPUTimes; self.startTime = startTime; self.clock = clock
        }
    }
    private let dependencies: Dependencies

    private enum Identity: Equatable, Sendable {
        case path(groupID: String, name: String, processName: String, iconPath: String)
        case fallback(name: String)

        func resolved(pid: Int32, startTime: UInt64) -> (groupID: String, name: String, processName: String, iconPath: String?) {
            switch self {
            case let .path(groupID, name, processName, iconPath): (groupID, name, processName, iconPath)
            case let .fallback(name): ("pid:\(pid):\(startTime)", name, name, nil)
            }
        }
    }

    init() {
        dependencies = .init(
            count: { proc_listallpids(nil, 0) },
            fill: { pointer, byteCount in proc_listallpids(pointer, byteCount) },
            usage: { pid in
                var info = rusage_info_v4()
                let result = withUnsafeMutablePointer(to: &info) { pointer in pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) } }
                guard result == 0 else { return nil }
                // ri_user_time and ri_system_time are mach absolute-time units, not
                // nanoseconds; the calculator divides them by a real-nanosecond elapsed
                // time, so they must be converted at this boundary. ri_proc_start_abstime
                // stays raw on purpose — it is only ever compared for equality, to detect
                // a recycled PID, and converting it would cost precision for nothing.
                guard
                    let user = MonotonicClock.nanoseconds(machTicks: info.ri_user_time),
                    let system = MonotonicClock.nanoseconds(machTicks: info.ri_system_time)
                else { return nil }
                return .init(user: user, system: system, footprint: info.ri_phys_footprint, startTime: info.ri_proc_start_abstime)
            },
            // `proc_name` documents a buffer matching proc_bsdinfo.pbi_name:
            // 2 * MAXCOMLEN bytes. It returns strlen, leaving the terminating NUL
            // at buffer[result], just as proc_pidpath does.
            shortName: { pid in Self.string(capacity: Int(2 * MAXCOMLEN)) { proc_name(pid, $0, UInt32(2 * MAXCOMLEN)) } },
            path: { pid in Self.string(capacity: Self.pathCapacity) { proc_pidpath(pid, $0, UInt32(Self.pathCapacity)) } },
            gpuUsage: { GPUClientUsageReader().read() },
            deniedCPUTimes: { ProcessCPUTimeReader().read() },
            startTime: { pid in Self.startTime(pid: pid) },
            clock: { MonotonicClock.nowNanoseconds() }
        )
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func read() -> ConsumerUsageReading? {
        guard let pids = enumerate() else { return nil }
        let gpuUsage = dependencies.gpuUsage()
        // Processes owned by another user refuse proc_pid_rusage. Their CPU time comes
        // from the fallback, loaded at most once per reading and only when needed,
        // because it costs a process launch. They carry no footprint: nothing
        // unprivileged reports one, and an invented value would distort the RAM list.
        var deniedCPUTimes: [Int32: UInt64]?
        var records: [ConsumerUsageRecord] = []
        var seen = Set<Int32>()
        for pid in pids where pid > 0 && seen.insert(pid).inserted {
            let before = identity(for: pid)
            let usage: NativeUsage
            if let native = dependencies.usage(pid) {
                usage = native
            } else {
                if deniedCPUTimes == nil { deniedCPUTimes = dependencies.deniedCPUTimes() }
                guard let cpu = deniedCPUTimes?[pid], let start = dependencies.startTime(pid) else { continue }
                usage = .init(user: cpu, system: 0, footprint: nil, startTime: start)
            }
            guard let before, let after = identity(for: pid) else { continue }
            let beforeResolved = before.resolved(pid: pid, startTime: usage.startTime)
            let afterResolved = after.resolved(pid: pid, startTime: usage.startTime)
            guard beforeResolved.groupID == afterResolved.groupID, beforeResolved.name == afterResolved.name, beforeResolved.processName == afterResolved.processName, beforeResolved.iconPath == afterResolved.iconPath else { continue }
            let sum = usage.user.addingReportingOverflow(usage.system)
            guard !sum.overflow else { continue }
            let total = sum.partialValue
            records.append(.init(pid: pid, startTime: usage.startTime, groupID: beforeResolved.groupID, name: beforeResolved.name, processName: beforeResolved.processName, iconPath: beforeResolved.iconPath, cumulativeCPUTimeNanoseconds: total, physicalFootprintBytes: usage.footprint, cumulativeGPUTimeNanoseconds: gpuUsage[pid]))
        }
        return .init(monotonicNanoseconds: dependencies.clock(), records: records)
    }
    private func enumerate() -> [Int32]? {
        let count = dependencies.count()
        guard count >= 0, count <= Int32(Self.maximumPIDCapacity) else { return nil }
        var capacity = min(Self.maximumPIDCapacity, max(Self.minimumPIDCapacity, Int(count) + Self.PIDCapacitySlack))
        for attempt in 0...1 {
            var pids = [Int32](repeating: 0, count: capacity)
            let filled = pids.withUnsafeMutableBytes { dependencies.fill($0.baseAddress, Int32($0.count)) }
            guard filled >= 0 else { return nil }
            let value = Int(filled)
            guard value <= capacity else { return nil }
            if value < capacity { return Array(pids.prefix(value)) }
            guard attempt == 0, capacity < Self.maximumPIDCapacity else { return nil }
            capacity = min(Self.maximumPIDCapacity, capacity + Self.PIDCapacitySlack)
        }
        return nil
    }
    /// Start time from sysctl, which answers for processes of every user. Like
    /// ri_proc_start_abstime it only detects a recycled PID by equality, so the two
    /// clocks are never compared with each other; a process that moves between the
    /// two sources simply restarts its CPU baseline.
    private static func startTime(pid: Int32) -> UInt64? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        let start = info.kp_proc.p_starttime
        guard start.tv_sec > 0, start.tv_usec >= 0 else { return nil }
        let microseconds = UInt64(start.tv_sec).multipliedReportingOverflow(by: 1_000_000)
        guard !microseconds.overflow else { return nil }
        let total = microseconds.partialValue.addingReportingOverflow(UInt64(start.tv_usec))
        return total.overflow ? nil : total.partialValue
    }

    private func identity(for pid: Int32) -> Identity? {
        if let path = dependencies.path(pid), let normalized = Self.normalize(path: path) {
            return normalized
        }
        guard let name = dependencies.shortName(pid), !name.isEmpty else { return nil }
        return .fallback(name: name)
    }

    private static func normalize(path: String) -> Identity? {
        guard path.first == "/" else { return nil }
        var components: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !components.isEmpty else { continue }
                components.removeLast()
            default: components.append(component)
            }
        }
        guard !components.isEmpty else { return nil }
        let normalized = "/" + components.joined(separator: "/")
        guard let filename = components.last, !filename.isEmpty else { return nil }
        if let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) {
            let appName = components[appIndex]
            let displayName = String(appName.dropLast(4))
            guard !displayName.isEmpty else { return nil }
            let appPath = "/" + components.prefix(through: appIndex).joined(separator: "/")
            return .path(groupID: "app:\(appPath)", name: displayName, processName: String(filename), iconPath: appPath)
        }
        return .path(groupID: "exe:\(normalized)", name: String(filename), processName: String(filename), iconPath: normalized)
    }
    private static func string(capacity: Int, call: (UnsafeMutablePointer<CChar>) -> Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: capacity)
        let result = buffer.withUnsafeMutableBufferPointer { call($0.baseAddress!) }
        return decodeString(buffer.map { UInt8(bitPattern: $0) }, result: result, capacity: capacity)
    }

    /// A deliberately narrow seam for validating the C-string contract independently
    /// of libproc. Native APIs return strlen, with the required NUL at precisely
    /// `buffer[result]`; only that bounded UTF-8 value becomes a process name.
    static func decodeString(_ bytes: [UInt8], result: Int32, capacity: Int) -> String? {
        guard capacity > 1, bytes.count >= capacity, result > 0, result < Int32(capacity) else { return nil }
        let prefix = bytes.prefix(capacity)
        let length = Int(result)
        guard prefix[prefix.index(prefix.startIndex, offsetBy: length)] == 0 else { return nil }
        return String(bytes: prefix.prefix(length), encoding: .utf8)
    }
}
