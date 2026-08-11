import AppKit

@MainActor
final class WorkspaceLifecycle {
    enum Event: Equatable, Sendable {
        case willSleep
        case didWake
        case didActivate
        case screenParametersChanged
    }

    private let handler: @MainActor @Sendable (Event) -> Void
    private let workspaceNotificationCenter: NotificationCenter
    private let applicationCenter: NotificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var applicationObservers: [NSObjectProtocol] = []

    init(
        workspace: NSWorkspace = .shared,
        applicationCenter: NotificationCenter = .default,
        handler: @escaping @MainActor @Sendable (Event) -> Void
    ) {
        self.handler = handler
        workspaceNotificationCenter = workspace.notificationCenter
        self.applicationCenter = applicationCenter

        observeWorkspace(NSWorkspace.willSleepNotification, object: workspace, as: .willSleep)
        observeWorkspace(NSWorkspace.didWakeNotification, object: workspace, as: .didWake)
        observeApplication(NSApplication.didBecomeActiveNotification, as: .didActivate)
        observeApplication(NSApplication.didChangeScreenParametersNotification, as: .screenParametersChanged)
    }

    isolated deinit {
        workspaceObservers.forEach(workspaceNotificationCenter.removeObserver)
        applicationObservers.forEach(applicationCenter.removeObserver)
    }

    private func observeWorkspace(_ name: Notification.Name, object: AnyObject?, as event: Event) {
        workspaceObservers.append(observe(on: workspaceNotificationCenter, name: name, object: object, event: event))
    }

    private func observeApplication(_ name: Notification.Name, as event: Event) {
        applicationObservers.append(observe(on: applicationCenter, name: name, object: nil, event: event))
    }

    private func observe(on center: NotificationCenter, name: Notification.Name, object: AnyObject?, event: Event) -> NSObjectProtocol {
        center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handler(event)
            }
        }
    }
}
