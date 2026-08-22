import SwiftUI
import ThermoBarCore

enum FloatingPanelLayout {
    static let width: CGFloat = 260
}

struct FloatingPanelView: View {
    private let snapshot: SystemSnapshot?
    private let mode: SamplingMode
    private let nowNanoseconds: UInt64?
    private let diagnostics: [SamplingDiagnostic]
    private let resourceConsumerVisibility: ResourceConsumerVisibility
    private let accessibilityOverride: PreviewAccessibilityOverride?
    private let onClose: (() -> Void)?
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    init(snapshot: SystemSnapshot?, mode: SamplingMode, diagnostics: [SamplingDiagnostic] = [], resourceConsumerVisibility: ResourceConsumerVisibility = .all, nowNanoseconds: UInt64? = nil, accessibilityOverride: PreviewAccessibilityOverride? = nil, onClose: (() -> Void)? = nil) {
        self.snapshot = snapshot
        self.mode = mode
        self.diagnostics = diagnostics
        self.resourceConsumerVisibility = resourceConsumerVisibility
        self.nowNanoseconds = nowNanoseconds
        self.accessibilityOverride = accessibilityOverride
        self.onClose = onClose
    }

    var body: some View {
        FreshnessTimeline(snapshot: snapshot, mode: mode, nowNanoseconds: nowNanoseconds) { now in
            FloatingPanelContent(
                presentation: ThermoBarPresentation(snapshot: snapshot, mode: mode, nowNanoseconds: now),
                sensorStatus: ThermoBarPresentation.sensorStatus(snapshot: snapshot, diagnostics: diagnostics),
                resourceConsumerVisibility: resourceConsumerVisibility,
                background: FloatingPanelBackground(contrast: effectiveContrast),
                reduceMotion: effectiveReduceMotion,
                onClose: onClose
            )
        }
    }

    private var effectiveContrast: ColorSchemeContrast { accessibilityOverride?.contrast ?? colorSchemeContrast }
    private var effectiveReduceMotion: Bool { accessibilityOverride?.reduceMotion ?? accessibilityReduceMotion }
}

struct FloatingPanelContent: View {
    let presentation: ThermoBarPresentation
    let sensorStatus: ThermoBarPresentation.SensorStatus
    let resourceConsumerVisibility: ResourceConsumerVisibility
    let background: FloatingPanelBackground
    let reduceMotion: Bool
    let onClose: (() -> Void)?
    @ScaledMetric(relativeTo: .title2) private var hotspotFontSize = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            metricGrid
            if shouldShowFooter {
                Divider()
                footer
            }
        }
        .padding(14)
        .frame(width: FloatingPanelLayout.width, alignment: .leading)
        // The floating scene must follow the panel's intrinsic height. Without
        // this, a legacy 330-point window can compress and clip the process rows.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            background
        }
        .transaction { transaction in if reduceMotion { transaction.animation = nil } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(ThermoBarCopy.appName))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            ZStack {
                HStack {
                    Text(ThermoBarCopy.chipHotspot)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 6)
                    if let onClose {
                        Button(action: onClose) {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(ThermoBarCopy.hidePanel))
                    }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: presentation.hotspot)
                    .font(.system(size: hotspotFontSize, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(presentation.thermalTint)
                Spacer(minLength: 6)
                Text(presentation.thermalVerdict)
                    .font(.body.weight(.medium))
                    .foregroundStyle(presentation.thermalTint)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricGrid: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                MetricTile(
                    title: ThermoBarCopy.cpu,
                    value: presentation.cpuLoad,
                    detail: presentation.cpuTemperatureDetail,
                    fraction: presentation.cpuFraction,
                    tint: .blue
                )
                MetricTile(
                    title: ThermoBarCopy.gpu,
                    value: presentation.gpuLoad,
                    detail: presentation.gpuTemperatureDetail,
                    fraction: presentation.gpuFraction,
                    tint: .purple
                )
            }
            HStack(alignment: .top, spacing: 14) {
                MetricTile(
                    title: ThermoBarCopy.memory,
                    value: presentation.memory,
                    detail: presentation.memoryDetail,
                    fraction: presentation.memoryFraction,
                    tint: .teal
                )
                MetricTile(
                    title: ThermoBarCopy.fans,
                    value: presentation.fanSpeed,
                    detail: presentation.fanDetail,
                    fraction: presentation.fanFraction,
                    tint: .orange
                )
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
        if let diagnostic = ThermoBarPresentation.footerDiagnostic(for: sensorStatus) {
             HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                Text(verbatim: ThermoBarPresentation.diagnostic(diagnostic)).font(.caption).foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        } else if !presentation.isFresh {
             HStack(spacing: 6) {
            Image(systemName: presentation.isFresh ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(presentation.freshness)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        }
        if resourceConsumerVisibility.showsAny {
            ResourceConsumerList(metric: presentation.resourceConsumers, visibility: resourceConsumerVisibility)
        }
        }
    }

    private var shouldShowFooter: Bool {
        Self.shouldShowFooter(
            resourceConsumerVisibility: resourceConsumerVisibility,
            hasDiagnostic: ThermoBarPresentation.footerDiagnostic(for: sensorStatus) != nil,
            isFresh: presentation.isFresh
        )
    }

    static func shouldShowFooter(
        resourceConsumerVisibility: ResourceConsumerVisibility,
        hasDiagnostic: Bool,
        isFresh: Bool
    ) -> Bool {
        resourceConsumerVisibility.showsAny || hasDiagnostic || !isFresh
    }

}

struct FloatingPanelBackground: View {
    let contrast: ColorSchemeContrast

    var body: some View {
        if contrast == .increased {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.thickMaterial)
        } else {
            Color.clear
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }
}

struct PreviewAccessibilityOverride: Equatable {
    let contrast: ColorSchemeContrast
    let reduceMotion: Bool
}

struct FreshnessTimeline<Content: View>: View {
    private let snapshot: SystemSnapshot?
    private let mode: SamplingMode
    private let nowNanoseconds: UInt64?
    private let content: (UInt64) -> Content
    @State private var deadlineNowNanoseconds: UInt64?

    init(
        snapshot: SystemSnapshot?, mode: SamplingMode, nowNanoseconds: UInt64? = nil,
        @ViewBuilder content: @escaping (UInt64) -> Content
    ) {
        self.nowNanoseconds = nowNanoseconds
        self.snapshot = snapshot
        self.mode = mode
        self.content = content
    }

    var body: some View {
        Group {
            if let nowNanoseconds {
                content(nowNanoseconds)
            } else {
                content(deadlineNowNanoseconds ?? MonotonicClock.nowNanoseconds())
                    .task(id: FreshnessDeadlineID(snapshot: snapshot, mode: mode)) {
                        deadlineNowNanoseconds = nil
                        guard let snapshot, let deadline = SnapshotFreshness.staleDeadlineNanoseconds(snapshot: snapshot, mode: mode) else { return }
                        let now = MonotonicClock.nowNanoseconds()
                        if deadline > now { try? await Task.sleep(nanoseconds: deadline - now) }
                        guard !Task.isCancelled else { return }
                        deadlineNowNanoseconds = MonotonicClock.nowNanoseconds()
                    }
            }
        }
    }
}

/// Stable task identity: a new snapshot timestamp or sampling mode re-arms the deadline.
struct FreshnessDeadlineID: Equatable {
    let timestamp: UInt64?
    let mode: SamplingMode
    init(snapshot: SystemSnapshot?, mode: SamplingMode) { timestamp = snapshot?.monotonicNanoseconds; self.mode = mode }
}

struct ThermoBarPresentation {
    static let unavailable = "—"

    let isFresh: Bool
    let hotspot: String
    let cpuLoad: String
    let gpuLoad: String
    let memory: String
    let fanSpeed: String
    let cpuTemperatureDetail: String
    let gpuTemperatureDetail: String
    let memoryDetail: String
    let thermalVerdict: LocalizedStringResource
    let fanDetail: String
    let freshness: LocalizedStringResource
    let cpuFraction: Double?
    let gpuFraction: Double?
    let memoryFraction: Double?
    let fanFraction: Double?
    let thermalTint: Color
    let resourceConsumers: ResourceConsumerMetric

    init(snapshot: SystemSnapshot?, mode: SamplingMode, nowNanoseconds: UInt64) {
        guard let snapshot,
              SnapshotFreshness.isFresh(snapshot: snapshot, mode: mode, nowNanoseconds: nowNanoseconds)
        else {
            isFresh = false
            hotspot = Self.unavailable
            cpuLoad = Self.unavailable
            gpuLoad = Self.unavailable
            memory = Self.unavailable
            fanSpeed = Self.unavailable
            cpuTemperatureDetail = Self.temperatureDetail(ThermoBarCopy.cpuAverage, value: nil)
            gpuTemperatureDetail = Self.temperatureDetail(ThermoBarCopy.gpuAverage, value: nil)
            memoryDetail = Self.unavailable
            thermalVerdict = ThermoBarCopy.unavailable
            fanDetail = Self.unavailable
            freshness = ThermoBarCopy.stale
            cpuFraction = nil
            gpuFraction = nil
            memoryFraction = nil
            fanFraction = nil
            thermalTint = .secondary
            resourceConsumers = snapshot?.resourceConsumers ?? .init(cpu: .measuring, memory: .unavailable)
            return
        }

        isFresh = true
        hotspot = Self.temperature(snapshot.temperature.chipHotspotCelsius)
        cpuLoad = Self.percent(snapshot.cpuPercent)
        gpuLoad = Self.percent(snapshot.gpuPercent)
        memory = Self.memory(snapshot.memory)
        fanSpeed = Self.rpm(snapshot.fan.fastestRPM)
        cpuTemperatureDetail = Self.temperatureDetail(ThermoBarCopy.cpuAverage, value: snapshot.temperature.cpuAverageCelsius)
        gpuTemperatureDetail = Self.temperatureDetail(ThermoBarCopy.gpuAverage, value: snapshot.temperature.gpuAverageCelsius)
        memoryDetail = Self.memoryDetail(snapshot.memory)
        thermalVerdict = Self.verdict(for: snapshot.thermalLevel)
        fanDetail = snapshot.fan.fastestRPM == nil ? Self.unavailable : String(localized: ThermoBarCopy.fastest)
        freshness = ThermoBarCopy.fresh
        cpuFraction = Self.fraction(snapshot.cpuPercent)
        gpuFraction = Self.fraction(snapshot.gpuPercent)
        memoryFraction = snapshot.memory?.usedFraction
        fanFraction = Self.fanFraction(current: snapshot.fan.fastestRPM, maximum: snapshot.fan.fastestMaximumRPM)
        thermalTint = Self.tint(for: snapshot.thermalLevel)
        resourceConsumers = snapshot.resourceConsumers
    }

    static func roundedTemperature(_ value: Double) -> String {
        "\(Int(value.rounded()))°C"
    }

    private static func percent(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return "\(value.formatted(.number.precision(.fractionLength(0))))%"
    }

    private static func temperature(_ value: Double?) -> String {
        guard let value else { return unavailable }
        return "\(value.formatted(.number.precision(.fractionLength(1))))°C"
    }

    private static func memory(_ value: MemoryMetric?) -> String {
        guard let value else { return unavailable }
        return "\(gigabytes(value.usedBytes)) / \(gigabytes(value.totalBytes)) GB"
    }

    private static func memoryDetail(_ value: MemoryMetric?) -> String {
        guard let value else { return unavailable }
        return percent(value.usedFraction * 100)
    }

    private static func rpm(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return unavailable }
        return "\(Int(value.rounded())) RPM"
    }

    private static func fanFraction(current: Double?, maximum: Double?) -> Double? {
        guard let current, let maximum, current.isFinite, maximum.isFinite, maximum > 0 else { return nil }
        return min(max(current / maximum, 0), 1)
    }

    private static func gigabytes(_ value: UInt64) -> String {
        (Double(value) / 1_073_741_824).formatted(.number.precision(.fractionLength(1)))
    }

    private static func temperatureDetail(_ title: LocalizedStringResource, value: Double?) -> String {
        let title = String(localized: title)
        return "\(title): \(temperature(value))"
    }

    static func verdict(for level: ThermalLevel) -> LocalizedStringResource {
        switch level {
        case .nominal: ThermoBarCopy.nominal
        case .fair: ThermoBarCopy.fair
        case .serious: ThermoBarCopy.serious
        case .critical: ThermoBarCopy.critical
        }
    }

    enum SensorStatus: Equatable {
        case waiting
        case available
        case failed([SamplingDiagnostic])
    }

    static func sensorStatus(snapshot: SystemSnapshot?, diagnostics: [SamplingDiagnostic]) -> SensorStatus {
        guard snapshot != nil else { return .waiting }
        var values = diagnostics
        guard let snapshot else { return .waiting }
        func append(_ source: SamplingSource, _ error: MetricError?) {
            guard let error, !values.contains(where: { $0.source == source }) else { return }
            values.append(.init(source: source, error: error, consecutiveFailures: 1))
        }
        append(.cpuTemperature, snapshot.temperature.cpuError)
        append(.gpuTemperature, snapshot.temperature.gpuError)
        append(.fanSpeed, snapshot.fan.error)
        if snapshot.publicMetricError != nil {
            if snapshot.cpuPercent == nil { append(.cpu, snapshot.publicMetricError) }
            if snapshot.memory == nil { append(.memory, snapshot.publicMetricError) }
        }
        let hasPrecisePrivateDiagnostic = values.contains {
            switch $0.source {
            case .smcConnection, .cpuTemperature, .gpuTemperature, .fanSpeed, .gpuUtilization: true
            case .cpu, .memory: false
            }
        }
        if snapshot.privateMetricError != nil,
           snapshot.temperature.cpuError == nil,
           snapshot.temperature.gpuError == nil,
           !hasPrecisePrivateDiagnostic {
            append(.smcConnection, snapshot.privateMetricError)
        }
        return values.isEmpty ? .available : .failed(values)
    }

    /// Unsupported schemas are permanent presentation failures; transient failures need three samples.
    static func footerDiagnostic(for sensorStatus: SensorStatus) -> SamplingDiagnostic? {
        guard case .failed(let diagnostics) = sensorStatus else { return nil }
        return diagnostics.first(where: { $0.error == .unsupportedPrivateMetricSchema })
            ?? diagnostics.first(where: \.isPersistent)
    }

    private static func tint(for level: ThermalLevel) -> Color {
        switch level {
        case .nominal: .green
        case .fair: .yellow
        case .serious: .orange
        case .critical: .red
        }
    }

    private static func fraction(_ percentage: Double?) -> Double? {
        percentage.map { min(max($0 / 100, 0), 1) }
    }

    static func diagnostic(_ error: MetricError) -> String {
        let resource: LocalizedStringResource
        switch error {
        case .readFailed: resource = ThermoBarCopy.diagnosticReadFailed
        case .invalidValue: resource = ThermoBarCopy.diagnosticInvalidValue
        case .stale: resource = ThermoBarCopy.diagnosticStale
        case .unsupportedPrivateMetricSchema: resource = ThermoBarCopy.diagnosticUnsupportedSchema
        case .missingExpectedKey: resource = ThermoBarCopy.diagnosticMissingSensor
        case .unexpectedType: resource = ThermoBarCopy.diagnosticUnexpectedType
        }
        return String(localized: resource)
    }

    static func sourceName(_ source: SamplingSource) -> String {
        let resource: LocalizedStringResource
        switch source {
        case .smcConnection: resource = ThermoBarCopy.sourceSMCConnection
        case .cpuTemperature: resource = ThermoBarCopy.sourceCPUTemperature
        case .gpuTemperature: resource = ThermoBarCopy.sourceGPUTemperature
        case .fanSpeed: resource = ThermoBarCopy.sourceFanSpeed
        case .gpuUtilization: resource = ThermoBarCopy.sourceGPUUtilization
        case .cpu: resource = ThermoBarCopy.sourceCPUUtilization
        case .memory: resource = ThermoBarCopy.sourceMemory
        }
        return String(localized: resource)
    }

    static func diagnostic(_ value: SamplingDiagnostic) -> String {
        "\(sourceName(value.source)): \(diagnostic(value.error))"
    }
}

enum ThermoBarCopy {
    private static func resource(_ key: String.LocalizationValue) -> LocalizedStringResource {
        LocalizedStringResource(key, bundle: #bundle)
    }

    static let appName = resource("app.name")
    static let chipHotspot = resource("panel.chip-hotspot")
    static let cpu = resource("metric.cpu")
    static let gpu = resource("metric.gpu")
    static let memory = resource("metric.memory")
    static let fans = resource("metric.fans")
    static let fastest = resource("metric.fastest")
    static let cpuAverage = resource("metric.cpu-average")
    static let gpuAverage = resource("metric.gpu-average")
    static let nominal = resource("thermal.nominal")
    static let fair = resource("thermal.fair")
    static let serious = resource("thermal.serious")
    static let critical = resource("thermal.critical")
    static let unavailable = resource("status.unavailable")
    static let fresh = resource("status.fresh")
    static let stale = resource("status.stale")
    static let menuBarTemperature = resource("accessibility.menu-temperature")
    static let showPanel = resource("action.show-panel")
    static let hidePanel = resource("action.hide-panel")
    static let panelOpacity = resource("setting.panel-opacity")
    static let visibleInPanel = resource("setting.visible-in-panel")
    static let showComputeConsumers = resource("setting.show-compute-consumers")
    static let showMemoryConsumers = resource("setting.show-memory-consumers")
    static let showComputeConsumersAccessibility = resource("accessibility.show-compute-consumers")
    static let showMemoryConsumersAccessibility = resource("accessibility.show-memory-consumers")
    static let launchAtLogin = resource("setting.launch-at-login")
    static let thermalNotifications = resource("setting.thermal-notifications")
    static let settings = resource("action.settings")
    static let quit = resource("action.quit")
    static let openLoginItems = resource("action.open-login-items")
    static let launchAtLoginUnavailable = resource("status.launch-at-login-unavailable")
    static let waitingForSensors = resource("status.waiting-for-sensors")
    static let sensorsAvailable = resource("status.sensors-available")
    static let previewControls = resource("preview.controls")
    static let general = resource("settings.general")
    static let notifications = resource("settings.notifications")
    static let sensors = resource("settings.sensors")
    static let notificationInstructions = resource("settings.notification-instructions")
    static let sensorInstructions = resource("settings.sensor-instructions")
    static let launchAtLoginEnabled = resource("status.launch-at-login-enabled")
    static let launchAtLoginApprovalNeeded = resource("status.launch-at-login-approval-needed")
    static let launchAtLoginNotRegistered = resource("status.launch-at-login-not-registered")
    static let diagnosticReadFailed = resource("diagnostic.read-failed")
    static let diagnosticInvalidValue = resource("diagnostic.invalid-value")
    static let diagnosticStale = resource("diagnostic.stale")
    static let diagnosticUnsupportedSchema = resource("diagnostic.unsupported-schema")
    static let diagnosticMissingSensor = resource("diagnostic.missing-sensor")
    static let diagnosticUnexpectedType = resource("diagnostic.unexpected-type")
    static let retrySensors = resource("action.retry-sensors")
    static let sourceSMCConnection = resource("sensor.smc-connection")
    static let sourceCPUTemperature = resource("sensor.cpu-temperature")
    static let sourceGPUTemperature = resource("sensor.gpu-temperature")
    static let sourceFanSpeed = resource("sensor.fan-speed")
    static let sourceGPUUtilization = resource("sensor.gpu-utilization")
    static let sourceCPUUtilization = resource("sensor.cpu-utilization")
    static let sourceMemory = resource("sensor.memory")
    static let consumerCPUTitle = resource("consumer.cpu-title")
    static let consumerComputeTitle = resource("consumer.compute-title")
    static let consumerMemoryTitle = resource("consumer.memory-title")
    static let consumerMeasuring = resource("consumer.measuring")
    static let consumerUnavailable = resource("consumer.unavailable")
    static let consumerCPUAccessibility = resource("consumer.cpu-accessibility")
    static let consumerMemoryAccessibility = resource("consumer.memory-accessibility")
}

#Preview("Początkowy pomiar", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 360)) {
    FloatingPanelView(snapshot: nil, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
}

#Preview("Pomiar CPU i RAM", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 430)) {
    FloatingPanelView(snapshot: PreviewFixtures.measuring, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
}

#Preview("Rankingi procesów", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 500)) {
    FloatingPanelView(snapshot: PreviewFixtures.nominal, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
        .preferredColorScheme(.dark)
}

#Preview("Brak danych procesów", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 430)) {
    FloatingPanelView(snapshot: PreviewFixtures.unavailable, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
}

#Preview("Stan poważny", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 500)) {
    FloatingPanelView(snapshot: PreviewFixtures.serious, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
}

#Preview("Nieaktualne dane", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 500)) {
    FloatingPanelView(snapshot: PreviewFixtures.stale, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds)
}

#Preview("Nieobsługiwany schemat", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 500)) {
    FloatingPanelView(
        snapshot: PreviewFixtures.unsupportedSchema,
        mode: .visible,
        diagnostics: [.init(source: .cpuTemperature, error: .unsupportedPrivateMetricSchema, consecutiveFailures: 3)],
        nowNanoseconds: PreviewFixtures.nowNanoseconds
    )
}

#Preview("Częściowy błąd czujnika", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 500)) {
    FloatingPanelView(
        snapshot: PreviewFixtures.partialSensorFailure,
        mode: .visible,
        diagnostics: [.init(source: .cpuTemperature, error: .missingExpectedKey("Tp0m"), consecutiveFailures: 3)],
        nowNanoseconds: PreviewFixtures.nowNanoseconds
    )
}

#Preview("Jasny tryb i większy kontrast", traits: .fixedLayout(width: FloatingPanelLayout.width, height: 310)) {
    FloatingPanelView(snapshot: PreviewFixtures.nominal, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds,
        accessibilityOverride: .init(contrast: .increased, reduceMotion: false))
        .preferredColorScheme(.light)
}

#Preview("Duży tekst i ograniczony ruch", traits: .fixedLayout(width: 320, height: 440)) {
    FloatingPanelView(snapshot: PreviewFixtures.serious, mode: .visible, nowNanoseconds: PreviewFixtures.nowNanoseconds,
        accessibilityOverride: .init(contrast: .standard, reduceMotion: true))
        .dynamicTypeSize(.accessibility3)
}
