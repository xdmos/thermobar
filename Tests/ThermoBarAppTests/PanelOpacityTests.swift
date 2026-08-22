import Foundation
import SwiftUI
import Testing
@testable import ThermoBar
@testable import ThermoBarCore

@Test @MainActor func panelOpacityDefaultsToOneHundredPercentAndPersistsValidValues() {
    let defaults = panelOpacityDefaults()
    let preferences = AppPreferences(defaults: defaults)

    #expect(preferences.panelOpacity == 1.00)

    preferences.panelOpacity = 0.65

    #expect(preferences.panelOpacity == 0.65)
    #expect(AppPreferences(defaults: defaults).panelOpacity == 0.65)
}

@Test @MainActor func panelOpacityClampsFiniteAssignmentsToItsSupportedRange() {
    let preferences = AppPreferences(defaults: panelOpacityDefaults())

    preferences.panelOpacity = 0.10
    #expect(preferences.panelOpacity == 0.30)

    preferences.panelOpacity = 1.50
    #expect(preferences.panelOpacity == 1.00)
}

@Test @MainActor func panelOpacityUsesDefaultForNonFiniteAssignmentsAndInvalidPersistedValues() {
    let defaults = panelOpacityDefaults()
    let preferences = AppPreferences(defaults: defaults)

    preferences.panelOpacity = .nan
    #expect(preferences.panelOpacity == 1.00)
    preferences.panelOpacity = .infinity
    #expect(preferences.panelOpacity == 1.00)

    defaults.set("invalid", forKey: "thermobar.panelOpacity")
    #expect(AppPreferences(defaults: defaults).panelOpacity == 1.00)
    defaults.set(Double.nan, forKey: "thermobar.panelOpacity")
    #expect(AppPreferences(defaults: defaults).panelOpacity == 1.00)
    defaults.set(0.25, forKey: "thermobar.panelOpacity")
    #expect(AppPreferences(defaults: defaults).panelOpacity == 1.00)
    defaults.set(1.05, forKey: "thermobar.panelOpacity")
    #expect(AppPreferences(defaults: defaults).panelOpacity == 1.00)
}

@Test @MainActor func settingPanelOpacitySynchronizesAndPersistsWithoutTouchingTheSampler() async {
    let defaults = panelOpacityDefaults()
    let preferences = AppPreferences(defaults: defaults)
    let sampler = OpacityCountingSampler()
    let model = AppModel(
        preferences: preferences,
        sampler: sampler,
        notifications: OpacityNoopNotifications()
    )

    model.setPanelOpacity(0.30)

    #expect(model.panelOpacity == 0.30)
    #expect(preferences.panelOpacity == 0.30)
    #expect(AppPreferences(defaults: defaults).panelOpacity == 0.30)
    #expect(await sampler.snapshotRequests == 0)
    #expect(await sampler.setModeRequests == 0)
}

@Test @MainActor func panelOpacityControlUsesTheSpecifiedSliderAndAccessibilityContract() {
    let configuration = PanelOpacityControlConfiguration(value: 0.65)

    #expect(PanelOpacityControlConfiguration.range == 0.30...1.00)
    #expect(PanelOpacityControlConfiguration.step == 0.05)
    #expect(PanelOpacityControlConfiguration.accessibilityLabelKey == "setting.panel-opacity")
    #expect(configuration.accessibilityValue(locale: Locale(identifier: "en_US_POSIX")) == "65%")
}

@Test @MainActor func panelOpacityMenuBindingPersistsTheLiveSliderValue() {
    let defaults = panelOpacityDefaults()
    let preferences = AppPreferences(defaults: defaults)
    let model = AppModel(
        preferences: preferences,
        sampler: OpacityCountingSampler(),
        notifications: OpacityNoopNotifications()
    )
    let menu = MenuPopoverView(model: model)

    menu.panelOpacityBinding.wrappedValue = 0.65

    #expect(model.panelOpacity == 0.65)
    #expect(AppPreferences(defaults: defaults).panelOpacity == 0.65)
}

@Test @MainActor func consumerVisibilityDefaultsToVisibleAndRejectsInvalidStoredValues() {
    let defaults = panelOpacityDefaults()

    #expect(AppPreferences(defaults: defaults).showComputeConsumers)
    #expect(AppPreferences(defaults: defaults).showMemoryConsumers)

    defaults.set("invalid", forKey: "thermobar.showComputeConsumers")
    defaults.set("invalid", forKey: "thermobar.showMemoryConsumers")

    #expect(AppPreferences(defaults: defaults).showComputeConsumers)
    #expect(AppPreferences(defaults: defaults).showMemoryConsumers)
}

@Test @MainActor func consumerVisibilityModelAndMenuBindingsPersistIndependently() {
    let defaults = panelOpacityDefaults()
    let preferences = AppPreferences(defaults: defaults)
    let model = AppModel(
        preferences: preferences,
        sampler: OpacityCountingSampler(),
        notifications: OpacityNoopNotifications()
    )
    let menu = MenuPopoverView(model: model)

    menu.showComputeConsumersBinding.wrappedValue = false

    #expect(!model.showComputeConsumers)
    #expect(model.showMemoryConsumers)
    #expect(!AppPreferences(defaults: defaults).showComputeConsumers)
    #expect(AppPreferences(defaults: defaults).showMemoryConsumers)

    menu.showMemoryConsumersBinding.wrappedValue = false

    #expect(!model.showMemoryConsumers)
    #expect(!AppPreferences(defaults: defaults).showMemoryConsumers)
}

@Test func consumerVisibilityMenuUsesCompactLabelsAndDescriptiveAccessibilityLabels() throws {
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/ThermoBar/Resources/Localizable.xcstrings")
    let catalog = try String(contentsOf: catalogURL, encoding: .utf8)

    #expect(catalog.contains("\"setting.visible-in-panel\""))
    #expect(catalog.contains("\"value\" : \"CPU/GPU\""))
    #expect(catalog.contains("\"value\" : \"RAM\""))
    #expect(catalog.contains("\"accessibility.show-compute-consumers\""))
    #expect(catalog.contains("\"accessibility.show-memory-consumers\""))
}

@Test @MainActor func floatingPanelContentKeepsItsBackgroundAtFullStrengthForWindowLevelOpacity() {
    let background = FloatingPanelBackground(contrast: .standard)
    let content = FloatingPanelContent(
        presentation: ThermoBarPresentation(snapshot: nil, mode: .visible, nowNanoseconds: 1),
        sensorStatus: .waiting,
        resourceConsumerVisibility: .all,
        background: background,
        reduceMotion: false,
        onClose: nil
    )

    #expect(content.background.contrast == .standard)
}

@Test @MainActor func consumerVisibilityControlsTheFooterWithoutSuppressingWarnings() {
    let neither = ResourceConsumerVisibility(showCompute: false, showMemory: false)

    #expect(!FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: neither, hasDiagnostic: false, isFresh: true))
    #expect(FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: .init(showCompute: true, showMemory: false), hasDiagnostic: false, isFresh: true))
    #expect(FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: .init(showCompute: false, showMemory: true), hasDiagnostic: false, isFresh: true))
    #expect(FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: .all, hasDiagnostic: false, isFresh: true))
    #expect(FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: neither, hasDiagnostic: true, isFresh: true))
    #expect(FloatingPanelContent.shouldShowFooter(resourceConsumerVisibility: neither, hasDiagnostic: false, isFresh: false))
}

@MainActor private func panelOpacityDefaults() -> UserDefaults {
    let suiteName = "PanelOpacityTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        fatalError("Could not create isolated defaults suite")
    }
    return defaults
}

private actor OpacityCountingSampler: SamplingControlling {
    private(set) var snapshotRequests = 0
    private(set) var setModeRequests = 0

    func snapshots() -> AsyncStream<SamplingSnapshot> {
        snapshotRequests += 1
        return AsyncStream { $0.finish() }
    }

    func thermalSamples() -> AsyncStream<ThermalSample> { AsyncStream { $0.finish() } }

    func setMode(_ mode: SamplingMode, transitionID: UUID) async -> SamplingTransitionReceipt {
        setModeRequests += 1
        return .init(requestedTransitionID: transitionID, currentTransitionID: transitionID, currentMode: mode, isCurrent: true)
    }

    func currentDiagnostics() async -> [SamplingDiagnostic] {
        []
    }
}

private struct OpacityNoopNotifications: NotificationControlling {
    func restore(enabledPreference: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        fatalError("Notifications are not used by this test")
    }

    func reconcileOnActivation(currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        fatalError("Notifications are not used by this test")
    }

    func setEnabled(_ shouldEnable: Bool, currentThermalLevel: ThermalLevel) async -> NotificationController.Outcome {
        fatalError("Notifications are not used by this test")
    }

    func consume(thermalLevel: ThermalLevel, transitionTimestamp: UInt64) async -> NotificationController.Outcome {
        fatalError("Notifications are not used by this test")
    }
}
