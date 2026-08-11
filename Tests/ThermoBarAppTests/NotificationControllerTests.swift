import Foundation
import Testing
@testable import ThermoBar
@testable import ThermoBarCore

private let settingsRoute = "Ustawienia systemowe → Powiadomienia → ThermoBar"

@Test func explicitEnableRequestsOnlyAlertAndSoundThenCommitsFinalSettings() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .notDetermined, alertsEnabled: false),
        .init(authorization: .authorized, alertsEnabled: true)
    ], authorizationResult: false)
    let controller = NotificationController(client: client)

    #expect(await controller.setEnabled(true, currentThermalLevel: .critical) == .enabled)
    #expect(await controller.isEnabled)
    #expect(await client.operations == [.settings, .request([.alert, .sound]), .settings])
    #expect(await controller.consume(thermalLevel: .critical, transitionTimestamp: 1) == .noAlert)
}

@Test func authorizationErrorStillRequeriesAndFailsClosed() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .notDetermined, alertsEnabled: false),
        .init(authorization: .denied, alertsEnabled: false)
    ], authorizationError: TestError.failed)
    let controller = NotificationController(client: client)

    #expect(await controller.setEnabled(true, currentThermalLevel: .nominal) == .systemSettingsRequired(settingsRoute))
    #expect(await client.operations == [.settings, .request([.alert, .sound]), .settings])
    #expect(!(await controller.isEnabled))
}

@Test func deniedOrAlertDisabledPermissionsReturnTheExactSettingsRoute() async {
    for snapshot in [
        NotificationSettingsSnapshot(authorization: .denied, alertsEnabled: false),
        .init(authorization: .restricted, alertsEnabled: false),
        .init(authorization: .other, alertsEnabled: false),
        .init(authorization: .authorized, alertsEnabled: false)
    ] {
        let client = FakeNotificationCenter(settings: [snapshot])
        let controller = NotificationController(client: client)
        #expect(await controller.setEnabled(true, currentThermalLevel: .nominal) == .systemSettingsRequired(settingsRoute))
        #expect(await client.operations == [.settings])
        #expect(!(await controller.isEnabled))
    }
}

@Test func disablingRestoreAndActivationNeverRequestAuthorization() async {
    let client = FakeNotificationCenter(settings: [.init(authorization: .notDetermined, alertsEnabled: false)])
    let controller = NotificationController(client: client)

    #expect(await controller.setEnabled(false, currentThermalLevel: .nominal) == .disabled)
    #expect(await controller.restore(enabledPreference: false, currentThermalLevel: .nominal) == .disabled)
    #expect(await controller.reconcileOnActivation(currentThermalLevel: .nominal) == .disabled)
    #expect(await client.operations == [.settings])
}

@Test func restoreEnabledPreferenceBaselinesHotLevelWithoutPrompt() async {
    let client = FakeNotificationCenter(settings: [.init(authorization: .provisional, alertsEnabled: true)])
    let controller = NotificationController(client: client)

    #expect(await controller.restore(enabledPreference: true, currentThermalLevel: .serious) == .enabled)
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 5) == .noAlert)
    #expect(await client.operations == [.settings])
}

@Test func enableAndReenableHotLevelsEstablishBaselinesWithoutRetroactiveRequests() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .authorized, alertsEnabled: true)
    ])
    let controller = NotificationController(client: client)

    #expect(await controller.setEnabled(true, currentThermalLevel: .serious) == .enabled)
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 1) == .noAlert)
    #expect(await controller.setEnabled(false, currentThermalLevel: .serious) == .disabled)
    #expect(await controller.setEnabled(true, currentThermalLevel: .critical) == .enabled)
    #expect(await controller.consume(thermalLevel: .critical, transitionTimestamp: 2) == .noAlert)
    #expect(await client.requests.isEmpty)
}

@Test func activationDisablesOnRevocationButKeepsBaselineWhenStillAuthorized() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .denied, alertsEnabled: false)
    ])
    let controller = NotificationController(client: client)

    #expect(await controller.restore(enabledPreference: true, currentThermalLevel: .serious) == .enabled)
    #expect(await controller.reconcileOnActivation(currentThermalLevel: .serious) == .enabled)
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 10) == .noAlert)
    #expect(await controller.reconcileOnActivation(currentThermalLevel: .serious) == .systemSettingsRequired(settingsRoute))
    #expect(!(await controller.isEnabled))
}

@Test func qualifyingTransitionsRecheckPermissionAndDeliverStableUniqueRequests() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .authorized, alertsEnabled: true)
    ])
    let controller = NotificationController(client: client)
    _ = await controller.restore(enabledPreference: true, currentThermalLevel: .nominal)

    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 123) == .delivered("thermobar.serious.123"))
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 124) == .noAlert)
    #expect(await controller.consume(thermalLevel: .critical, transitionTimestamp: 125) == .delivered("thermobar.critical.125"))
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 126) == .noAlert)
    #expect(await controller.consume(thermalLevel: .critical, transitionTimestamp: 127) == .delivered("thermobar.critical.127"))
    #expect(await client.requests.map(\.identifier) == ["thermobar.serious.123", "thermobar.critical.125", "thermobar.critical.127"])
    #expect((await client.requests).allSatisfy { $0.sound == .default && $0.delivery == .immediate })
    #expect((await client.requests).map { "\($0.title)|\($0.body)" } == [
        "Poważny stan termiczny|ThermoBar wykrył poważne obciążenie termiczne Maca.",
        "Krytyczny stan termiczny|ThermoBar wykrył krytyczne obciążenie termiczne Maca.",
        "Krytyczny stan termiczny|ThermoBar wykrył krytyczne obciążenie termiczne Maca."
    ])
}

@Test func revokedPermissionBeforeDeliveryCancelsAddAndDisablesController() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .denied, alertsEnabled: false)
    ])
    let controller = NotificationController(client: client)
    _ = await controller.restore(enabledPreference: true, currentThermalLevel: .nominal)

    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 4) == .systemSettingsRequired(settingsRoute))
    #expect(await client.requests.isEmpty)
    #expect(!(await controller.isEnabled))
}

@Test func addFailureIsBoundedAndDoesNotRetryTheSameTransition() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .authorized, alertsEnabled: true),
        .init(authorization: .authorized, alertsEnabled: true)
    ], addError: TestError.failed)
    let controller = NotificationController(client: client)
    _ = await controller.restore(enabledPreference: true, currentThermalLevel: .nominal)

    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 7) == .deliveryFailed)
    #expect(await controller.consume(thermalLevel: .serious, transitionTimestamp: 7) == .noAlert)
    #expect((await client.requests).count == 1)
}

@Test func overlappingToggleTransactionsDoNotInterleave() async {
    let client = FakeNotificationCenter(settings: [
        .init(authorization: .notDetermined, alertsEnabled: false),
        .init(authorization: .authorized, alertsEnabled: true)
    ], pauseAuthorization: true)
    let gateProbe = TransactionWaiterProbe()
    let controller = NotificationController(client: client, transactionWaiterRegistered: { gateProbe.record() })
    let enabling = Task { await controller.setEnabled(true, currentThermalLevel: .nominal) }
    await client.waitForAuthorizationRequest()
    let disabling = Task { await controller.setEnabled(false, currentThermalLevel: .nominal) }
    await gateProbe.waitForRegistrations(1)
    #expect(await client.operations == [.settings, .request([.alert, .sound])])
    await client.releaseAuthorizationRequest()
    #expect(await enabling.value == .enabled)
    #expect(await disabling.value == .disabled)
    #expect(await client.operations == [.settings, .request([.alert, .sound]), .settings])
    #expect(!(await controller.isEnabled))
}

@Test func queuedDisableCannotInterleaveAPausedPreDeliveryTransaction() async {
    let client = FakeNotificationCenter(
        settings: [
            .init(authorization: .authorized, alertsEnabled: true),
            .init(authorization: .authorized, alertsEnabled: true)
        ],
        pauseSettingsOnCall: 2
    )
    let gateProbe = TransactionWaiterProbe()
    let controller = NotificationController(client: client, transactionWaiterRegistered: { gateProbe.record() })
    _ = await controller.restore(enabledPreference: true, currentThermalLevel: .nominal)

    let delivery = Task { await controller.consume(thermalLevel: .serious, transitionTimestamp: 44) }
    await client.waitForPausedSettingsCall()
    let disabling = Task { await controller.setEnabled(false, currentThermalLevel: .serious) }
    await gateProbe.waitForRegistrations(1)
    #expect(await client.operations == [.settings, .settings])
    await client.releasePausedSettingsCall()
    #expect(await delivery.value == .delivered("thermobar.serious.44"))
    #expect(await disabling.value == .disabled)
    #expect(await client.operations == [.settings, .settings, .add("thermobar.serious.44")])
    #expect(!(await controller.isEnabled))
}

private enum TestError: Error { case failed }

private final class TransactionWaiterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    func record() {
        let resumptions = withLock { state -> [CheckedContinuation<Void, Never>] in
            state.registrations += 1
            return state.observers.removeValue(forKey: state.registrations) ?? []
        }
        resumptions.forEach { $0.resume() }
    }

    func waitForRegistrations(_ target: Int) async {
        guard currentRegistrations < target else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = withLock { state -> Bool in
                guard state.registrations < target else { return true }
                state.observers[target, default: []].append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    private var currentRegistrations: Int { withLock { $0.registrations } }

    private func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }

    private struct State {
        var registrations = 0
        var observers: [Int: [CheckedContinuation<Void, Never>]] = [:]
    }
}

private actor FakeNotificationCenter: NotificationCenterClient {
    enum Operation: Equatable, Sendable { case settings, request(NotificationPermissionOptions), add(String) }
    private var settingsQueue: [NotificationSettingsSnapshot]
    private let authorizationResult: Bool
    private let authorizationError: Error?
    private let addError: Error?
    private let pauseAuthorization: Bool
    private let pauseSettingsOnCall: Int?
    private var settingsCallCount = 0
    private var pausedSettingsWaiters: [CheckedContinuation<Void, Never>] = []
    private var pausedSettingsObservers: [CheckedContinuation<Void, Never>] = []
    private var hasPausedSettingsCall = false
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationObservers: [CheckedContinuation<Void, Never>] = []
    private var authorizationRequested = false
    private(set) var operations: [Operation] = []
    private(set) var requests: [LocalNotificationRequest] = []

    init(settings: [NotificationSettingsSnapshot], authorizationResult: Bool = true, authorizationError: Error? = nil, addError: Error? = nil, pauseAuthorization: Bool = false, pauseSettingsOnCall: Int? = nil) {
        self.settingsQueue = settings
        self.authorizationResult = authorizationResult
        self.authorizationError = authorizationError
        self.addError = addError
        self.pauseAuthorization = pauseAuthorization
        self.pauseSettingsOnCall = pauseSettingsOnCall
    }

    func notificationSettings() async -> NotificationSettingsSnapshot {
        operations.append(.settings)
        settingsCallCount += 1
        if settingsCallCount == pauseSettingsOnCall {
            hasPausedSettingsCall = true
            let observers = pausedSettingsObservers
            pausedSettingsObservers.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { pausedSettingsWaiters.append($0) }
        }
        guard !settingsQueue.isEmpty else { return .init(authorization: .other, alertsEnabled: false) }
        return settingsQueue.count == 1 ? settingsQueue[0] : settingsQueue.removeFirst()
    }

    func requestAuthorization(options: NotificationPermissionOptions) async throws -> Bool {
        operations.append(.request(options))
        authorizationRequested = true
        let observers = authorizationObservers
        authorizationObservers.removeAll()
        observers.forEach { $0.resume() }
        if pauseAuthorization { await withCheckedContinuation { authorizationWaiters.append($0) } }
        if let authorizationError { throw authorizationError }
        return authorizationResult
    }

    func add(_ request: LocalNotificationRequest) async throws {
        operations.append(.add(request.identifier))
        requests.append(request)
        if let addError { throw addError }
    }

    func waitForAuthorizationRequest() async {
        guard !authorizationRequested else { return }
        await withCheckedContinuation { continuation in
            if authorizationRequested { continuation.resume() } else { authorizationObservers.append(continuation) }
        }
    }

    func releaseAuthorizationRequest() {
        let waiters = authorizationWaiters
        authorizationWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForPausedSettingsCall() async {
        guard !hasPausedSettingsCall else { return }
        await withCheckedContinuation { continuation in
            if hasPausedSettingsCall { continuation.resume() } else { pausedSettingsObservers.append(continuation) }
        }
    }

    func releasePausedSettingsCall() {
        let waiters = pausedSettingsWaiters
        pausedSettingsWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
