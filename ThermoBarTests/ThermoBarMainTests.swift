import Foundation
import Testing
@testable import ThermoBar

@Test func testRunsAreDetectedInsideTheHostApp() {
    #expect(ThermoBarMain.isHostingTests(environment: ProcessInfo.processInfo.environment))
}

@Test func normalLaunchesAreNotTreatedAsTestRuns() {
    #expect(!ThermoBarMain.isHostingTests(environment: [:]))
    #expect(!ThermoBarMain.isHostingTests(environment: ["HOME": "/Users/example", "PATH": "/usr/bin"]))
}
