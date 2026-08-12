import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ThermoBar

@Suite("PanelFrameStoreTests")
struct PanelFrameStoreTests {
    private let primary = PanelFrameStore.Screen(
        displayIdentifier: 1,
        visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
    )

    @Test func preservesAnAlreadyVisibleFrameOnItsSavedDisplay() {
        let saved = PanelFrameRecord(displayIdentifier: 1, x: 100, y: 120, width: 238, height: 330)

        #expect(PanelFrameStore.restore(saved: saved, screens: [primary]) == CGRect(x: 100, y: 120, width: 238, height: 330))
    }

    @Test func matchingDisplayIdentifierPreservesOriginOnlyWithAMeaningfulIntersection() {
        let right = PanelFrameStore.Screen(
            displayIdentifier: 2,
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900)
        )
        let thinSeamOnSavedDisplay = PanelFrameRecord(displayIdentifier: 1, x: 1_420, y: 100, width: 238, height: 330)
        let meaningfulIntersectionOnSavedDisplay = PanelFrameRecord(displayIdentifier: 1, x: 1_400, y: 100, width: 238, height: 330)

        // A 20-point seam on display 1 must move to display 2, where the frame has
        // a meaningful 218-point intersection. A 40-point overlap remains on display 1.
        #expect(PanelFrameStore.restore(saved: thinSeamOnSavedDisplay, screens: [primary, right]) == CGRect(x: 1_452, y: 100, width: 238, height: 330))
        #expect(PanelFrameStore.restore(saved: meaningfulIntersectionOnSavedDisplay, screens: [primary, right]) == CGRect(x: 1_190, y: 100, width: 238, height: 330))
    }

    @Test func disconnectedDisplayUsesNearestCurrentScreenAndKeepsTheFrameVisible() {
        let saved = PanelFrameRecord(displayIdentifier: 99, x: 2_000, y: 80, width: 238, height: 330)

        #expect(PanelFrameStore.restore(saved: saved, screens: [primary]) == CGRect(x: 1_190, y: 80, width: 238, height: 330))
    }

    @Test func clampsAgainstNegativeScreenOrigins() {
        let left = PanelFrameStore.Screen(
            displayIdentifier: 2,
            visibleFrame: CGRect(x: -1_280, y: 0, width: 1_280, height: 800)
        )
        let saved = PanelFrameRecord(displayIdentifier: 2, x: -1_300, y: 100, width: 238, height: 330)

        #expect(PanelFrameStore.restore(saved: saved, screens: [left, primary]) == CGRect(x: -1_268, y: 100, width: 238, height: 330))
    }

    @Test func shrinksOversizeFramesToTheInsetVisibleArea() {
        let screen = PanelFrameStore.Screen(
            displayIdentifier: 1,
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
        )
        let saved = PanelFrameRecord(displayIdentifier: 1, x: -100, y: -100, width: 2_000, height: 1_000)

        #expect(PanelFrameStore.restore(saved: saved, screens: [screen]) == CGRect(x: 12, y: 12, width: 976, height: 776))
    }

    @Test func choosesTheNearestScreenWhenTheSavedDisplayIsGone() {
        let left = PanelFrameStore.Screen(
            displayIdentifier: 2,
            visibleFrame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)
        )
        let saved = PanelFrameRecord(displayIdentifier: 99, x: -2_200, y: 100, width: 238, height: 330)

        #expect(PanelFrameStore.restore(saved: saved, screens: [primary, left]) == CGRect(x: -1_908, y: 100, width: 238, height: 330))
    }

    @Test func screenChangeClampsTheCurrentFrameInsteadOfJumpingToPersistedGeometry() {
        let middle = PanelFrameStore.Screen(
            displayIdentifier: 2,
            visibleFrame: CGRect(x: 1_440, y: 0, width: 1_440, height: 900)
        )
        let right = PanelFrameStore.Screen(
            displayIdentifier: 3,
            visibleFrame: CGRect(x: 2_880, y: 0, width: 1_440, height: 900)
        )
        let persistedOldFrame = PanelFrameRecord(displayIdentifier: 1, x: 100, y: 100, width: 238, height: 330)
        let currentFrame = CGRect(x: 3_000, y: 100, width: 238, height: 330)

        #expect(PanelFrameStore.restore(saved: persistedOldFrame, screens: [primary, middle, right]) == CGRect(x: 100, y: 100, width: 238, height: 330))
        #expect(PanelFrameStore.clamp(currentFrame, screens: [primary, middle, right]) == currentFrame)
    }

    @Test func requiresAtLeastATwentyFourPointSquareIntersectionToPreserveAScreenChoice() {
        let thinOverlap = CGRect(x: 1_420, y: 100, width: 238, height: 330)
        let minimumOverlap = CGRect(x: 1_416, y: 100, width: 238, height: 330)

        // A 20×330 seam cannot retain an origin; 24×330 can.
        #expect(!PanelFrameStore.hasMeaningfulIntersection(thinOverlap, primary.visibleFrame))
        #expect(PanelFrameStore.hasMeaningfulIntersection(minimumOverlap, primary.visibleFrame))
    }

    @Test func meaningfulIntersectionRequiresBothDimensionsRatherThanAreaAlone() {
        let frame = CGRect(x: 0, y: 0, width: 600, height: 1)
        let screen = CGRect(x: 0, y: 0, width: 600, height: 800)

        #expect(!PanelFrameStore.hasMeaningfulIntersection(frame, screen))
    }

    @Test func rejectsNonFiniteCoordinatesAndNonpositiveSizes() {
        #expect(PanelFrameStore.restore(saved: .init(displayIdentifier: 1, x: .infinity, y: 0, width: 238, height: 330), screens: [primary]) == nil)
        #expect(PanelFrameStore.restore(saved: .init(displayIdentifier: 1, x: 0, y: 0, width: 0, height: 330), screens: [primary]) == nil)
        #expect(PanelFrameStore.restore(saved: .init(displayIdentifier: 1, x: 0, y: .nan, width: 238, height: 330), screens: [primary]) == nil)
    }

    @Test @MainActor func bridgeRestoresExistingDelegatesWhenItMovesOrDismantles() {
        let suiteName = "PanelWindowBridgeTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let secondWindow = NSWindow(
            contentRect: CGRect(x: 300, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let firstDelegate = WindowDelegateSpy()
        let secondDelegate = WindowDelegateSpy()
        firstWindow.delegate = firstDelegate
        secondWindow.delegate = secondDelegate

        let bridge = PanelWindowBridge(store: PanelFrameStore(preferences: AppPreferences(defaults: defaults)))
        let coordinator = bridge.makeCoordinator()
        coordinator.install(on: firstWindow)
        #expect(firstWindow.delegate === coordinator)

        coordinator.install(on: secondWindow)
        #expect(firstWindow.delegate === firstDelegate)
        #expect(secondWindow.delegate === coordinator)

        coordinator.uninstall()
        #expect(secondWindow.delegate === secondDelegate)

        let staleView = NSView(frame: .zero)
        let staleGeneration = coordinator.activate(view: staleView)
        coordinator.dismantle(view: staleView)
        coordinator.installIfCurrent(on: firstWindow, view: staleView, generation: staleGeneration)
        #expect(firstWindow.delegate === firstDelegate)
    }

    @Test @MainActor func bridgeAtFullOpacityPreservesOriginalVisualProperties() {
        let suiteName = "PanelWindowBridgeVisualTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        firstWindow.isOpaque = true
        firstWindow.backgroundColor = .windowBackgroundColor
        firstWindow.alphaValue = 0.80

        let bridge = PanelWindowBridge(store: PanelFrameStore(preferences: AppPreferences(defaults: defaults)))
        let coordinator = bridge.makeCoordinator()
        coordinator.install(on: firstWindow)

        #expect(firstWindow.isOpaque)
        #expect(firstWindow.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(firstWindow.alphaValue == 0.80)
    }

    @Test @MainActor func bridgeTransitionsItsHostSurfaceWithoutOverwritingCapturedOriginals() {
        let suiteName = "PanelWindowBridgeVisualTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.alphaValue = 0.80

        let bridge = PanelWindowBridge(store: PanelFrameStore(preferences: AppPreferences(defaults: defaults)))
        let coordinator = bridge.makeCoordinator()
        coordinator.install(on: window)
        coordinator.setPanelOpacity(0.95)

        #expect(window.isOpaque)
        #expect(window.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(window.alphaValue == 0.95)

        coordinator.setPanelOpacity(1.00)
        #expect(window.isOpaque)
        #expect(window.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(window.alphaValue == 0.80)

        coordinator.setPanelOpacity(0.95)
        coordinator.setPanelOpacity(1.00)
        #expect(window.isOpaque)
        #expect(window.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(window.alphaValue == 0.80)
    }

    @Test @MainActor func bridgeRestoresVisualPropertiesWhenItMovesUninstallsOrDismantles() {
        let suiteName = "PanelWindowBridgeVisualTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("Could not create isolated defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let firstWindow = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        firstWindow.isOpaque = true
        firstWindow.backgroundColor = .windowBackgroundColor
        firstWindow.alphaValue = 0.80

        let secondWindow = NSWindow(
            contentRect: CGRect(x: 300, y: 0, width: 238, height: 330),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        secondWindow.isOpaque = false
        secondWindow.backgroundColor = .systemRed
        secondWindow.alphaValue = 0.70

        let bridge = PanelWindowBridge(store: PanelFrameStore(preferences: AppPreferences(defaults: defaults)), panelOpacity: 0.95)
        let coordinator = bridge.makeCoordinator()
        coordinator.install(on: firstWindow)
        coordinator.install(on: secondWindow)

        #expect(firstWindow.isOpaque)
        #expect(firstWindow.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(firstWindow.alphaValue == 0.80)
        #expect(!secondWindow.isOpaque)
        #expect(secondWindow.backgroundColor?.isEqual(NSColor.systemRed) == true)
        #expect(secondWindow.alphaValue == 0.95)

        coordinator.uninstall()

        #expect(!secondWindow.isOpaque)
        #expect(secondWindow.backgroundColor?.isEqual(NSColor.systemRed) == true)
        #expect(secondWindow.alphaValue == 0.70)

        let view = NSView(frame: .zero)
        let generation = coordinator.activate(view: view)
        coordinator.installIfCurrent(on: firstWindow, view: view, generation: generation)
        coordinator.setPanelOpacity(0.95)
        coordinator.dismantle(view: view)
        #expect(firstWindow.isOpaque)
        #expect(firstWindow.backgroundColor?.isEqual(NSColor.windowBackgroundColor) == true)
        #expect(firstWindow.alphaValue == 0.80)
    }

}

@MainActor
private final class WindowDelegateSpy: NSObject, NSWindowDelegate {}
