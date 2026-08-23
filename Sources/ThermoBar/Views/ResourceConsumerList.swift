import Foundation
import SwiftUI
import ThermoBarCore

struct ResourceConsumerVisibility: Equatable {
    static let all = Self(showCompute: true, showMemory: true)

    let showCompute: Bool
    let showMemory: Bool

    var showsAny: Bool { showCompute || showMemory }
}

private struct RankedConsumerRow<Row>: Identifiable {
    let index: Int
    let row: Row
    let id: Int32
}

enum ResourceConsumerPresentation {
    // Keep these catalog keys visible to the string-catalog compiler. The actual
    // lookup below chooses the caller's lproj bundle before formatting.
    private static let cpuAccessibilityCatalogKey = String(localized: "consumer.cpu-accessibility", defaultValue: "Rank %lld, %@, CPU, %@", bundle: .module)
    private static let memoryAccessibilityCatalogKey = String(localized: "consumer.memory-accessibility", defaultValue: "Rank %lld, %@, RAM, %@", bundle: .module)
    private static let computeAccessibilityCatalogKey = String(localized: "consumer.compute-accessibility", defaultValue: "Rank %lld, %@, GPU %@, CPU %@", bundle: .module)
    static func cpu(_ value: Double) -> String { guard value.isFinite, value >= 0, value <= Double(Int.max) else { return "—" }; return "\(Int(value.rounded()))%" }
    static func memory(_ bytes: UInt64, locale: Locale = .current) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(bytes); var index = 0
        while amount >= 1024, index < units.count - 1 { amount /= 1024; index += 1 }
        let formatter = NumberFormatter(); formatter.locale = locale; formatter.maximumFractionDigits = 1; formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "—") \(units[index])"
    }
    static func gpu(_ value: Double?) -> String { value.map(Self.cpu) ?? "—" }
    static func accessibility(rank: Int, name: String, resource: String, value: String, locale: Locale = .current) -> String {
        // `String(localized:locale:)` follows the app's preferred languages. Select
        // the matching .lproj bundle first so previews and presentation tests can
        // render a caller-supplied locale without any language-specific wording.
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
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
        let bundle = Bundle.module.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .module
        let format = bundle.localizedString(forKey: "consumer.compute-accessibility", value: Self.computeAccessibilityCatalogKey, table: nil)
        return String(format: format, locale: locale, rank, name, Self.cpu(cpu), gpu.map(Self.cpu) ?? "—")
    }
}

struct ResourceConsumerList: View {
    let metric: ResourceConsumerMetric
    let visibility: ResourceConsumerVisibility
    // The panel is only 260 points wide, so the process rows need reserved
    // numeric columns. Without them the CPU and GPU values wrap onto a second
    // line and every row ends up a different height.
    @ScaledMetric(relativeTo: .body) private var rankColumnWidth: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var valueColumnWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .body) private var memoryColumnWidth: CGFloat = 54

    init(metric: ResourceConsumerMetric, visibility: ResourceConsumerVisibility = .all) {
        self.metric = metric
        self.visibility = visibility
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
    }
    private var cpuSection: some View {
        computeSection
    }
    @ViewBuilder private var memorySection: some View {
        switch metric.memory {
        case .inactive:
            EmptyView()
        case let .available(rows) where !rows.isEmpty:
            VStack(alignment: .leading, spacing: 5) {
                Text(ThermoBarCopy.consumerMemoryTitle).font(.body.bold()).foregroundStyle(.primary).textCase(.uppercase)
                ForEach(rows.enumerated().map { RankedConsumerRow(index: $0.offset, row: $0.element, id: $0.element.pid) }) { ranked in
                    memoryRow(rank: ranked.index + 1, row: ranked.row)
                }
            }
        case .measuring:
            section(title: ThermoBarCopy.consumerMemoryTitle, state: metric.memory, id: \.pid, value: { ResourceConsumerPresentation.memory($0.physicalFootprintBytes) }, resource: "RAM")
        case .unavailable, .available:
            section(title: ThermoBarCopy.consumerMemoryTitle, state: metric.memory, id: \.pid, value: { ResourceConsumerPresentation.memory($0.physicalFootprintBytes) }, resource: "RAM")
        }
    }
    @ViewBuilder private var computeSection: some View {
        switch metric.cpu {
        case .inactive:
            EmptyView()
        case let .available(rows) where !rows.isEmpty:
            VStack(alignment: .leading, spacing: 5) {
                computeHeader
                ForEach(rows.enumerated().map { RankedConsumerRow(index: $0.offset, row: $0.element, id: $0.element.pid) }) { ranked in
                    computeRow(rank: ranked.index + 1, row: ranked.row)
                }
            }
        case .measuring:
            section(title: ThermoBarCopy.consumerComputeTitle, state: metric.cpu, id: \.pid, value: { ResourceConsumerPresentation.cpu($0.percent) }, resource: "CPU")
        case .unavailable, .available:
            section(title: ThermoBarCopy.consumerComputeTitle, state: metric.cpu, id: \.pid, value: { ResourceConsumerPresentation.cpu($0.percent) }, resource: "CPU")
        }
    }
    @ViewBuilder private func section<Row>(title: LocalizedStringResource, state: ResourceConsumerSection<Row>, id: KeyPath<Row, Int32>, value: @escaping (Row) -> String, resource: String) -> some View where Row: Equatable & Sendable {
        if case .inactive = state {
            EmptyView()
        } else {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.body.bold()).foregroundStyle(.primary).textCase(.uppercase)
            switch state {
            case .available(let rows) where !rows.isEmpty:
                ForEach(rows.enumerated().map { RankedConsumerRow(index: $0.offset, row: $0.element, id: $0.element[keyPath: id]) }) { ranked in
                    rowView(rank: ranked.index + 1, name: name(ranked.row), value: value(ranked.row), resource: resource)
                }
            case .measuring:
                Text(ThermoBarCopy.consumerMeasuring).font(.body).foregroundStyle(.secondary)
            case .unavailable, .available:
                Text(ThermoBarCopy.consumerUnavailable).font(.body).foregroundStyle(.secondary)
            case .inactive: EmptyView()
            }
        }
        }
    }
    private func name<Row>(_ row: Row) -> String {
        switch row { case let row as ResourceConsumerCPUEntry: row.name; case let row as ResourceConsumerMemoryEntry: row.name; default: "" }
    }
    private func rowView(rank: Int, name: String, value: String, resource: String) -> some View {
        HStack(spacing: 6) {
            Text("\(rank)").foregroundStyle(.tertiary).frame(width: rankColumnWidth, alignment: .leading)
            Text(verbatim: name).lineLimit(1).truncationMode(.tail).help(Text(verbatim: name))
            Spacer(minLength: 4)
            Text(verbatim: value).font(.body.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
        }
        .font(.body).accessibilityElement(children: .ignore).accessibilityLabel(ResourceConsumerPresentation.accessibility(rank: rank, name: name, resource: resource, value: value))
    }
    private var computeHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(ThermoBarCopy.consumerComputeTitle).font(.body.bold()).foregroundStyle(.primary).textCase(.uppercase)
            Spacer(minLength: 4)
            computeColumns(cpu: "CPU", gpu: "GPU")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }
    private func computeColumns(cpu: String, gpu: String) -> some View {
        HStack(spacing: 6) {
            Text(verbatim: cpu).frame(width: valueColumnWidth, alignment: .trailing)
            Text(verbatim: gpu).frame(width: valueColumnWidth, alignment: .trailing)
        }
        .lineLimit(1)
    }
    private func computeRow(rank: Int, row: ResourceConsumerCPUEntry) -> some View {
        HStack(spacing: 6) {
            Text("\(rank)").foregroundStyle(.tertiary).frame(width: rankColumnWidth, alignment: .leading)
            Text(verbatim: row.name).lineLimit(1).truncationMode(.tail).help(Text(verbatim: row.name))
            Spacer(minLength: 4)
            computeColumns(cpu: ResourceConsumerPresentation.cpu(row.percent), gpu: ResourceConsumerPresentation.gpu(row.gpuPercent))
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceConsumerPresentation.computeAccessibility(rank: rank, name: row.name, cpu: row.percent, gpu: row.gpuPercent))
    }
    private func memoryRow(rank: Int, row: ResourceConsumerMemoryEntry) -> some View {
        let value = ResourceConsumerPresentation.memory(row.physicalFootprintBytes)
        return HStack(spacing: 6) {
            Text("\(rank)").foregroundStyle(.tertiary).frame(width: rankColumnWidth, alignment: .leading)
            Text(verbatim: row.name).lineLimit(1).truncationMode(.tail).help(Text(verbatim: row.name))
            Spacer(minLength: 4)
            Text(verbatim: value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: memoryColumnWidth, alignment: .trailing)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceConsumerPresentation.accessibility(rank: rank, name: row.name, resource: "RAM", value: value))
    }
}
