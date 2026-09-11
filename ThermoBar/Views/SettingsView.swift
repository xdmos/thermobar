import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section(ThermoBarCopy.general) {
                Toggle(ThermoBarCopy.launchAtLogin, isOn: launchAtLoginBinding)
                launchAtLoginDetail
            }
            Section(ThermoBarCopy.notifications) {
                Toggle(ThermoBarCopy.thermalNotifications, isOn: notificationBinding)
                Text(ThermoBarCopy.notificationInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section(ThermoBarCopy.sensors) {
                sensorDiagnostic
                Button(ThermoBarCopy.retrySensors) {
                    Task { await model.retrySensors() }
                }
                Text(ThermoBarCopy.sensorInstructions)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420, height: 260)
    }

    @ViewBuilder
    private var launchAtLoginDetail: some View {
        switch model.launchAtLoginStatus {
        case .enabled:
            Text(ThermoBarCopy.launchAtLoginEnabled)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .requiresApproval:
            VStack(alignment: .leading, spacing: 4) {
                Text(ThermoBarCopy.launchAtLoginApprovalNeeded)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(ThermoBarCopy.openLoginItems) {
                    model.openLaunchAtLoginApprovalSettings()
                }
            }
        case .notRegistered:
            Text(ThermoBarCopy.launchAtLoginNotRegistered)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .notFound:
            Text(ThermoBarCopy.launchAtLoginUnavailable)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }

    private var notificationBinding: Binding<Bool> {
        Binding(
            get: { model.notificationsEnabled },
            set: { requestedValue in
                Task { await model.setNotificationsEnabled(requestedValue) }
            }
        )
    }

    @ViewBuilder
    private var sensorDiagnostic: some View {
        switch ThermoBarPresentation.sensorStatus(snapshot: model.snapshot, diagnostics: model.diagnostics) {
        case .waiting:
            Text(ThermoBarCopy.waitingForSensors)
        case .available:
            Text(ThermoBarCopy.sensorsAvailable)
        case .failed(let diagnostics):
            ForEach(diagnostics, id: \.source.rawValue) { diagnostic in
                Text(verbatim: ThermoBarPresentation.diagnostic(diagnostic))
            }
        }
    }
}

#Preview("Ustawienia — interaktywne") {
    @Previewable @State var launchAtLogin = false
    @Previewable @State var notifications = true
    Form {
        Section(ThermoBarCopy.general) {
            Toggle(ThermoBarCopy.launchAtLogin, isOn: $launchAtLogin)
        }
        Section(ThermoBarCopy.notifications) {
            Toggle(ThermoBarCopy.thermalNotifications, isOn: $notifications)
            Text(ThermoBarCopy.notificationInstructions)
        }
    }
    .formStyle(.grouped)
    .frame(width: 420, height: 220)
}
