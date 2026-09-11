import Testing
@testable import ThermoBarCore

@Test func psTimeIsMinutesSecondsAndHundredths() {
    #expect(ProcessCPUTimeReader.nanoseconds(time: "0:01.01") == 1_010_000_000)
    #expect(ProcessCPUTimeReader.nanoseconds(time: "18:14.71") == 1_094_710_000_000)
    #expect(ProcessCPUTimeReader.nanoseconds(time: "700:09.66") == 42_009_660_000_000)
}

@Test func psTimeRejectsEveryFormButTheOnePsPrints() {
    let malformed = ["", ":00.00", "1:00", "1:60.00", "1:00.0", "1:00.000", "+1:00.00",
                     "1:2:03.00", "01:00:00", "a:00.00", "1:0a.00", "1:00.a0", "184467440737:00.00"]
    for time in malformed {
        #expect(ProcessCPUTimeReader.nanoseconds(time: Substring(time)) == nil, "accepted \(time)")
    }
}

@Test func psOutputKeepsWellFormedRowsAndSkipsTheRest() {
    let output = """
      607 700:09.66
        1  18:14.71
        0   0:00.00
        x   1:00.00
       42
       88   1:00.00 extra
       -3   0:01.00
      +9   0:01.00
    """
    #expect(ProcessCPUTimeReader.parse(output) == [607: 42_009_660_000_000, 1: 1_094_710_000_000])
}

/// Runs the real `/bin/ps`. launchd is PID 1, owned by root, and has accumulated CPU
/// time on any booted Mac, so a reading without it means the subprocess did not run
/// or its output was not understood.
@Test func psReportsProcessesOwnedByRoot() {
    let times = ProcessCPUTimeReader().read()
    #expect((times[1] ?? 0) > 0)
    #expect(times.count > 10)
}
