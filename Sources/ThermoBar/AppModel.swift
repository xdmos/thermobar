import Foundation
import Observation
import ThermoBarCore

protocol SamplingControlling: Sendable {
    func snapshots() async -> AsyncStream<SystemSnapshot>
    func setMode(_ mode: SamplingMode) async
    func currentDiagnostics() async -> [SamplingDiagnostic]
}

extension MetricsSampler: SamplingControlling {}

protocol NotificationControlling: Sendable {
    func restore(enabledPreference: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome
    func reconcileOnActivation(currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome
    func setEnabled(_ shouldEnable: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome
    func consume(thermalLevel: ThermalLevel, transitionTimestamp: UInt64) async -> NotificationController.Outcome
}

extension NotificationController: NotificationControlling {}

@MainActor
@Observable
final class AppModel {
    private(set) var snapshot: SystemSnapshot?
    private(set) var diagnostic: MetricError?
    private(set) var diagnostics: [SamplingDiagnostic] = []
    private(set) var panelVisible: Bool
    private(set) var panelOpacity: Double
    private(set) var notificationsEnabled: Bool
    private(set) var launchAtLoginEnabled: Bool
    private(set) var launchAtLoginStatus: LaunchAtLoginStatus

    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let sampler: any SamplingControlling
    @ObservationIgnored private let notifications: any NotificationControlling
    @ObservationIgnored private let launchAtLogin: LaunchAtLoginController
    @ObservationIgnored private let notificationStateDidChange: @MainActor @Sendable (Bool) -> Void
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var panelVisibilityReconciliationTask: Task<Void, Never>?
    @ObservationIgnored private var isStreamReady = false
    @ObservationIgnored private var isSleeping = false
    @ObservationIgnored private var panelVisibilityGeneration: UInt64 = 0

    convenience init(model: String, build: String, preferences: AppPreferences = .init()) {
        self.init(
            preferences: preferences,
            sampler: MetricsSampler(model: model, build: build),
            notifications: NotificationController(),
            launchAtLogin: LaunchAtLoginController()
        )
    }

    init(
        preferences: AppPreferences,
        sampler: any SamplingControlling,
        notifications: any NotificationControlling,
        launchAtLogin: LaunchAtLoginController = .init(),
        notificationStateDidChange: @escaping @MainActor @Sendable (Bool) -> Void = { _ in }
    ) {
        self.preferences = preferences
        self.sampler = sampler
        self.notifications = notifications
        self.launchAtLogin = launchAtLogin
        self.notificationStateDidChange = notificationStateDidChange
        panelVisible = preferences.panelVisible
        panelOpacity = preferences.panelOpacity
        notificationsEnabled = preferences.thermalNotifications
        launchAtLoginStatus = launchAtLogin.status
        launchAtLoginEnabled = launchAtLogin.status == .enabled
    }

    func start() {
        guard streamTask == nil else { return }
        let sampler = sampler
        streamTask = Task { [weak self, sampler, notifications] in
            let snapshots = await sampler.snapshots()
            guard self != nil else { return }
            self?.isStreamReady = true
            let mode: SamplingMode
            if let model = self {
                mode = model.isSleeping ? .sleeping : model.activeSamplingMode
            } else {
                return
            }
            await sampler.setMode(mode)
            var needsNotificationBaseline = true
            for await value in snapshots {
                guard self != nil else { return }
                let diagnostics = await sampler.currentDiagnostics()
                guard self != nil else { return }
                if self?.snapshot != value {
                    self?.snapshot = value
                }
                self?.applyDiagnostics(diagnostics, snapshot: value)
                if needsNotificationBaseline {
                    needsNotificationBaseline = false
                    guard let notificationsEnabled = self?.notificationsEnabled else { return }
                    let outcome = await notifications.restore(
                        enabledPreference: notificationsEnabled,
                        currentThermalLevel: value.thermalLevel
                    )
                    guard self != nil else { return }
                    self?.applyNotificationOutcome(outcome)
                } else if self?.notificationsEnabled == true {
                    let outcome = await notifications.consume(
                        thermalLevel: value.thermalLevel,
                        transitionTimestamp: value.monotonicNanoseconds
                    )
                    guard self != nil else { return }
                    self?.applyNotificationOutcome(outcome)
                }
            }
        }
    }

    func setPanelVisible(_ visible: Bool) async {
        guard let generation = recordPanelVisibilityIntent(visible) else { return }
        await reconcilePanelVisibility(generation: generation)
    }

    /// Updates presentation and persistence synchronously, then reconciles sampling
    /// in generation order so a stale async sampler call cannot win a later intent.
    func setPanelVisibilityIntent(_ visible: Bool) {
        guard let generation = recordPanelVisibilityIntent(visible) else { return }
        panelVisibilityReconciliationTask?.cancel()
        panelVisibilityReconciliationTask = Task { @MainActor [weak self] in
            await self?.reconcilePanelVisibility(generation: generation)
        }
    }

    func setPanelOpacity(_ opacity: Double) {
        preferences.panelOpacity = opacity
        panelOpacity = preferences.panelOpacity
    }

    private func recordPanelVisibilityIntent(_ visible: Bool) -> UInt64? {
        guard panelVisible != visible else { return nil }
        panelVisible = visible
        preferences.panelVisible = visible
        panelVisibilityGeneration &+= 1
        return panelVisibilityGeneration
    }

    private func reconcilePanelVisibility(generation: UInt64) async {
        guard generation == panelVisibilityGeneration, isStreamReady, !isSleeping else { return }
        let intendedMode = activeSamplingMode
        await sampler.setMode(intendedMode)
        // A newer intent always schedules its own reconciliation. This guard avoids
        // any stale post-await work from treating an older mode as current.
        guard generation == panelVisibilityGeneration else { return }
    }

    func retrySensors() async {
        guard isStreamReady, !isSleeping else { return }
        await sampler.setMode(.sleeping)
        guard !isSleeping else { return }

        await sampler.setMode(activeSamplingMode)
        guard !isSleeping else { return }
        applyDiagnostics(await sampler.currentDiagnostics(), snapshot: snapshot)
    }

    func setNotificationsEnabled(_ enabled: Bool) async {
        let outcome = await notifications.setEnabled(enabled, currentThermalLevel: currentThermalLevel)
        let isEnabled = outcome == .enabled
        notificationsEnabled = isEnabled
        preferences.thermalNotifications = isEnabled
        notificationStateDidChange(isEnabled)
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        preferences.launchAtLogin = enabled
        let status = launchAtLogin.setEnabled(enabled)
        launchAtLoginStatus = status
        launchAtLoginEnabled = status == .enabled
    }

    func openLaunchAtLoginApprovalSettings() {
        guard launchAtLoginStatus == .requiresApproval else { return }
        _ = launchAtLogin.openApprovalSettingsIfNeeded()
        refreshLaunchAtLoginStatus()
    }

    func handleLifecycleEvent(_ event: WorkspaceLifecycle.Event) async {
        switch event {
        case .willSleep:
            isSleeping = true
            guard isStreamReady else { return }
            await sampler.setMode(.sleeping)
        case .didWake:
            isSleeping = false
            guard isStreamReady else { return }
            await sampler.setMode(activeSamplingMode)
        case .didActivate:
            refreshLaunchAtLoginStatus()
            let outcome = await notifications.reconcileOnActivation(currentThermalLevel: currentThermalLevel)
            applyNotificationOutcome(outcome)
        case .screenParametersChanged:
            break
        }
    }

    private var activeSamplingMode: SamplingMode {
        panelVisible ? .visible : .menuBarOnly
    }

    private var currentThermalLevel: ThermalLevel {
        snapshot?.thermalLevel ?? .nominal
    }

    private func refreshLaunchAtLoginStatus() {
        let status = launchAtLogin.refreshStatus()
        launchAtLoginStatus = status
        launchAtLoginEnabled = status == .enabled
    }

    private func applyNotificationOutcome(_ outcome: NotificationController.Outcome) {
        guard case .systemSettingsRequired = outcome else { return }
        notificationsEnabled = false
        preferences.thermalNotifications = false
        notificationStateDidChange(false)
    }

    private func applyDiagnostics(_ values: [SamplingDiagnostic], snapshot: SystemSnapshot?) {
        diagnostics = values
        diagnostic = values.first?.error ?? snapshot?.publicMetricError ?? snapshot?.privateMetricError
    }

    deinit {
        streamTask?.cancel()
        panelVisibilityReconciliationTask?.cancel()
    }
}
