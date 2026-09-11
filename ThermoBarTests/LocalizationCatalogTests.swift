import Foundation
import Testing

/// The app bundle offers every language in the catalog, and macOS picks one from the
/// user's language order. A key missing from that language renders as the raw key, so
/// every entry must exist in every supported language.
@Test func everyCatalogEntryIsTranslatedIntoEverySupportedLanguage() throws {
    let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("ThermoBar/Resources/Localizable.xcstrings")
    let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
    let strings = try #require(catalog?["strings"] as? [String: [String: Any]])
    #expect(!strings.isEmpty)

    for language in ["pl", "en"] {
        let missing = strings.compactMap { key, entry -> String? in
            let localizations = entry["localizations"] as? [String: [String: Any]]
            let unit = localizations?[language]?["stringUnit"] as? [String: Any]
            let value = unit?["value"] as? String
            return value?.isEmpty == false ? nil : key
        }.sorted()
        #expect(missing.isEmpty, "Missing \(language) translations: \(missing)")
    }
}
