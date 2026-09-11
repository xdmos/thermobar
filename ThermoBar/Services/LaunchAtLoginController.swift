import ServiceManagement

enum LaunchAtLoginStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    case notFound

    init(serviceStatus: SMAppService.Status) {
        switch serviceStatus {
        case .enabled: self = .enabled
        case .requiresApproval: self = .requiresApproval
        case .notRegistered: self = .notRegistered
        case .notFound: self = .notFound
        @unknown default: self = .notFound
        }
    }
}

@MainActor
protocol LaunchAtLoginService: AnyObject {
    func currentStatus() -> LaunchAtLoginStatus
    func register() throws
    func unregister() throws
    func openSystemSettingsLoginItems()
}

@MainActor
private final class SystemLaunchAtLoginService: LaunchAtLoginService {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    func currentStatus() -> LaunchAtLoginStatus {
        LaunchAtLoginStatus(serviceStatus: service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }

    func openSystemSettingsLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

@MainActor
final class LaunchAtLoginController {
    private let service: any LaunchAtLoginService
    private(set) var status: LaunchAtLoginStatus

    init(service: any LaunchAtLoginService = SystemLaunchAtLoginService()) {
        self.service = service
        status = service.currentStatus()
    }

    @discardableResult
    func refreshStatus() -> LaunchAtLoginStatus {
        let current = service.currentStatus()
        status = current
        return current
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> LaunchAtLoginStatus {
        if enabled {
            try? service.register()
        } else {
            try? service.unregister()
        }
        return refreshStatus()
    }

    @discardableResult
    func openApprovalSettingsIfNeeded() -> Bool {
        guard refreshStatus() == .requiresApproval else { return false }
        service.openSystemSettingsLoginItems()
        return true
    }
}
