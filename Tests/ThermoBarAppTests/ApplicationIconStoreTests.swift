import AppKit
import Testing
@testable import ThermoBar

@Test @MainActor
func applicationIconStoreCachesOneWorkspaceLookupPerExistingPath() {
    var loads = 0
    let expected = NSImage(size: NSSize(width: 16, height: 16))
    let store = ApplicationIconStore(
        fileExists: { $0 == "/Applications/Test.app" },
        loadIcon: { _ in loads += 1; return expected }
    )

    let first = store.icon(for: "/Applications/Test.app")
    let second = store.icon(for: "/Applications/Test.app")

    #expect(first === expected)
    #expect(second === expected)
    #expect(loads == 1)
}

@Test @MainActor
func applicationIconStoreRejectsMissingEmptyAndNilPathsWithoutLoading() {
    var loads = 0
    let store = ApplicationIconStore(
        fileExists: { _ in false },
        loadIcon: { _ in loads += 1; return NSImage() }
    )

    #expect(store.icon(for: nil) == nil)
    #expect(store.icon(for: "") == nil)
    #expect(store.icon(for: "/missing") == nil)
    #expect(loads == 0)
}
