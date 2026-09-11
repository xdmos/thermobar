import Foundation
import SwiftUI
import Testing
@testable import ThermoBar

@Test func resourceConsumerPresentationKeepsCPUAboveOneHundredPercent() {
    #expect(ResourceConsumerPresentation.cpu(237.4) == "237%")
}

@Test func resourceConsumerPresentationShowsGPUAndCPUWithoutInventingGPUData() {
    // The panel renders CPU and GPU as two reserved columns, so each value has
    // to stay short enough to fit its column on a single line.
    #expect(ResourceConsumerPresentation.cpu(6) == "6%")
    #expect(ResourceConsumerPresentation.gpu(82) == "82%")
    #expect(ResourceConsumerPresentation.gpu(nil) == "—")
    #expect(ResourceConsumerPresentation.computeAccessibility(rank: 1, name: "Codex Renderer", cpu: 116, gpu: nil, locale: Locale(identifier: "en_US")) == "Rank 1, Codex Renderer, CPU 116%, GPU —")
}

@Test func resourceConsumerPresentationKeepsRAMValueShortEnoughForItsTrailingColumn() {
    // The RAM row is a single line with a trailing-aligned value column, so the
    // formatted value has to stay a compact "<number> <unit>" pair.
    #expect(ResourceConsumerPresentation.memory(6_833 * 1_024 * 1_024, locale: Locale(identifier: "en_US")) == "6.7 GB")
}

@Test func resourceConsumerPresentationUsesBinaryMemoryUnits() {
    #expect(ResourceConsumerPresentation.memory(620 * 1_024 * 1_024, locale: Locale(identifier: "en_US")) == "620 MB")
    #expect(ResourceConsumerPresentation.memory(1_800 * 1_024 * 1_024, locale: Locale(identifier: "pl_PL")).contains(","))
}

@Test func resourceConsumerPresentationRejectsInvalidCPUAndKeepsAccessibilityNames() throws {
    #expect(ResourceConsumerPresentation.cpu(.infinity) == "—")
    #expect(ResourceConsumerPresentation.cpu(-1) == "—")
    #expect(ResourceConsumerPresentation.accessibility(rank: 2, name: "Long Untruncated Name", resource: "CPU", value: "237%", locale: Locale(identifier: "en_US")) == "Rank 2, Long Untruncated Name, CPU, 237%")
    // Build systems may either copy the catalog or compile it into lproj files.
    // Assert the source catalog directly so this contract is independent of that
    // packaging choice while the English bundle fallback remains executable.
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ThermoBar/Resources/Localizable.xcstrings")
    let catalog = try String(contentsOf: catalogURL, encoding: .utf8)
    #expect(catalog.contains("Pozycja %lld, %@, RAM, %@"))
    #expect(String(format: "Pozycja %lld, %@, RAM, %@", locale: Locale(identifier: "pl_PL"), 2, "Długi proces", "1,8 GB") == "Pozycja 2, Długi proces, RAM, 1,8 GB")
}

@Test func resourceConsumerPresentationHasDeterministicBinaryUnits() {
    #expect(ResourceConsumerPresentation.memory(620 * 1_024 * 1_024, locale: Locale(identifier: "en_US")) == "620 MB")
    #expect(ResourceConsumerPresentation.memory(1_800 * 1_024 * 1_024, locale: Locale(identifier: "pl_PL")) == "1,8 GB")
}

@Test func resourceConsumerSummaryFormatsTheApprovedSectionHeaders() {
    let summary = ResourceConsumerSummary(cpu: "18%", gpu: "7%", memory: "69%")
    #expect(summary.compute == "CPU 18% · GPU 7%")
    #expect(summary.memory == "69%")
}

@Test func activityMonitorButtonIncludesTheRowNameInBothLanguages() {
    #expect(ResourceConsumerPresentation.openActivityMonitor(name: "Finder", locale: Locale(identifier: "pl_PL")) == "Otwórz Monitor aktywności — Finder")
    #expect(ResourceConsumerPresentation.openActivityMonitor(name: "Finder", locale: Locale(identifier: "en_US")) == "Open Activity Monitor — Finder")
}

@Test func maximumConsumerColumnsLeaveAReadableNameAtThreeHundredPoints() {
    #expect(ResourceConsumerRowLayout.contentWidth == 300)
    #expect(ResourceConsumerRowLayout.maximumComputeNameWidth >= 70)
    #expect(ResourceConsumerRowLayout.maximumMemoryNameWidth >= 90)
    #expect(ResourceConsumerRowLayout.maximumDynamicTypeSize == .xxxLarge)
}

@Test func floatingPanelCollapsesToTheNarrowWidthWithoutTheConsumerColumn() {
    #expect(FloatingPanelLayout.totalWidth(showsConsumers: false) == 260)
    #expect(FloatingPanelLayout.totalWidth(showsConsumers: true) == 589)
}

@Test func thermobarPresentationPublishesConsumerHeaderSummariesFromTheSnapshot() {
    let presentation = ThermoBarPresentation(
        snapshot: PreviewFixtures.nominal,
        mode: .visible,
        nowNanoseconds: PreviewFixtures.nowNanoseconds
    )

    #expect(presentation.resourceConsumerSummary == .init(
        cpu: "26%",
        gpu: "19%",
        memory: "50%"
    ))
}

@Test func memoryRowsLabelApplicationGroupsWithTheirProcessCount() {
    #expect(ResourceConsumerPresentation.processCount(1) == nil)
    #expect(ResourceConsumerPresentation.processCount(36) == "(36)")
    #expect(ResourceConsumerPresentation.memoryName("Finder", processCount: 1) == "Finder")
    #expect(ResourceConsumerPresentation.memoryName("Claude", processCount: 36) == "Claude (36)")
    #expect(ResourceConsumerPresentation.accessibility(
        rank: 1,
        name: ResourceConsumerPresentation.memoryName("Claude", processCount: 36),
        resource: "RAM",
        value: "1.9 GB",
        locale: Locale(identifier: "en_US")
    ) == "Rank 1, Claude (36), RAM, 1.9 GB")
}
