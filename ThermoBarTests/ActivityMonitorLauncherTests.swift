import Foundation
import Testing
@testable import ThermoBar

@Test @MainActor
func activityMonitorLauncherOpensTheExactSystemApplicationOnce() {
    var received: [URL] = []
    let launcher = ActivityMonitorLauncher(openApplication: { received.append($0) })

    launcher.open()

    #expect(received == [ActivityMonitorLauncher.applicationURL])
    #expect(received.first?.path == "/System/Applications/Utilities/Activity Monitor.app")
}
