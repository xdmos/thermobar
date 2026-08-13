import Foundation
import Observation
import ThermoBarCore

protocol SamplingControlling: Sendable {
    func snapshots() async -> AsyncStream<SamplingSnapshot>
    func thermalSamples() async -> AsyncStream<ThermalSample>
    func setMode(_ mode: SamplingMode, transitionID: UUID) async -> SamplingTransitionReceipt
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
    @ObservationIgnored private var activeTransitionID = UUID()
    @ObservationIgnored private var thermalTask: Task<Void, Never>?

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
            // Attach both continuations before asking the sampler for its immediate sample.
            let snapshots = await sampler.snapshots()
            let thermal = await sampler.thermalSamples()
            guard self != nil else { return }
            self?.isStreamReady = true
            let mode = self?.isSleeping == true ? SamplingMode.sleeping : self?.activeSamplingMode ?? .sleeping
            self?.thermalTask = Task { [weak self, notifications] in
                var baseline = true
                for await sample in thermal {
                    guard let self else { return }
                    let outcome: NotificationController.Outcome
                    if baseline { baseline = false; outcome = await notifications.restore(enabledPreference: self.notificationsEnabled, currentThermalLevel: sample.level) }
                    else if self.notificationsEnabled { outcome = await notifications.consume(thermalLevel: sample.level, transitionTimestamp: sample.monotonicNanoseconds) }
                    else { continue }
                    self.applyNotificationOutcome(outcome)
                }
            }
            _ = await self?.requestMode(mode)
            for await delivered in snapshots {
                guard self != nil else { return }
                // Accept (or drop) the identity-bearing delivery before the first
                // suspension. If sleep starts while diagnostics are pending it
                // synchronously redacts `snapshot`, and this loop retains only the
                // transition UUID across that suspension.
                guard let acceptedTransitionID = self?.applySnapshotIfCurrent(delivered) else { continue }
                let diagnostics = await sampler.currentDiagnostics()
                guard self != nil else { return }
                guard self?.accepts(transitionID: acceptedTransitionID) == true else { continue }
                self?.applyDiagnostics(diagnostics, snapshot: self?.snapshot)
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
        _ = await requestMode(intendedMode)
        // A newer intent always schedules its own reconciliation. This guard avoids
        // any stale post-await work from treating an older mode as current.
        guard generation == panelVisibilityGeneration else { return }
    }

    func retrySensors() async {
        guard isStreamReady, !isSleeping else { return }
        _ = await requestMode(.sleeping)
        guard !isSleeping else { return }

        _ = await requestMode(activeSamplingMode)
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
            activeTransitionID = UUID()
            if let snapshot { self.snapshot = snapshot.replacing(resourceConsumers: .inactive) }
            guard isStreamReady else { return }
            _ = await sampler.setMode(.sleeping, transitionID: activeTransitionID)
        case .didWake:
            isSleeping = false
            guard isStreamReady else { return }
            _ = await requestMode(activeSamplingMode)
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
    private func requestMode(_ mode: SamplingMode) async -> SamplingTransitionReceipt {
        let id = UUID(); activeTransitionID = id
        let receipt = await sampler.setMode(mode, transitionID: id)
        // A same-mode join deliberately keeps the sampler's existing stable UUID,
        // so `isCurrent` is false for our fresh requested UUID. It is still the
        // authoritative identity while this remains the latest AppModel intent.
        if activeTransitionID == id { activeTransitionID = receipt.currentTransitionID }
        return receipt
    }
    private func accepts(transitionID: UUID) -> Bool {
        !isSleeping && transitionID == activeTransitionID
    }
    private func applySnapshotIfCurrent(_ delivered: SamplingSnapshot) -> UUID? {
        guard accepts(transitionID: delivered.transitionID) else { return nil }
        if snapshot != delivered.value { snapshot = delivered.value }
        return delivered.transitionID
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
        thermalTask?.cancel()
    }
}
