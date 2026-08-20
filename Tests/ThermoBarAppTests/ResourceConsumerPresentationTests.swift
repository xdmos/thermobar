import Foundation
import Testing
@testable import ThermoBar

@Test func resourceConsumerPresentationKeepsCPUAboveOneHundredPercent() {
    #expect(ResourceConsumerPresentation.cpu(237.4) == "237%")
}

@Test func resourceConsumerPresentationShowsGPUAndCPUWithoutInventingGPUData() {
    #expect(ResourceConsumerPresentation.compute(cpu: 6, gpu: 82) == "GPU 82% · CPU 6%")
    #expect(ResourceConsumerPresentation.compute(cpu: 6, gpu: nil) == "GPU — · CPU 6%")
}

@Test func resourceConsumerPresentationSeparatesGPUAndCPUForNarrowPanelRows() {
    #expect(ResourceConsumerPresentation.computeDetails(cpu: 6, gpu: 82) == .init(gpu: "GPU 82%", cpu: "CPU 6%"))
    #expect(ResourceConsumerPresentation.computeDetails(cpu: 6, gpu: nil) == .init(gpu: "GPU —", cpu: "CPU 6%"))
}

@Test func resourceConsumerPresentationKeepsRAMValueAsItsOwnDetailLine() {
    #expect(ResourceConsumerPresentation.memoryDetail(6_833 * 1_024 * 1_024, locale: Locale(identifier: "en_US")) == "6.7 GB")
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
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/ThermoBar/Resources/Localizable.xcstrings")
    let catalog = try String(contentsOf: catalogURL, encoding: .utf8)
    #expect(catalog.contains("Pozycja %lld, %@, RAM, %@"))
    #expect(String(format: "Pozycja %lld, %@, RAM, %@", locale: Locale(identifier: "pl_PL"), 2, "Długi proces", "1,8 GB") == "Pozycja 2, Długi proces, RAM, 1,8 GB")
}

@Test func resourceConsumerPresentationHasDeterministicBinaryUnits() {
    #expect(ResourceConsumerPresentation.memory(620 * 1_024 * 1_024, locale: Locale(identifier: "en_US")) == "620 MB")
    #expect(ResourceConsumerPresentation.memory(1_800 * 1_024 * 1_024, locale: Locale(identifier: "pl_PL")) == "1,8 GB")
}
