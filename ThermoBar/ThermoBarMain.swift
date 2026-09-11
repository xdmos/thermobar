import Foundation
import SwiftUI

@main
enum ThermoBarMain {
    @MainActor
    static func main() {
        if isHostingTests(environment: ProcessInfo.processInfo.environment) {
            TestHostApp.main()
        } else {
            ThermoBarApp.main()
        }
    }

    /// Xcode runs the unit tests inside the app. The real app would start sampling,
    /// open the floating panel, and write to the same preferences as an installed copy,
    /// so a test run launches an inert app instead.
    static func isHostingTests(environment: [String: String]) -> Bool {
        environment.keys.contains { $0.hasPrefix("XCTest") }
    }
}

private struct TestHostApp: App {
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
