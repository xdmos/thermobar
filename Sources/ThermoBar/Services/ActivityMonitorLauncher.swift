import AppKit

@MainActor
final class ActivityMonitorLauncher {
    typealias OpenApplication = @MainActor (URL) -> Void

    static let applicationURL = URL(
        fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app",
        isDirectory: true
    )

    private let openApplication: OpenApplication

    init(openApplication: OpenApplication? = nil) {
        self.openApplication = openApplication ?? { url in
            NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
        }
    }

    func open() {
        openApplication(Self.applicationURL)
    }
}
