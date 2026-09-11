import SwiftUI
import ThermoBarCore

struct MenuBarLabel: View {
    private let snapshot: SystemSnapshot?
    private let mode: SamplingMode
    private let nowNanoseconds: UInt64?

    init(snapshot: SystemSnapshot?, mode: SamplingMode, nowNanoseconds: UInt64? = nil) {
        self.snapshot = snapshot
        self.mode = mode
        self.nowNanoseconds = nowNanoseconds
    }

    var body: some View {
        FreshnessTimeline(snapshot: snapshot, mode: mode, nowNanoseconds: nowNanoseconds) { now in
            label(nowNanoseconds: now)
        }
    }

    private func label(nowNanoseconds: UInt64) -> some View {
        let roundedHotspot: String?
        if let snapshot,
           SnapshotFreshness.isFresh(snapshot: snapshot, mode: mode, nowNanoseconds: nowNanoseconds),
           let hotspot = snapshot.temperature.chipHotspotCelsius {
            roundedHotspot = ThermoBarPresentation.roundedTemperature(hotspot)
        } else {
            roundedHotspot = nil
        }

        return HStack(spacing: 3) {
            Image(systemName: "thermometer.medium")
            if let roundedHotspot {
                Text(verbatim: roundedHotspot)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(roundedHotspot == nil ? Text(ThermoBarCopy.appName) : Text(ThermoBarCopy.menuBarTemperature))
        .accessibilityValue(roundedHotspot ?? ThermoBarPresentation.unavailable)
    }
}

#Preview("Świeży pasek menu") {
    MenuBarLabel(snapshot: PreviewFixtures.nominal, mode: .menuBarOnly, nowNanoseconds: PreviewFixtures.nowNanoseconds)
        .padding()
}

#Preview("Niedostępny pasek menu") {
    MenuBarLabel(snapshot: PreviewFixtures.unsupportedSchema, mode: .menuBarOnly, nowNanoseconds: PreviewFixtures.nowNanoseconds)
        .padding()
}
