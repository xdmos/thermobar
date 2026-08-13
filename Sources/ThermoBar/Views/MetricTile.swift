import SwiftUI

struct MetricTile: View {
    let title: LocalizedStringResource
    let value: String
    let detail: String?
    let fraction: Double?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.title3.monospacedDigit())
            if let fraction {
                ProgressView(value: fraction)
                    .tint(tint)
                    .accessibilityHidden(true)
            }
            if let detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue([value, detail].compactMap { $0 }.joined(separator: ", "))
    }
}
