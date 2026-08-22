import AppKit
import SwiftUI

struct MenuPopoverView: View {
    let model: AppModel
    private let nowNanoseconds: UInt64?

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(model: AppModel, nowNanoseconds: UInt64? = nil) {
        self.model = model
        self.nowNanoseconds = nowNanoseconds
    }

    var body: some View {
        FreshnessTimeline(snapshot: model.snapshot, mode: model.panelVisible ? .visible : .menuBarOnly, nowNanoseconds: nowNanoseconds) { now in
            content(nowNanoseconds: now)
        }
    }

    private func content(nowNanoseconds: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            status(nowNanoseconds: nowNanoseconds)
            Divider()
            Button(model.panelVisible ? ThermoBarCopy.hidePanel : ThermoBarCopy.showPanel) {
                let shouldShow = !model.panelVisible
                if shouldShow {
                    openWindow(id: "floating-panel")
                } else {
                    dismissWindow(id: "floating-panel")
                }
                model.setPanelVisibilityIntent(shouldShow)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(panelOpacityControl.accessibilityLabel)
                    Spacer()
                    Text(verbatim: panelOpacityControl.accessibilityValue())
                        .foregroundStyle(.secondary)
                }
                Slider(value: panelOpacityBinding, in: PanelOpacityControlConfiguration.range, step: PanelOpacityControlConfiguration.step)
                    .accessibilityLabel(Text(panelOpacityControl.accessibilityLabel))
                    .accessibilityValue(Text(verbatim: panelOpacityControl.accessibilityValue()))
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(ThermoBarCopy.panelView)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(ThermoBarCopy.showComputeConsumers, isOn: showComputeConsumersBinding)
                Toggle(ThermoBarCopy.showMemoryConsumers, isOn: showMemoryConsumersBinding)
            }
            Toggle(ThermoBarCopy.launchAtLogin, isOn: launchAtLoginBinding)
            launchAtLoginStatus
            Toggle(ThermoBarCopy.thermalNotifications, isOn: notificationBinding)
            sensorDiagnostic
            Button(ThermoBarCopy.retrySensors) {
                Task { await model.retrySensors() }
            }
            .font(.caption)
            Divider()
            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(ThermoBarCopy.quit, systemImage: "power")
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func status(nowNanoseconds: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ThermoBarCopy.appName)
                .font(.headline)
            Text(statusText(nowNanoseconds: nowNanoseconds))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var launchAtLoginStatus: some View {
        if model.launchAtLoginStatus == .requiresApproval {
            Button(ThermoBarCopy.openLoginItems) {
                model.openLaunchAtLoginApprovalSettings()
            }
            .font(.caption)
        } else if model.launchAtLoginStatus == .notFound {
            Text(ThermoBarCopy.launchAtLoginUnavailable)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sensorDiagnostic: some View {
        switch ThermoBarPresentation.sensorStatus(snapshot: model.snapshot, diagnostics: model.diagnostics) {
        case .waiting:
            diagnosticLine(systemImage: "clock", tint: .secondary, text: String(localized: ThermoBarCopy.waitingForSensors))
        case .available:
            diagnosticLine(systemImage: "checkmark.circle", tint: .green, text: String(localized: ThermoBarCopy.sensorsAvailable))
        case .failed(let diagnostics):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(diagnostics, id: \.source.rawValue) { diagnostic in
                    diagnosticLine(systemImage: "exclamationmark.triangle", tint: .orange, text: ThermoBarPresentation.diagnostic(diagnostic))
                }
            }
        }
    }

    private func diagnosticLine(systemImage: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    var panelOpacityBinding: Binding<Double> {
        Binding(
            get: { model.panelOpacity },
            set: { model.setPanelOpacity($0) }
        )
    }

    var showComputeConsumersBinding: Binding<Bool> {
        Binding(
            get: { model.showComputeConsumers },
            set: { model.setShowComputeConsumers($0) }
        )
    }

    var showMemoryConsumersBinding: Binding<Bool> {
        Binding(
            get: { model.showMemoryConsumers },
            set: { model.setShowMemoryConsumers($0) }
        )
    }

    private var panelOpacityControl: PanelOpacityControlConfiguration {
        PanelOpacityControlConfiguration(value: model.panelOpacity)
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { model.notificationsEnabled },
            set: { requestedValue in
                Task { await model.setNotificationsEnabled(requestedValue) }
            }
        )
    }

    private func statusText(nowNanoseconds: UInt64) -> String {
        guard let snapshot = model.snapshot else {
            return String(localized: ThermoBarCopy.waitingForSensors)
        }
        let presentation = ThermoBarPresentation(
            snapshot: snapshot,
            mode: model.panelVisible ? .visible : .menuBarOnly,
            nowNanoseconds: nowNanoseconds
        )
        guard presentation.isFresh else {
            return String(localized: ThermoBarCopy.stale)
        }
        return String(localized: ThermoBarPresentation.verdict(for: snapshot.thermalLevel))
    }
}

struct PanelOpacityControlConfiguration {
    static let range: ClosedRange<Double> = 0.30...1.00
    static let step = 0.05
    static let accessibilityLabelKey: String.LocalizationValue = "setting.panel-opacity"

    let value: Double

    var accessibilityLabel: LocalizedStringResource {
        ThermoBarCopy.panelOpacity
    }

    func accessibilityValue(locale: Locale = .current) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }
}

#Preview("Popover") {
    @Previewable @State var panelVisible = true
    VStack(alignment: .leading) {
        Toggle(ThermoBarCopy.showPanel, isOn: $panelVisible)
        Text(ThermoBarCopy.previewControls)
    }
    .padding()
    .frame(width: 260)
}
