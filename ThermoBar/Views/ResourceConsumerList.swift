import Foundation
import SwiftUI
import ThermoBarCore

struct ResourceConsumerVisibility: Equatable {
    static let all = Self(showCompute: true, showMemory: true)

    let showCompute: Bool
    let showMemory: Bool

    var showsAny: Bool { showCompute || showMemory }
}

struct ResourceConsumerSummary: Equatable {
    let cpu: String
    let gpu: String
    let memory: String

    var compute: String { "CPU \(cpu) · GPU \(gpu)" }
}

enum ResourceConsumerRowLayout {
    static let contentWidth: CGFloat = FloatingPanelLayout.consumerColumnWidth
    static let maximumIconSize: CGFloat = 26
    static let actionSize: CGFloat = 20
    static let maximumValueColumnWidth: CGFloat = 44
    static let maximumMemoryColumnWidth: CGFloat = 72
    static let spacing: CGFloat = 5
    static let maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge

    static let maximumComputeNameWidth = contentWidth
        - maximumIconSize - actionSize - (2 * maximumValueColumnWidth) - (4 * spacing)
    static let maximumMemoryNameWidth = contentWidth
        - maximumIconSize - actionSize - maximumMemoryColumnWidth - (3 * spacing)
}

enum ResourceConsumerPresentation {
    // Keep these catalog keys visible to the string-catalog compiler. The actual
    // lookup below chooses the caller's lproj bundle before formatting.
    private static let cpuAccessibilityCatalogKey = String(localized: "consumer.cpu-accessibility", defaultValue: "Rank %lld, %@, CPU, %@", bundle: .main)
    private static let memoryAccessibilityCatalogKey = String(localized: "consumer.memory-accessibility", defaultValue: "Rank %lld, %@, RAM, %@", bundle: .main)
    private static let computeAccessibilityCatalogKey = String(localized: "consumer.compute-accessibility", defaultValue: "Rank %lld, %@, GPU %@, CPU %@", bundle: .main)

    static func cpu(_ value: Double) -> String {
        guard value.isFinite, value >= 0, value <= Double(Int.max) else { return "—" }
        return "\(Int(value.rounded()))%"
    }

    static func memory(_ bytes: UInt64, locale: Locale = .current) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(bytes)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.maximumFractionDigits = 1
        formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "—") \(units[index])"
    }

    static func gpu(_ value: Double?) -> String { value.map(Self.cpu) ?? "—" }

    /// RAM rows sum every process of one application, so a group is labelled with
    /// its size. A single process needs no label: "(1)" would be noise on most rows.
    static func processCount(_ count: Int) -> String? {
        count > 1 ? "(\(count))" : nil
    }

    static func memoryName(_ name: String, processCount count: Int) -> String {
        processCount(count).map { "\(name) \($0)" } ?? name
    }

    static func accessibility(rank: Int, name: String, resource: String, value: String, locale: Locale = .current) -> String {
        // Select the matching .lproj bundle first so previews and presentation
        // tests can render a caller-supplied locale without language-specific
        // wording being taken from the host process.
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let format: String
        if resource == "CPU" {
            format = bundle.localizedString(forKey: "consumer.cpu-accessibility", value: Self.cpuAccessibilityCatalogKey, table: nil)
        } else {
            format = bundle.localizedString(forKey: "consumer.memory-accessibility", value: Self.memoryAccessibilityCatalogKey, table: nil)
        }
        return String(format: format, locale: locale, rank, name, value)
    }

    static func computeAccessibility(rank: Int, name: String, cpu: Double, gpu: Double?, locale: Locale = .current) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(forKey: "consumer.compute-accessibility", value: Self.computeAccessibilityCatalogKey, table: nil)
        return String(format: format, locale: locale, rank, name, Self.cpu(cpu), gpu.map(Self.cpu) ?? "—")
    }

    static func openActivityMonitor(name: String, locale: Locale = .current) -> String {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj")
            .flatMap(Bundle.init(path:)) ?? .main
        let format = bundle.localizedString(
            forKey: "action.open-activity-monitor",
            value: "Open Activity Monitor — %@",
            table: nil
        )
        return String(format: format, locale: locale, name)
    }
}

struct ResourceConsumerList: View {
    let metric: ResourceConsumerMetric
    let summary: ResourceConsumerSummary
    let visibility: ResourceConsumerVisibility
    let iconProvider: any ApplicationIconProviding
    let openActivityMonitor: () -> Void
    @ScaledMetric(relativeTo: .body) private var scaledIconSize: CGFloat = 22
    @ScaledMetric(relativeTo: .body) private var scaledValueColumnWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var scaledMemoryColumnWidth: CGFloat = 64

    init(
        metric: ResourceConsumerMetric,
        summary: ResourceConsumerSummary,
        visibility: ResourceConsumerVisibility = .all,
        iconProvider: any ApplicationIconProviding,
        openActivityMonitor: @escaping () -> Void
    ) {
        self.metric = metric
        self.summary = summary
        self.visibility = visibility
        self.iconProvider = iconProvider
        self.openActivityMonitor = openActivityMonitor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if visibility.showCompute {
                cpuSection
            }
            if visibility.showMemory {
                memorySection
            }
        }
        .dynamicTypeSize(...ResourceConsumerRowLayout.maximumDynamicTypeSize)
    }

    private var iconSize: CGFloat {
        min(scaledIconSize, ResourceConsumerRowLayout.maximumIconSize)
    }

    private var valueColumnWidth: CGFloat {
        min(scaledValueColumnWidth, ResourceConsumerRowLayout.maximumValueColumnWidth)
    }

    private var memoryColumnWidth: CGFloat {
        min(scaledMemoryColumnWidth, ResourceConsumerRowLayout.maximumMemoryColumnWidth)
    }

    @ViewBuilder
    private var cpuSection: some View {
        switch metric.cpu {
        case .inactive:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader(title: ThermoBarCopy.consumerComputeTitle, summary: summary.compute)
                computeHeader
                switch metric.cpu {
                case let .available(rows) where !rows.isEmpty:
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.element.pid) { rank, row in
                        computeRow(rank: rank + 1, row: row)
                    }
                case .measuring:
                    Text(ThermoBarCopy.consumerMeasuring).font(.body).foregroundStyle(.secondary)
                case .unavailable, .available:
                    Text(ThermoBarCopy.consumerUnavailable).font(.body).foregroundStyle(.secondary)
                case .inactive:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var memorySection: some View {
        switch metric.memory {
        case .inactive:
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 5) {
                sectionHeader(title: ThermoBarCopy.consumerMemoryTitle, summary: summary.memory)
                switch metric.memory {
                case let .available(rows) where !rows.isEmpty:
                    ForEach(Array(rows.prefix(5).enumerated()), id: \.element.pid) { rank, row in
                        memoryRow(rank: rank + 1, row: row)
                    }
                case .measuring:
                    Text(ThermoBarCopy.consumerMeasuring).font(.body).foregroundStyle(.secondary)
                case .unavailable, .available:
                    Text(ThermoBarCopy.consumerUnavailable).font(.body).foregroundStyle(.secondary)
                case .inactive:
                    EmptyView()
                }
            }
        }
    }

    private func sectionHeader(title: LocalizedStringResource, summary: String) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(.body.bold()).textCase(.uppercase)
                Spacer(minLength: 4)
                Text(verbatim: summary).font(.body.bold().monospacedDigit())
            }
            Divider()
        }
    }

    private var computeHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Spacer(minLength: 4)
            computeColumns(cpu: "CPU", gpu: "GPU")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private func computeColumns(cpu: String, gpu: String) -> some View {
        HStack(spacing: ResourceConsumerRowLayout.spacing) {
            Text(verbatim: cpu).frame(width: valueColumnWidth, alignment: .trailing)
            Text(verbatim: gpu).frame(width: valueColumnWidth, alignment: .trailing)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private func consumerIcon(path: String?) -> some View {
        if let icon = iconProvider.icon(for: path) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.dashed").resizable().scaledToFit().padding(3)
        }
    }

    private func activityMonitorButton(name: String) -> some View {
        let label = ResourceConsumerPresentation.openActivityMonitor(name: name)
        return Button(action: openActivityMonitor) {
            Image(systemName: "arrow.up.right.square")
                .frame(width: ResourceConsumerRowLayout.actionSize, height: ResourceConsumerRowLayout.actionSize)
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: label))
        .accessibilityLabel(Text(verbatim: label))
    }

    private func computeRow(rank: Int, row: ResourceConsumerCPUEntry) -> some View {
        HStack(spacing: ResourceConsumerRowLayout.spacing) {
            HStack(spacing: ResourceConsumerRowLayout.spacing) {
                consumerIcon(path: row.iconPath)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                Text(verbatim: row.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(Text(verbatim: row.name))
                Spacer(minLength: 4)
                computeColumns(
                    cpu: ResourceConsumerPresentation.cpu(row.percent),
                    gpu: ResourceConsumerPresentation.gpu(row.gpuPercent)
                )
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ResourceConsumerPresentation.computeAccessibility(
                    rank: rank,
                    name: row.name,
                    cpu: row.percent,
                    gpu: row.gpuPercent
                )
            )

            activityMonitorButton(name: row.name)
        }
        .font(.body)
    }

    private func memoryRow(rank: Int, row: ResourceConsumerMemoryEntry) -> some View {
        let value = ResourceConsumerPresentation.memory(row.physicalFootprintBytes)
        let displayName = ResourceConsumerPresentation.memoryName(row.name, processCount: row.processCount)
        return HStack(spacing: ResourceConsumerRowLayout.spacing) {
            HStack(spacing: ResourceConsumerRowLayout.spacing) {
                consumerIcon(path: row.iconPath)
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(.rect(cornerRadius: 6))
                    .accessibilityHidden(true)
                // The count is its own text so that truncating a long name never
                // cuts it off: the name gives way, the group size stays readable.
                HStack(spacing: 3) {
                    Text(verbatim: row.name)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let count = ResourceConsumerPresentation.processCount(row.processCount) {
                        Text(verbatim: count)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .help(Text(verbatim: displayName))
                Spacer(minLength: 4)
                Text(verbatim: value)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: memoryColumnWidth, alignment: .trailing)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                ResourceConsumerPresentation.accessibility(
                    rank: rank,
                    name: displayName,
                    resource: "RAM",
                    value: value
                )
            )

            activityMonitorButton(name: row.name)
        }
        .font(.body)
    }
}
