import Testing
import Darwin
@testable import ThermoBarCore

@Test func readerUsesOneBoundedRetryAndSkipsBadEntries() {
    let reader = ResourceConsumerReader(dependencies: .init(count: { 1 }, fill: { pointer, _ in pointer?.assumingMemoryBound(to: Int32.self)[0] = 42; return 1 }, usage: { _ in .init(user: 2, system: 3, footprint: 4, startTime: 5) }, shortName: { _ in "ReaderTest" }, path: { _ in nil }, clock: { 99 }))
    #expect(reader.read() == .init(monotonicNanoseconds: 99, records: [.init(pid: 42, startTime: 5, groupID: "pid:42:5", name: "ReaderTest", cumulativeCPUTimeNanoseconds: 5, physicalFootprintBytes: 4)]))
}

@Test func readerRejectsEnumerationFailuresAndAllowsEmptyPass() {
    let bad = ResourceConsumerReader(dependencies: .init(count: { -1 }, fill: { _, _ in 0 }, usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 1 }))
    #expect(bad.read() == nil)
    let empty = ResourceConsumerReader(dependencies: .init(count: { 0 }, fill: { _, _ in 0 }, usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 42 }))
    #expect(empty.read() == .init(monotonicNanoseconds: 42, records: []))
}

@Test func readerFallsBackToPathAndSkipsOverflow() {
    let reader = ResourceConsumerReader(dependencies: .init(count: { 2 }, fill: { pointer, _ in pointer?.assumingMemoryBound(to: Int32.self)[0] = 1; pointer?.assumingMemoryBound(to: Int32.self)[1] = 2; return 2 }, usage: { pid in pid == 1 ? .init(user: .max, system: 1, footprint: 1, startTime: 1) : .init(user: 1, system: 2, footprint: 3, startTime: 4) }, shortName: { _ in nil }, path: { _ in "/System/Library/WindowServer" }, clock: { 7 }))
    #expect(reader.read()?.records == [.init(pid: 2, startTime: 4, groupID: "exe:/System/Library/WindowServer", name: "WindowServer", cumulativeCPUTimeNanoseconds: 3, physicalFootprintBytes: 3)])
}

@Test func readerRejectsExcessiveCountAndFillFailures() {
    let excessive = ResourceConsumerReader(dependencies: .init(count: { Int32(ResourceConsumerReader.maximumPIDCapacity) + 1 }, fill: { _, _ in 0 }, usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 1 }))
    let fillFailure = ResourceConsumerReader(dependencies: .init(count: { 1 }, fill: { _, _ in -1 }, usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 1 }))
    #expect(excessive.read() == nil)
    #expect(fillFailure.read() == nil)
}

@Test func readerRetriesExactlyOnceWhenTheFirstBufferIsFull() {
    let recorder = ReaderCallRecorder()
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 0 },
        fill: { pointer, byteCount in
            recorder.byteCounts.append(byteCount)
            let capacity = Int(byteCount) / MemoryLayout<Int32>.stride
            pointer?.assumingMemoryBound(to: Int32.self)[0] = 9
            return Int32(capacity == ResourceConsumerReader.minimumPIDCapacity ? capacity : 1)
        },
        usage: { _ in .init(user: 1, system: 1, footprint: 1, startTime: 1) }, shortName: { _ in "one" }, path: { _ in nil }, clock: { 17 }
    ))
    #expect(reader.read()?.records.count == 1)
    #expect(recorder.byteCounts == [Int32(ResourceConsumerReader.minimumPIDCapacity * MemoryLayout<Int32>.stride), Int32((ResourceConsumerReader.minimumPIDCapacity + ResourceConsumerReader.PIDCapacitySlack) * MemoryLayout<Int32>.stride)])
}

@Test func readerRejectsASecondFullBufferAndMaximumCapacity() {
    let recorder = ReaderCallRecorder()
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 0 }, fill: { _, byteCount in recorder.byteCounts.append(byteCount); return Int32(Int(byteCount) / MemoryLayout<Int32>.stride) },
        usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 1 }
    ))
    #expect(reader.read() == nil)
    let maximum = ResourceConsumerReader(dependencies: .init(
        count: { Int32(ResourceConsumerReader.maximumPIDCapacity) }, fill: { _, bytes in Int32(Int(bytes) / MemoryLayout<Int32>.stride) },
        usage: { _ in nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { 1 }
    ))
    #expect(maximum.read() == nil)
    #expect(recorder.byteCounts.count == 2)
}

@Test func readerDeduplicatesAndSkipsInvalidPIDsAndPerPIDFailures() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 4 }, fill: { pointer, _ in
            let pids = pointer!.assumingMemoryBound(to: Int32.self); pids[0] = 0; pids[1] = 7; pids[2] = 7; pids[3] = 8; return 4
        }, usage: { pid in pid == 7 ? .init(user: 1, system: 2, footprint: 3, startTime: 4) : nil },
        shortName: { _ in "name" }, path: { _ in nil }, clock: { 88 }
    ))
    #expect(reader.read() == .init(monotonicNanoseconds: 88, records: [.init(pid: 7, startTime: 4, groupID: "pid:7:4", name: "name", cumulativeCPUTimeNanoseconds: 3, physicalFootprintBytes: 3)]))
}

@Test func readerRejectsInvalidAndUnterminatedNativeUTF8() {
    // libproc returns strlen: the NUL belongs at result, not before it.
    #expect(ResourceConsumerReader.decodeString([65, 0], result: 1, capacity: 2) == "A")
    #expect(ResourceConsumerReader.decodeString([0xFF, 0], result: 1, capacity: 2) == nil)
    #expect(ResourceConsumerReader.decodeString([65, 66, 0], result: 1, capacity: 3) == nil)
    #expect(ResourceConsumerReader.decodeString([65, 0, 0], result: 3, capacity: 3) == nil)
}

@Test func readerUsesEndOfPassNanosecondClockAndAllowsNoReadableProcesses() {
    let recorder = ReaderCallRecorder()
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 }, fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 9; return 1 },
        usage: { _ in recorder.didReadUsage = true; return nil }, shortName: { _ in nil }, path: { _ in nil }, clock: { recorder.didReadUsage ? 999 : 0 }
    ))
    #expect(reader.read() == .init(monotonicNanoseconds: 999, records: []))
}

@Test(.enabled(if: getenv("THERMOBAR_LIVE_CONSUMER_READER") != nil))
func liveReaderReturnsOnlySafeRecordsWhenEnabled() {
    guard let reading = ResourceConsumerReader().read() else {
        Issue.record("libproc enumeration failed")
        return
    }
    #expect(reading.monotonicNanoseconds > 0)
    #expect(Set(reading.records.map(\.pid)).count == reading.records.count)
    #expect(reading.records.allSatisfy { $0.pid > 0 && !$0.name.isEmpty })
}

@Test func readerUsesOutermostAppBundleAndLexicallyNormalizesNestedHelpers() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 }, fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 42; return 1 },
        usage: { _ in .init(user: 2, system: 3, footprint: 4, startTime: 5) }, shortName: { _ in "ignored" },
        path: { _ in "/Applications/./Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/../MacOS/Google Chrome Helper" }, clock: { 99 }
    ))
    #expect(reader.read()?.records == [.init(pid: 42, startTime: 5, groupID: "app:/Applications/Google Chrome.app", name: "Google Chrome", cumulativeCPUTimeNanoseconds: 5, physicalFootprintBytes: 4)])
}

@Test func readerSeparatesMissingPathsByPIDAndStartTime() {
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 2 }, fill: { pointer, _ in let pids = pointer!.assumingMemoryBound(to: Int32.self); pids[0] = 1; pids[1] = 2; return 2 },
        usage: { pid in .init(user: 1, system: 2, footprint: 3, startTime: UInt64(pid)) }, shortName: { _ in "same" }, path: { _ in nil }, clock: { 7 }
    ))
    #expect(reader.read()?.records.map(\.groupID) == ["pid:1:1", "pid:2:2"])
}

@Test func readerSkipsPIDWhenIdentityChangesAcrossUsageRead() {
    let calls = ReaderPathRecorder()
    let reader = ResourceConsumerReader(dependencies: .init(
        count: { 1 }, fill: { pointer, _ in pointer!.assumingMemoryBound(to: Int32.self)[0] = 1; return 1 },
        usage: { _ in .init(user: 1, system: 2, footprint: 3, startTime: 4) }, shortName: { _ in nil },
        path: { _ in calls.next() }, clock: { 7 }
    ))
    #expect(reader.read()?.records == [])
}

private final class ReaderCallRecorder: @unchecked Sendable {
    var byteCounts: [Int32] = []
    var didReadUsage = false
}

private final class ReaderPathRecorder: @unchecked Sendable {
    private var paths = ["/Applications/One.app/Contents/MacOS/One", "/Applications/Two.app/Contents/MacOS/Two"]
    func next() -> String? { paths.removeFirst() }
}
