import AppKit
import Foundation
import ServiceManagement
import Testing
@testable import ThermoBar
@testable import ThermoBarCore

@Test @MainActor func preferencesPersistOnlyTypedApplicationRecords() {
    let suiteName = "AppPreferencesTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        Issue.record("Could not create isolated defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let frame = PanelFrameRecord(displayIdentifier: 42, x: 12, y: 24, width: 238, height: 330)
    let preferences = AppPreferences(defaults: defaults)
    preferences.panelVisible = false
    preferences.launchAtLogin = true
    preferences.thermalNotifications = true
    preferences.panelFrame = frame

    let reloaded = AppPreferences(defaults: defaults)
    #expect(reloaded.panelVisible == false)
    #expect(reloaded.launchAtLogin == true)
    #expect(reloaded.thermalNotifications == true)
    #expect(reloaded.panelFrame == frame)
    let keys = Set((defaults.persistentDomain(forName: suiteName) ?? [:]).keys.filter { $0.hasPrefix("thermobar.") })
    #expect(keys == ["thermobar.panelVisible", "thermobar.launchAtLogin", "thermobar.thermalNotifications", "thermobar.panelFrame"])
}

@Test @MainActor func panelAndPowerEventsSelectExactSamplingModes() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications()
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    try? await Task.sleep(nanoseconds: 20_000_000)

    await model.setPanelVisible(true)
    await model.setPanelVisible(false)
    await model.handleLifecycleEvent(.willSleep)
    await model.handleLifecycleEvent(.didWake)
    await model.setPanelVisible(true)
    await model.handleLifecycleEvent(.willSleep)
    await model.handleLifecycleEvent(.didWake)

    #expect(await sampler.modes == [.visible, .menuBarOnly, .sleeping, .menuBarOnly, .visible, .sleeping, .visible])
    await sampler.finish()
}

@Test @MainActor func preStartVisibilityDefersSamplingUntilStreamAttachmentThenSamplesImmediately() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications()
    let model = AppModel(preferences: preferences, sampler: sampler, notifications: notifications)

    await model.setPanelVisible(false)

    let modesBeforeStart = await sampler.modes
    #expect(modesBeforeStart.isEmpty)
    #expect(preferences.panelVisible == false)
    guard modesBeforeStart.isEmpty else { return }

    model.start()
    await notifications.waitForRestoreRequests(1)

    #expect(await sampler.snapshotRequests == 1)
    #expect(await sampler.modes == [.menuBarOnly])
    #expect(model.snapshot == fixture(.nominal, timestamp: 1))
    await sampler.finish()
}

@Test @MainActor func latestSynchronousPanelIntentWinsOverAnOlderPausedSamplerReconciliation() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    preferences.panelVisible = false
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1), pauseOnMode: .visible)
    let notifications = FakeNotifications()
    let model = AppModel(preferences: preferences, sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    model.setPanelVisibilityIntent(true)
    await sampler.waitForPausedMode(.visible)
    model.setPanelVisibilityIntent(false)
    model.setPanelVisibilityIntent(false)
    await sampler.waitForModes(3)

    #expect(model.panelVisible == false)
    #expect(preferences.panelVisible == false)
    #expect(await sampler.modes == [.menuBarOnly, .visible, .menuBarOnly])
    #expect(await sampler.setModeRequests == 3)
    await sampler.releasePausedMode()
    await sampler.finish()
}

@Test @MainActor func samplerDiagnosticsPropagateWithTheirSourceAfterASnapshot() async {
    let expected = SamplingDiagnostic(source: .gpuUtilization, error: .readFailed, consecutiveFailures: 3)
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1), diagnostics: [expected])
    let notifications = FakeNotifications()
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    try? await Task.sleep(nanoseconds: 20_000_000)

    #expect(model.diagnostics == [expected])
    #expect(model.diagnostic == .readFailed)
    await sampler.finish()
}

@Test @MainActor func retrySensorsSleepsThenImmediatelyRestartsTheActiveSamplingMode() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications()
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    await model.retrySensors()

    #expect(await sampler.modes == [.visible, .sleeping, .visible])
    await sampler.finish()
}

@Test @MainActor func retrySensorsNeverReactivatesSamplingIfSleepStartsDuringRetry() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1), pauseOnSleepingMode: true)
    let notifications = FakeNotifications()
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)

    let retry = Task { @MainActor in await model.retrySensors() }
    await sampler.waitForSleepingMode()
    await model.handleLifecycleEvent(.willSleep)
    await sampler.releaseSleepingMode()
    await retry.value

    #expect(await sampler.modes == [.visible, .sleeping])
    await sampler.finish()
}

@Test func presentationClassifiesWaitingAvailableAndSourceFailuresDeterministically() {
    let snapshot = fixture(.serious, timestamp: 100)
    let failure = SamplingDiagnostic(source: .cpuTemperature, error: .missingExpectedKey("Tp0m"), consecutiveFailures: 3)

    #expect(ThermoBarPresentation.sensorStatus(snapshot: nil, diagnostics: []) == .waiting)
    #expect(ThermoBarPresentation.sensorStatus(snapshot: snapshot, diagnostics: []) == .available)
    #expect(ThermoBarPresentation.sensorStatus(snapshot: snapshot, diagnostics: [failure]) == .failed([failure]))
}

@Test func presentationDerivesSnapshotSensorFailuresAndPreservesDiagnosticTruth() {
    let unsupported = SystemSnapshot(
        monotonicNanoseconds: 100,
        cpuPercent: nil,
        memory: nil,
        gpuPercent: nil,
        temperature: .init(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: nil,
            chipHotspotCelsius: nil,
            cpuError: .unsupportedPrivateMetricSchema,
            gpuError: .unsupportedPrivateMetricSchema
        ),
        fan: .unavailable(.unsupportedPrivateMetricSchema),
        thermalLevel: .nominal,
        publicMetricError: .unsupportedPrivateMetricSchema,
        privateMetricError: .unsupportedPrivateMetricSchema
    )
    let partial = SystemSnapshot(
        monotonicNanoseconds: 101,
        cpuPercent: 10,
        memory: .init(usedBytes: 1, totalBytes: 2),
        gpuPercent: 20,
        temperature: .init(
            cpuAverageCelsius: nil,
            gpuAverageCelsius: 50,
            chipHotspotCelsius: 55,
            cpuError: .missingExpectedKey("Tp0m"),
            gpuError: nil
        ),
        fan: .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .nominal,
        publicMetricError: nil,
        privateMetricError: nil
    )
    let transient = SamplingDiagnostic(source: .gpuUtilization, error: .readFailed, consecutiveFailures: 1)
    let persistent = SamplingDiagnostic(source: .smcConnection, error: .readFailed, consecutiveFailures: 3)
    let gpuOnlySnapshot = SystemSnapshot(
        monotonicNanoseconds: 102,
        cpuPercent: 10,
        memory: .init(usedBytes: 1, totalBytes: 2),
        gpuPercent: nil,
        temperature: .init(cpuAverageCelsius: 50, gpuAverageCelsius: 51, chipHotspotCelsius: 55, cpuError: nil, gpuError: nil),
        fan: .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .nominal,
        publicMetricError: nil,
        privateMetricError: .readFailed
    )

    #expect(ThermoBarPresentation.sensorStatus(snapshot: fixture(.nominal, timestamp: 1), diagnostics: []) == .available)
    #expect(ThermoBarPresentation.sensorStatus(snapshot: unsupported, diagnostics: []) == .failed([
        .init(source: .cpuTemperature, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1),
        .init(source: .gpuTemperature, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1),
        .init(source: .fanSpeed, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1),
        .init(source: .cpu, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1),
        .init(source: .memory, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1)
    ]))
    #expect(ThermoBarPresentation.sensorStatus(snapshot: partial, diagnostics: []) == .failed([
        .init(source: .cpuTemperature, error: .missingExpectedKey("Tp0m"), consecutiveFailures: 1)
    ]))
    #expect(ThermoBarPresentation.sensorStatus(snapshot: gpuOnlySnapshot, diagnostics: [transient]) == .failed([transient]))
    #expect(ThermoBarPresentation.sensorStatus(snapshot: fixture(.nominal, timestamp: 1), diagnostics: [transient]) == .failed([transient]))
    #expect(ThermoBarPresentation.sensorStatus(snapshot: fixture(.nominal, timestamp: 1), diagnostics: [persistent]) == .failed([persistent]))
    #expect(!transient.isPersistent)
    #expect(persistent.isPersistent)
}

@Test func unsupportedSchemaFooterIsPermanentAndNeverFallsBackToFreshness() {
    let unsupported = SamplingDiagnostic(source: .cpuTemperature, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 1)
    let persistent = SamplingDiagnostic(source: .smcConnection, error: .readFailed, consecutiveFailures: 3)

    #expect(ThermoBarPresentation.footerDiagnostic(for: .failed([unsupported])) == unsupported)
    #expect(ThermoBarPresentation.footerDiagnostic(for: .failed([unsupported, persistent])) == unsupported)
    #expect(ThermoBarPresentation.footerDiagnostic(for: .failed([persistent])) == persistent)
    #expect(ThermoBarPresentation.footerDiagnostic(for: .available) == nil)
}

@Test func presentationFreshnessFailsAtTheFirstNanosecondPastTheDeadline() {
    let snapshot = fixture(.nominal, timestamp: 100)

    #expect(ThermoBarPresentation(snapshot: snapshot, mode: .visible, nowNanoseconds: 6_000_000_100).isFresh)
    #expect(!ThermoBarPresentation(snapshot: snapshot, mode: .visible, nowNanoseconds: 6_000_000_101).isFresh)
}

@Test func presentationFormatsTheFastestFanAndItsOwnProgressDeterministically() {
    let snapshot = SystemSnapshot(
        monotonicNanoseconds: 100,
        cpuPercent: 10,
        memory: .init(usedBytes: 1, totalBytes: 2),
        gpuPercent: 20,
        temperature: .init(cpuAverageCelsius: 50, gpuAverageCelsius: 45, chipHotspotCelsius: 50, cpuError: nil, gpuError: nil),
        fan: .available(fastestRPM: 2_499.6, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: .nominal,
        publicMetricError: nil,
        privateMetricError: nil
    )

    let presentation = ThermoBarPresentation(snapshot: snapshot, mode: .visible, nowNanoseconds: 101)

    #expect(presentation.fanSpeed == "2500 RPM")
    #expect(presentation.fanDetail == String(localized: ThermoBarCopy.fastest))
    #expect(presentation.fanFraction == 2_499.6 / 7_900)
}

@Test func freshnessDeadlineIdentityRearmsOnlyForSnapshotTimestampOrModeChanges() {
    let original = FreshnessDeadlineID(snapshot: fixture(.nominal, timestamp: 100), mode: .visible)

    #expect(original == FreshnessDeadlineID(snapshot: fixture(.serious, timestamp: 100), mode: .visible))
    #expect(original != FreshnessDeadlineID(snapshot: fixture(.nominal, timestamp: 101), mode: .visible))
    #expect(original != FreshnessDeadlineID(snapshot: fixture(.nominal, timestamp: 100), mode: .menuBarOnly))
}

@Test @MainActor func startupInstallsStreamBeforeImmediateModeAndDoesNotBlockOnRestore() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications(restoreOutcome: .enabled, pauseRestore: true)
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)

    model.start()
    model.start()
    await notifications.waitForRestoreRequests(1)

    #expect(await sampler.snapshotRequests == 1)
    #expect(await sampler.modes == [.visible])
    #expect(model.snapshot == fixture(.nominal, timestamp: 1))
    await notifications.releaseRestore()
    await sampler.finish()
}

@Test @MainActor func duplicateWakeAdoptsTheSamplerStableUUIDAndAcceptsItsCadence() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications(restoreOutcome: .enabled)
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)
    model.start()
    await notifications.waitForRestoreRequests(1)
    let stableID = await sampler.currentID()
    await model.handleLifecycleEvent(.didWake) // visible is already active: this is a same-mode join
    await sampler.emit(fixture(.serious, timestamp: 2), transitionID: stableID)
    await waitForSnapshot(model, timestamp: 2)
    #expect(model.snapshot?.thermalLevel == .serious)
    await sampler.finish()
}

@Test @MainActor func pausedDiagnosticsCannotReintroduceConsumerIdentitiesAfterSleep() async {
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications(restoreOutcome: .enabled)
    let model = AppModel(preferences: AppPreferences(defaults: isolatedDefaults()), sampler: sampler, notifications: notifications)
    model.start()
    await notifications.waitForRestoreRequests(1)
    await sampler.pauseNextDiagnostics()
    let consumerSnapshot = fixture(.serious, timestamp: 2, resourceConsumers: .init(
        cpu: .available([.init(pid: 4242, name: "never-retain-me", percent: 101)]),
        memory: .available([.init(pid: 4242, name: "never-retain-me", physicalFootprintBytes: 99)])
    ))
    await sampler.emit(consumerSnapshot)
    await sampler.waitForPausedDiagnostics()
    await model.handleLifecycleEvent(.willSleep)
    #expect(model.snapshot?.resourceConsumers == .inactive)
    await sampler.releasePausedDiagnostics()
    for _ in 0..<8 { await Task.yield() }
    #expect(model.snapshot?.resourceConsumers == .inactive)
    await sampler.finish()
}

@Test @MainActor func restoredHotSnapshotIsBaselineAndLaterEscalationsDeliverOnce() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    preferences.thermalNotifications = true
    let sampler = ControlledSampler(immediateSnapshot: fixture(.serious, timestamp: 10))
    let notifications = FakeNotifications(restoreOutcome: .enabled)
    let model = AppModel(preferences: preferences, sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    #expect(await notifications.deliveries.isEmpty)

    await sampler.emit(fixture(.critical, timestamp: 20))
    await notifications.waitForDeliveries(1)

    #expect(await notifications.deliveries == [.init(level: .critical, timestamp: 20)])
    #expect(model.notificationsEnabled)
    #expect(await sampler.modes == [.visible])
    await sampler.finish()
}

@Test @MainActor func sampledSeriousAndCriticalTransitionsAreDeliveredWithoutChangingSampling() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    preferences.thermalNotifications = true
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications(restoreOutcome: .enabled)
    let model = AppModel(preferences: preferences, sampler: sampler, notifications: notifications)

    model.start()
    await notifications.waitForRestoreRequests(1)
    await sampler.emit(fixture(.serious, timestamp: 2))
    await notifications.waitForDeliveries(1)
    await sampler.emit(fixture(.critical, timestamp: 3))
    await notifications.waitForDeliveries(2)

    #expect(await notifications.deliveries == [.init(level: .serious, timestamp: 2), .init(level: .critical, timestamp: 3)])
    #expect(await sampler.modes == [.visible])
    await sampler.finish()
}

@Test @MainActor func preDeliveryRevocationClearsOnlyNotificationState() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    preferences.thermalNotifications = true
    let sampler = ControlledSampler(immediateSnapshot: fixture(.nominal, timestamp: 1))
    let notifications = FakeNotifications(
        restoreOutcome: .enabled,
        consumeOutcomes: [.systemSettingsRequired(NotificationController.systemSettingsRoute)]
    )
    let stateProbe = NotificationStateProbe()
    let model = AppModel(
        preferences: preferences,
        sampler: sampler,
        notifications: notifications,
        notificationStateDidChange: { stateProbe.record($0) }
    )

    model.start()
    await notifications.waitForRestoreRequests(1)
    await sampler.emit(fixture(.serious, timestamp: 2))
    await stateProbe.waitForValues(1)

    #expect(stateProbe.values == [false])
    #expect(model.notificationsEnabled == false)
    #expect(preferences.thermalNotifications == false)
    #expect(await sampler.modes == [.visible])
    await sampler.finish()
}

@Test @MainActor func activationRevocationClearsNotificationToggleWithoutChangingSampling() async {
    let preferences = AppPreferences(defaults: isolatedDefaults())
    preferences.thermalNotifications = true
    let sampler = ControlledSampler()
    let notifications = FakeNotifications(activationOutcome: .systemSettingsRequired(NotificationController.systemSettingsRoute))
    let model = AppModel(preferences: preferences, sampler: sampler, notifications: notifications)

    await model.handleLifecycleEvent(.didActivate)

    #expect(model.notificationsEnabled == false)
    #expect(preferences.thermalNotifications == false)
    #expect(await sampler.modes.isEmpty)
}

@Test @MainActor func lifecyclePostsFromOwningCentersForwardTypedEventsAndTearDown() async {
    let workspace = NSWorkspace.shared
    let workspaceCenter = workspace.notificationCenter
    let applicationCenter = NotificationCenter()
    let recorder = LifecycleRecorder()
    var lifecycle: WorkspaceLifecycle? = WorkspaceLifecycle(
        workspace: workspace,
        applicationCenter: applicationCenter,
        handler: { recorder.record($0) }
    )
    #expect(lifecycle != nil)

    workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: workspace)
    workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: workspace)
    applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    applicationCenter.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
    await recorder.waitForEvents(4)
    #expect(recorder.events == [.willSleep, .didWake, .didActivate, .screenParametersChanged])

    lifecycle = nil
    workspaceCenter.post(name: NSWorkspace.willSleepNotification, object: workspace)
    applicationCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
    #expect(recorder.events.count == 4)
}

@Test func everyPublicServiceManagementStatusHasALocalMapping() {
    #expect(LaunchAtLoginStatus(serviceStatus: .enabled) == .enabled)
    #expect(LaunchAtLoginStatus(serviceStatus: .requiresApproval) == .requiresApproval)
    #expect(LaunchAtLoginStatus(serviceStatus: .notRegistered) == .notRegistered)
    #expect(LaunchAtLoginStatus(serviceStatus: .notFound) == .notFound)
}

@Test @MainActor func launchAtLoginEffectiveStateUsesSystemStatusAndRefreshesOnActivation() async {
    let staleEnabledPreference = AppPreferences(defaults: isolatedDefaults())
    staleEnabledPreference.launchAtLogin = true
    let disabledService = FakeLoginService(status: .notRegistered)
    let disabledModel = AppModel(
        preferences: staleEnabledPreference,
        sampler: ControlledSampler(),
        notifications: FakeNotifications(),
        launchAtLogin: LaunchAtLoginController(service: disabledService)
    )
    #expect(disabledModel.launchAtLoginStatus == .notRegistered)
    #expect(disabledModel.launchAtLoginEnabled == false)
    #expect(staleEnabledPreference.launchAtLogin == true)

    let staleDisabledPreference = AppPreferences(defaults: isolatedDefaults())
    staleDisabledPreference.launchAtLogin = false
    let enabledService = FakeLoginService(status: .enabled)
    let enabledModel = AppModel(
        preferences: staleDisabledPreference,
        sampler: ControlledSampler(),
        notifications: FakeNotifications(),
        launchAtLogin: LaunchAtLoginController(service: enabledService)
    )
    #expect(enabledModel.launchAtLoginStatus == .enabled)
    #expect(enabledModel.launchAtLoginEnabled)
    #expect(staleDisabledPreference.launchAtLogin == false)

    disabledService.status = .enabled
    await disabledModel.handleLifecycleEvent(.didActivate)
    #expect(disabledModel.launchAtLoginStatus == .enabled)
    #expect(disabledModel.launchAtLoginEnabled)

    let approvalService = FakeLoginService(status: .requiresApproval, statusAfterSettings: .enabled)
    let approvalModel = AppModel(
        preferences: AppPreferences(defaults: isolatedDefaults()),
        sampler: ControlledSampler(),
        notifications: FakeNotifications(),
        launchAtLogin: LaunchAtLoginController(service: approvalService)
    )
    approvalModel.openLaunchAtLoginApprovalSettings()
    #expect(approvalModel.launchAtLoginStatus == .enabled)
    #expect(approvalModel.launchAtLoginEnabled)
}

@Test @MainActor func loginControllerRereadsAfterOperationsAndOpensSettingsOnlyForApproval() {
    let requiresApproval = FakeLoginService(status: .notRegistered, statusAfterRegister: .requiresApproval)
    let controller = LaunchAtLoginController(service: requiresApproval)
    #expect(controller.setEnabled(true) == .requiresApproval)
    #expect(requiresApproval.operations == [.status, .register, .status])
    #expect(controller.openApprovalSettingsIfNeeded())
    #expect(requiresApproval.operations.last == .openSettings)

    let notRegistered = FakeLoginService(status: .notRegistered)
    let other = LaunchAtLoginController(service: notRegistered)
    #expect(!other.openApprovalSettingsIfNeeded())
    #expect(!notRegistered.operations.contains(.openSettings))
}

@MainActor private func isolatedDefaults() -> UserDefaults {
    let suiteName = "AppModelTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else { fatalError("Could not create isolated defaults suite") }
    return defaults
}

private func fixture(_ thermalLevel: ThermalLevel, timestamp: UInt64, resourceConsumers: ResourceConsumerMetric = .inactive) -> SystemSnapshot {
    SystemSnapshot(
        monotonicNanoseconds: timestamp,
        cpuPercent: nil,
        memory: nil,
        gpuPercent: nil,
        temperature: .init(cpuAverageCelsius: nil, gpuAverageCelsius: nil, chipHotspotCelsius: nil, cpuError: nil, gpuError: nil),
        fan: .available(fastestRPM: 2_500, fastestMaximumRPM: 7_900, validatedFanCount: 2),
        thermalLevel: thermalLevel,
        publicMetricError: nil,
        privateMetricError: nil,
        resourceConsumers: resourceConsumers
    )
}

@MainActor private func waitForSnapshot(_ model: AppModel, timestamp: UInt64) async {
    for _ in 0..<100 {
        if model.snapshot?.monotonicNanoseconds == timestamp { return }
        await Task.yield()
    }
    Issue.record("Timed out waiting for snapshot \(timestamp)")
}

private actor ControlledSampler: SamplingControlling {
    private let immediateSnapshot: SystemSnapshot?
    private let pauseOnSleepingMode: Bool
    private let pauseOnMode: SamplingMode?
    private(set) var modes: [SamplingMode] = []
    private(set) var setModeRequests = 0
    private(set) var snapshotRequests = 0
    private var continuation: AsyncStream<SamplingSnapshot>.Continuation?
    private var thermalContinuation: AsyncStream<ThermalSample>.Continuation?
    private var currentMode: SamplingMode = .sleeping
    private var currentTransitionID = UUID()
    private var diagnostics: [SamplingDiagnostic]
    private var sleepingModeWaiters: [CheckedContinuation<Void, Never>] = []
    private var sleepingModePauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var modeWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var pausedModeWaiters: [SamplingMode: [CheckedContinuation<Void, Never>]] = [:]
    private var genericPauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseDiagnostics = false
    private var isDiagnosticsPaused = false
    private var pausedDiagnosticsWaiters: [CheckedContinuation<Void, Never>] = []
    private var diagnosticsPauseWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        immediateSnapshot: SystemSnapshot? = nil,
        diagnostics: [SamplingDiagnostic] = [],
        pauseOnSleepingMode: Bool = false,
        pauseOnMode: SamplingMode? = nil
    ) {
        self.immediateSnapshot = immediateSnapshot
        self.diagnostics = diagnostics
        self.pauseOnSleepingMode = pauseOnSleepingMode
        self.pauseOnMode = pauseOnMode
    }

    func snapshots() -> AsyncStream<SamplingSnapshot> {
        snapshotRequests += 1
        let stream = AsyncStream<SamplingSnapshot>.makeStream()
        continuation = stream.continuation
        return stream.stream
    }


    func thermalSamples() -> AsyncStream<ThermalSample> { let stream = AsyncStream<ThermalSample>.makeStream(); thermalContinuation = stream.continuation; return stream.stream }

    func setMode(_ mode: SamplingMode, transitionID: UUID) async -> SamplingTransitionReceipt {
        setModeRequests += 1
        guard mode != currentMode else { return .init(requestedTransitionID: transitionID, currentTransitionID: currentTransitionID, currentMode: mode, isCurrent: false) }
        currentMode = mode
        currentTransitionID = transitionID
        modes.append(mode)
        let modeObservers = modeWaiters.removeValue(forKey: modes.count) ?? []
        modeObservers.forEach { $0.resume() }
        if mode == pauseOnMode {
            let observers = pausedModeWaiters.removeValue(forKey: mode) ?? []
            observers.forEach { $0.resume() }
            await withCheckedContinuation { genericPauseWaiters.append($0) }
        }
        if mode == .sleeping, pauseOnSleepingMode {
            let observers = sleepingModeWaiters
            sleepingModeWaiters.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { sleepingModePauseWaiters.append($0) }
        }
        if modes.count == 1, let immediateSnapshot {
            continuation?.yield(.init(value: immediateSnapshot, transitionID: transitionID))
            thermalContinuation?.yield(.init(level: immediateSnapshot.thermalLevel, monotonicNanoseconds: immediateSnapshot.monotonicNanoseconds))
        }
        return .init(requestedTransitionID: transitionID, currentTransitionID: currentTransitionID, currentMode: mode, isCurrent: true)
    }

    func currentDiagnostics() async -> [SamplingDiagnostic] {
        if pauseDiagnostics {
            pauseDiagnostics = false
            isDiagnosticsPaused = true
            let observers = pausedDiagnosticsWaiters
            pausedDiagnosticsWaiters.removeAll()
            observers.forEach { $0.resume() }
            await withCheckedContinuation { diagnosticsPauseWaiters.append($0) }
            isDiagnosticsPaused = false
        }
        return diagnostics
    }

    func setDiagnostics(_ diagnostics: [SamplingDiagnostic]) { self.diagnostics = diagnostics }

    func waitForSleepingMode() async {
        guard modes.contains(.sleeping) else {
            await withCheckedContinuation { sleepingModeWaiters.append($0) }
            return
        }
    }

    func releaseSleepingMode() {
        let waiters = sleepingModePauseWaiters
        sleepingModePauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func waitForModes(_ expected: Int) async {
        guard modes.count < expected else { return }
        await withCheckedContinuation { modeWaiters[expected, default: []].append($0) }
    }

    func waitForPausedMode(_ mode: SamplingMode) async {
        guard !modes.contains(mode) else { return }
        await withCheckedContinuation { pausedModeWaiters[mode, default: []].append($0) }
    }

    func releasePausedMode() {
        let waiters = genericPauseWaiters
        genericPauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func currentID() -> UUID { currentTransitionID }

    func emit(_ snapshot: SystemSnapshot, transitionID: UUID? = nil) {
        continuation?.yield(.init(value: snapshot, transitionID: transitionID ?? currentTransitionID))
        thermalContinuation?.yield(.init(level: snapshot.thermalLevel, monotonicNanoseconds: snapshot.monotonicNanoseconds))
    }

    func pauseNextDiagnostics() { pauseDiagnostics = true }
    func waitForPausedDiagnostics() async {
        guard !isDiagnosticsPaused else { return }
        await withCheckedContinuation { pausedDiagnosticsWaiters.append($0) }
    }
    func releasePausedDiagnostics() {
        let waiters = diagnosticsPauseWaiters
        diagnosticsPauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    func finish() {
        continuation?.finish()
        thermalContinuation?.finish()
        continuation = nil
    }
}

private actor FakeNotifications: NotificationControlling {
    struct Delivery: Equatable, Sendable {
        let level: ThermalLevel
        let timestamp: UInt64
    }

    private let activationOutcome: NotificationController.Outcome
    private let restoreOutcome: NotificationController.Outcome
    private var consumeOutcomes: [NotificationController.Outcome]
    private let pauseRestore: Bool
    private(set) var restoreRequests = 0
    private(set) var deliveries: [Delivery] = []
    private var restoreWaiters: [CheckedContinuation<Void, Never>] = []
    private var restorePauseWaiters: [CheckedContinuation<Void, Never>] = []
    private var deliveryWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    init(
        activationOutcome: NotificationController.Outcome = .enabled,
        restoreOutcome: NotificationController.Outcome = .enabled,
        consumeOutcomes: [NotificationController.Outcome] = [],
        pauseRestore: Bool = false
    ) {
        self.activationOutcome = activationOutcome
        self.restoreOutcome = restoreOutcome
        self.consumeOutcomes = consumeOutcomes
        self.pauseRestore = pauseRestore
    }

    func restore(enabledPreference: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        restoreRequests += 1
        let observers = restoreWaiters
        restoreWaiters.removeAll()
        observers.forEach { $0.resume() }
        if pauseRestore { await withCheckedContinuation { restorePauseWaiters.append($0) } }
        return enabledPreference ? restoreOutcome : .disabled
    }

    func reconcileOnActivation(currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        activationOutcome
    }

    func setEnabled(_ shouldEnable: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        shouldEnable ? .enabled : .disabled
    }

    func consume(thermalLevel: ThermalLevel, transitionTimestamp: UInt64) async -> NotificationController.Outcome {
        deliveries.append(.init(level: thermalLevel, timestamp: transitionTimestamp))
        let observers = deliveryWaiters.removeValue(forKey: deliveries.count) ?? []
        observers.forEach { $0.resume() }
        guard !consumeOutcomes.isEmpty else { return .delivered("fake") }
        return consumeOutcomes.count == 1 ? consumeOutcomes[0] : consumeOutcomes.removeFirst()
    }

    func waitForRestoreRequests(_ expected: Int) async {
        guard restoreRequests < expected else { return }
        await withCheckedContinuation { restoreWaiters.append($0) }
    }

    func waitForDeliveries(_ expected: Int) async {
        guard deliveries.count < expected else { return }
        await withCheckedContinuation { deliveryWaiters[expected, default: []].append($0) }
    }

    func releaseRestore() {
        let waiters = restorePauseWaiters
        restorePauseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

@MainActor private final class LifecycleRecorder {
    private(set) var events: [WorkspaceLifecycle.Event] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ event: WorkspaceLifecycle.Event) {
        events.append(event)
        let continuations = waiters.removeValue(forKey: events.count) ?? []
        continuations.forEach { $0.resume() }
    }

    func waitForEvents(_ expected: Int) async {
        guard events.count < expected else { return }
        await withCheckedContinuation { waiters[expected, default: []].append($0) }
    }
}

@MainActor private final class NotificationStateProbe {
    private(set) var values: [Bool] = []
    private var waiters: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func record(_ value: Bool) {
        values.append(value)
        let continuations = waiters.removeValue(forKey: values.count) ?? []
        continuations.forEach { $0.resume() }
    }

    func waitForValues(_ expected: Int) async {
        guard values.count < expected else { return }
        await withCheckedContinuation { waiters[expected, default: []].append($0) }
    }
}

@MainActor private final class FakeLoginService: LaunchAtLoginService {
    enum Operation: Equatable { case status, register, unregister, openSettings }

    var status: LaunchAtLoginStatus
    private let statusAfterRegister: LaunchAtLoginStatus?
    private let statusAfterSettings: LaunchAtLoginStatus?
    private(set) var operations: [Operation] = []

    init(
        status: LaunchAtLoginStatus,
        statusAfterRegister: LaunchAtLoginStatus? = nil,
        statusAfterSettings: LaunchAtLoginStatus? = nil
    ) {
        self.status = status
        self.statusAfterRegister = statusAfterRegister
        self.statusAfterSettings = statusAfterSettings
    }

    func currentStatus() -> LaunchAtLoginStatus {
        operations.append(.status)
        return status
    }

    func register() throws {
        operations.append(.register)
        if let statusAfterRegister { status = statusAfterRegister }
    }

    func unregister() throws { operations.append(.unregister) }
    func openSystemSettingsLoginItems() {
        operations.append(.openSettings)
        if let statusAfterSettings { status = statusAfterSettings }
    }
}
