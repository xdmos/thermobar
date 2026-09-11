import Foundation

/// Reads cumulative CPU time for every process through `/bin/ps`.
///
/// `proc_pid_rusage` refuses processes owned by another user with EPERM, and those
/// include the heaviest consumers on a Mac: WindowServer, coreaudiod, launchd. No
/// unprivileged in-process API carries their CPU time — `PROC_PIDTASKINFO` is refused
/// the same way, and `sysctl(KERN_PROC)` answers but leaves every CPU field at zero,
/// even for the caller's own busy processes. `/bin/ps` is setuid root and ships with
/// macOS. One call costs about 10 ms of CPU, against about 1.1 s for `top -l 1`, and
/// its TIME column keeps a 10 ms resolution however long a process has run.
///
/// `ps` has no memory footprint (only RSS, which leaves out GPU and IOSurface memory),
/// so this reader supplies CPU time and nothing else.
struct ProcessCPUTimeReader: Sendable {
    static let executableURL = URL(fileURLWithPath: "/bin/ps")

    func read() -> [Int32: UInt64] {
        let process = Process()
        process.executableURL = Self.executableURL
        process.arguments = ["-A", "-o", "pid=,time="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [:] }
        // Drain before waiting: about a thousand rows overflow the pipe buffer, and a
        // child blocked writing to a full pipe never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) else { return [:] }
        return Self.parse(text)
    }

    /// Parses `ps -A -o pid=,time=` output. A row that is not exactly a positive PID
    /// followed by a well-formed TIME is skipped rather than guessed at.
    static func parse(_ text: String) -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2,
                  fields[0].allSatisfy(Self.isDigit),
                  let pid = Int32(fields[0]), pid > 0,
                  let time = nanoseconds(time: fields[1]) else { continue }
            result[pid] = time
        }
        return result
    }

    /// `ps` prints TIME as minutes, then seconds and hundredths — `700:09.66` is 700
    /// minutes and 9.66 seconds. Only that one form is accepted.
    static func nanoseconds(time: Substring) -> UInt64? {
        let clock = time.split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 2, !clock[0].isEmpty, clock[0].allSatisfy(Self.isDigit) else { return nil }
        let fraction = clock[1].split(separator: ".", omittingEmptySubsequences: false)
        guard fraction.count == 2,
              fraction[0].count == 2, fraction[0].allSatisfy(Self.isDigit),
              fraction[1].count == 2, fraction[1].allSatisfy(Self.isDigit),
              let minutes = UInt64(clock[0]),
              let seconds = UInt64(fraction[0]), seconds < 60,
              let hundredths = UInt64(fraction[1]) else { return nil }
        let minuteSeconds = minutes.multipliedReportingOverflow(by: 60)
        guard !minuteSeconds.overflow else { return nil }
        let wholeSeconds = minuteSeconds.partialValue.addingReportingOverflow(seconds)
        guard !wholeSeconds.overflow else { return nil }
        let wholeNanoseconds = wholeSeconds.partialValue.multipliedReportingOverflow(by: 1_000_000_000)
        guard !wholeNanoseconds.overflow else { return nil }
        let total = wholeNanoseconds.partialValue.addingReportingOverflow(hundredths * 10_000_000)
        return total.overflow ? nil : total.partialValue
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
