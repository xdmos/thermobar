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
    struct ComputeDetails: Equatable {
        let gpu: String
        let cpu: String
    }
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
    static func memoryDetail(_ bytes: UInt64, locale: Locale = .current) -> String { memory(bytes, locale: locale) }
    static func computeDetails(cpu: Double, gpu: Double?) -> ComputeDetails { .init(gpu: "GPU \(gpu.map(Self.cpu) ?? "—")", cpu: "CPU \(Self.cpu(cpu))") }
    static func compute(cpu: Double, gpu: Double?) -> String {
        let details = computeDetails(cpu: cpu, gpu: gpu)
        return "\(details.gpu) · \(details.cpu)"
    }
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
        return String(format: format, locale: locale, rank, name, gpu.map(Self.cpu) ?? "—", Self.cpu(cpu))
    }
}

struct ResourceConsumerList: View {
    let metric: ResourceConsumerMetric
    let visibility: ResourceConsumerVisibility

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
                Text(ThermoBarCopy.consumerMemoryTitle).font(.body.weight(.semibold)).foregroundStyle(.secondary)
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
                Text(ThermoBarCopy.consumerComputeTitle).font(.body.weight(.semibold)).foregroundStyle(.secondary)
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
            Text(title).font(.body.weight(.semibold)).foregroundStyle(.secondary)
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
            Text("\(rank)").foregroundStyle(.tertiary).frame(width: 10, alignment: .leading)
            Text(verbatim: name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Text(verbatim: value).font(.body.monospacedDigit()).foregroundStyle(.secondary)
        }
        .font(.body).accessibilityElement(children: .ignore).accessibilityLabel(ResourceConsumerPresentation.accessibility(rank: rank, name: name, resource: resource, value: value))
    }
    private func computeRow(rank: Int, row: ResourceConsumerCPUEntry) -> some View {
        let details = ResourceConsumerPresentation.computeDetails(cpu: row.percent, gpu: row.gpuPercent)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(rank)").foregroundStyle(.tertiary).frame(width: 10, alignment: .leading)
                Text(verbatim: row.name).lineLimit(1).truncationMode(.tail)
            }
            Text(verbatim: "\(details.gpu)  ·  \(details.cpu)")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceConsumerPresentation.computeAccessibility(rank: rank, name: row.name, cpu: row.percent, gpu: row.gpuPercent))
    }
    private func memoryRow(rank: Int, row: ResourceConsumerMemoryEntry) -> some View {
        let value = ResourceConsumerPresentation.memoryDetail(row.physicalFootprintBytes)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(rank)").foregroundStyle(.tertiary).frame(width: 10, alignment: .leading)
                Text(verbatim: row.name).lineLimit(1).truncationMode(.tail)
            }
            Text(verbatim: value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.leading, 16)
        }
        .font(.body)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ResourceConsumerPresentation.accessibility(rank: rank, name: row.name, resource: "RAM", value: value))
    }
}
