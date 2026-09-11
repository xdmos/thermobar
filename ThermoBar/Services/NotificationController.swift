import Foundation
@preconcurrency import UserNotifications
import ThermoBarCore

enum NotificationAuthorizationState: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    case restricted
    case other
}

struct NotificationSettingsSnapshot: Equatable, Sendable {
    let authorization: NotificationAuthorizationState
    let alertsEnabled: Bool
}

struct NotificationPermissionOptions: OptionSet, Equatable, Sendable {
    let rawValue: UInt

    init(rawValue: UInt) {
        self.rawValue = rawValue
    }

    static let alert = Self(rawValue: 1 << 0)
    static let sound = Self(rawValue: 1 << 1)
}

enum LocalNotificationSound: Equatable, Sendable {
    case `default`
}

enum LocalNotificationDelivery: Equatable, Sendable {
    case immediate
}

struct LocalNotificationRequest: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let sound: LocalNotificationSound
    let delivery: LocalNotificationDelivery
}

protocol NotificationCenterClient: Sendable {
    func notificationSettings() async -> NotificationSettingsSnapshot
    func requestAuthorization(options: NotificationPermissionOptions) async throws -> Bool
    func add(_ request: LocalNotificationRequest) async throws
}

/// The SDK does not annotate `UNUserNotificationCenter` as `Sendable`; this adapter
/// keeps its immutable reference private and transfers only value snapshots.
final class SystemNotificationCenterClient: NotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func notificationSettings() async -> NotificationSettingsSnapshot {
        let settings = await center.notificationSettings()
        return NotificationSettingsSnapshot(
            authorization: Self.authorizationState(for: settings.authorizationStatus),
            alertsEnabled: Self.alertsAreEnabled(settings.alertSetting)
        )
    }

    func requestAuthorization(options: NotificationPermissionOptions) async throws -> Bool {
        var nativeOptions: UNAuthorizationOptions = []
        if options.contains(.alert) { nativeOptions.insert(.alert) }
        if options.contains(.sound) { nativeOptions.insert(.sound) }
        return try await center.requestAuthorization(options: nativeOptions)
    }

    func add(_ request: LocalNotificationRequest) async throws {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: nil))
    }

    private static func authorizationState(for status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        @unknown default: .other
        }
    }

    private static func alertsAreEnabled(_ setting: UNNotificationSetting) -> Bool {
        switch setting {
        case .enabled: true
        case .notSupported, .disabled: false
        @unknown default: false
        }
    }
}

private actor NotificationTransactionGate {
    private let transactionWaiterRegistered: @Sendable () -> Void
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(transactionWaiterRegistered: @escaping @Sendable () -> Void = {}) {
        self.transactionWaiterRegistered = transactionWaiterRegistered
    }

    func enter() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            transactionWaiterRegistered()
        }
    }

    func leave() {
        guard let waiter = waiters.first else {
            isHeld = false
            return
        }
        waiters.removeFirst()
        waiter.resume()
    }
}

actor NotificationController {
    enum Outcome: Equatable, Sendable {
        case enabled
        case disabled
        case systemSettingsRequired(String)
        case delivered(String)
        case noAlert
        case deliveryFailed
    }

    static let systemSettingsRoute = "Ustawienia systemowe → Powiadomienia → ThermoBar"

    private let client: any NotificationCenterClient
    private let transactionGate: NotificationTransactionGate
    private var isEnabledStorage = false
    private var machine = ThermalAlertMachine()
    private var hasBaseline = false

    init(
        client: any NotificationCenterClient = SystemNotificationCenterClient(),
        transactionWaiterRegistered: @escaping @Sendable () -> Void = {}
    ) {
        self.client = client
        self.transactionGate = NotificationTransactionGate(transactionWaiterRegistered: transactionWaiterRegistered)
    }

    var isEnabled: Bool { isEnabledStorage }

    func setEnabled(_ shouldEnable: Bool, currentThermalLevel: ThermalLevel) async -> Outcome {
        await transactionGate.enter()
        let outcome = await setEnabledLocked(shouldEnable, currentThermalLevel: currentThermalLevel)
        await transactionGate.leave()
        return outcome
    }

    func restore(enabledPreference: Bool, currentThermalLevel: ThermalLevel) async -> Outcome {
        await transactionGate.enter()
        let outcome: Outcome
        if enabledPreference {
            outcome = commit(await client.notificationSettings(), currentThermalLevel: currentThermalLevel, establishBaseline: true)
        } else {
            disableAndReset()
            outcome = .disabled
        }
        await transactionGate.leave()
        return outcome
    }

    func reconcileOnActivation(currentThermalLevel: ThermalLevel) async -> Outcome {
        await transactionGate.enter()
        let settings = await client.notificationSettings()
        let outcome: Outcome
        if !isEnabledStorage {
            outcome = .disabled
        } else if settings.allowLocalAlerts {
            if !hasBaseline {
                machine.establishBaseline(currentThermalLevel)
                hasBaseline = true
            }
            outcome = .enabled
        } else {
            disableAndReset()
            outcome = .systemSettingsRequired(Self.systemSettingsRoute)
        }
        await transactionGate.leave()
        return outcome
    }

    func consume(thermalLevel: ThermalLevel, transitionTimestamp: UInt64) async -> Outcome {
        await transactionGate.enter()
        let outcome: Outcome
        guard isEnabledStorage, let alert = machine.consume(thermalLevel) else {
            outcome = .noAlert
            await transactionGate.leave()
            return outcome
        }

        let settings = await client.notificationSettings()
        guard settings.allowLocalAlerts else {
            disableAndReset()
            outcome = .systemSettingsRequired(Self.systemSettingsRoute)
            await transactionGate.leave()
            return outcome
        }

        let request = Self.request(for: alert, timestamp: transitionTimestamp)
        do {
            try await client.add(request)
            outcome = .delivered(request.identifier)
        } catch {
            outcome = .deliveryFailed
        }
        await transactionGate.leave()
        return outcome
    }

    private func setEnabledLocked(_ shouldEnable: Bool, currentThermalLevel: ThermalLevel) async -> Outcome {
        guard shouldEnable else {
            disableAndReset()
            return .disabled
        }

        let initialSettings = await client.notificationSettings()
        if initialSettings.authorization == .notDetermined {
            _ = try? await client.requestAuthorization(options: [.alert, .sound])
            return commit(await client.notificationSettings(), currentThermalLevel: currentThermalLevel, establishBaseline: true)
        }
        return commit(initialSettings, currentThermalLevel: currentThermalLevel, establishBaseline: true)
    }

    private func commit(_ settings: NotificationSettingsSnapshot, currentThermalLevel: ThermalLevel, establishBaseline: Bool) -> Outcome {
        guard settings.allowLocalAlerts else {
            disableAndReset()
            return .systemSettingsRequired(Self.systemSettingsRoute)
        }
        isEnabledStorage = true
        if establishBaseline {
            machine.establishBaseline(currentThermalLevel)
            hasBaseline = true
        }
        return .enabled
    }

    private func disableAndReset() {
        isEnabledStorage = false
        machine.resetBaseline()
        hasBaseline = false
    }

    private static func request(for alert: ThermalAlert, timestamp: UInt64) -> LocalNotificationRequest {
        let severity: String
        let title: String
        let body: String
        switch alert.severity {
        case .serious:
            severity = "serious"
            title = "Poważny stan termiczny"
            body = "ThermoBar wykrył poważne obciążenie termiczne Maca."
        case .critical:
            severity = "critical"
            title = "Krytyczny stan termiczny"
            body = "ThermoBar wykrył krytyczne obciążenie termiczne Maca."
        }
        return LocalNotificationRequest(
            identifier: "thermobar.\(severity).\(timestamp)",
            title: title,
            body: body,
            sound: .default,
            delivery: .immediate
        )
    }
}

private extension NotificationSettingsSnapshot {
    var allowLocalAlerts: Bool {
        alertsEnabled && (authorization == .authorized || authorization == .provisional)
    }
}
