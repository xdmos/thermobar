import Darwin

struct ResourceConsumerReader: Sendable {
    static let minimumPIDCapacity = 64
    static let PIDCapacitySlack = 64
    static let maximumPIDCapacity = 32_768
    private static let pathCapacity = 4_096

    struct NativeUsage: Sendable { let user: UInt64; let system: UInt64; let footprint: UInt64; let startTime: UInt64 }
    struct Dependencies: Sendable {
        let count: @Sendable () -> Int32
        let fill: @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32
        let usage: @Sendable (Int32) -> NativeUsage?
        let shortName: @Sendable (Int32) -> String?
        let path: @Sendable (Int32) -> String?
        let gpuUsage: @Sendable () -> [Int32: UInt64]
        let clock: @Sendable () -> UInt64

        init(
            count: @escaping @Sendable () -> Int32,
            fill: @escaping @Sendable (UnsafeMutableRawPointer?, Int32) -> Int32,
            usage: @escaping @Sendable (Int32) -> NativeUsage?,
            shortName: @escaping @Sendable (Int32) -> String?,
            path: @escaping @Sendable (Int32) -> String?,
            gpuUsage: @escaping @Sendable () -> [Int32: UInt64] = { [:] },
            clock: @escaping @Sendable () -> UInt64
        ) {
            self.count = count; self.fill = fill; self.usage = usage; self.shortName = shortName; self.path = path; self.gpuUsage = gpuUsage; self.clock = clock
        }
    }
    private let dependencies: Dependencies

    private enum Identity: Equatable, Sendable {
        case path(groupID: String, name: String)
        case fallback(name: String)

        func resolved(pid: Int32, startTime: UInt64) -> (groupID: String, name: String) {
            switch self {
            case let .path(groupID, name): (groupID, name)
            case let .fallback(name): ("pid:\(pid):\(startTime)", name)
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
                return .init(user: info.ri_user_time, system: info.ri_system_time, footprint: info.ri_phys_footprint, startTime: info.ri_proc_start_abstime)
            },
            // `proc_name` documents a buffer matching proc_bsdinfo.pbi_name:
            // 2 * MAXCOMLEN bytes. It returns strlen, leaving the terminating NUL
            // at buffer[result], just as proc_pidpath does.
            shortName: { pid in Self.string(capacity: Int(2 * MAXCOMLEN)) { proc_name(pid, $0, UInt32(2 * MAXCOMLEN)) } },
            path: { pid in Self.string(capacity: Self.pathCapacity) { proc_pidpath(pid, $0, UInt32(Self.pathCapacity)) } },
            gpuUsage: { GPUClientUsageReader().read() },
            clock: { MonotonicClock.nowNanoseconds() }
        )
    }
    init(dependencies: Dependencies) { self.dependencies = dependencies }

    func read() -> ConsumerUsageReading? {
        guard let pids = enumerate() else { return nil }
        let gpuUsage = dependencies.gpuUsage()
        var records: [ConsumerUsageRecord] = []
        var seen = Set<Int32>()
        for pid in pids where pid > 0 && seen.insert(pid).inserted {
            let before = identity(for: pid)
            guard let usage = dependencies.usage(pid) else { continue }
            guard let before, let after = identity(for: pid) else { continue }
            let beforeResolved = before.resolved(pid: pid, startTime: usage.startTime)
            let afterResolved = after.resolved(pid: pid, startTime: usage.startTime)
            guard beforeResolved.groupID == afterResolved.groupID, beforeResolved.name == afterResolved.name else { continue }
            let sum = usage.user.addingReportingOverflow(usage.system)
            guard !sum.overflow else { continue }
            let total = sum.partialValue
            records.append(.init(pid: pid, startTime: usage.startTime, groupID: beforeResolved.groupID, name: beforeResolved.name, cumulativeCPUTimeNanoseconds: total, physicalFootprintBytes: usage.footprint, cumulativeGPUTimeNanoseconds: gpuUsage[pid]))
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
            return .path(groupID: "app:/" + components.prefix(through: appIndex).joined(separator: "/"), name: displayName)
        }
        return .path(groupID: "exe:\(normalized)", name: String(filename))
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
