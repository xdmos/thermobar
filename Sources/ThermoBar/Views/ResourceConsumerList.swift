import Foundation
import SwiftUI
import ThermoBarCore

enum ResourceConsumerPresentation {
    // Keep these catalog keys visible to the string-catalog compiler. The actual
    // lookup below chooses the caller's lproj bundle before formatting.
    private static let cpuAccessibilityCatalogKey = String(localized: "consumer.cpu-accessibility", defaultValue: "Rank %lld, %@, CPU, %@", bundle: .module)
    private static let memoryAccessibilityCatalogKey = String(localized: "consumer.memory-accessibility", defaultValue: "Rank %lld, %@, RAM, %@", bundle: .module)
    static func cpu(_ value: Double) -> String { guard value.isFinite, value >= 0, value <= Double(Int.max) else { return "—" }; return "\(Int(value.rounded()))%" }
    static func memory(_ bytes: UInt64, locale: Locale = .current) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var amount = Double(bytes); var index = 0
        while amount >= 1024, index < units.count - 1 { amount /= 1024; index += 1 }
        let formatter = NumberFormatter(); formatter.locale = locale; formatter.maximumFractionDigits = 1; formatter.minimumFractionDigits = 0
        return "\(formatter.string(from: NSNumber(value: amount)) ?? "—") \(units[index])"
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
}

struct ResourceConsumerList: View {
    let metric: ResourceConsumerMetric
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cpuSection
            memorySection
        }
    }
    private var cpuSection: some View {
        section(title: ThermoBarCopy.consumerCPUTitle, state: metric.cpu, value: { ResourceConsumerPresentation.cpu($0.percent) }, resource: "CPU")
    }
    private var memorySection: some View {
        section(title: ThermoBarCopy.consumerMemoryTitle, state: metric.memory, value: { ResourceConsumerPresentation.memory($0.physicalFootprintBytes) }, resource: "RAM")
    }
    @ViewBuilder private func section<Row>(title: LocalizedStringResource, state: ResourceConsumerSection<Row>, value: @escaping (Row) -> String, resource: String) -> some View where Row: Equatable & Sendable {
        if case .inactive = state {
            EmptyView()
        } else {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.body.weight(.semibold)).foregroundStyle(.secondary)
            switch state {
            case .available(let rows) where !rows.isEmpty:
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    rowView(rank: index + 1, name: name(row), value: value(row), resource: resource)
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
}
