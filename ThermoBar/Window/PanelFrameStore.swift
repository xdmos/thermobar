import AppKit
import Foundation

@MainActor
final class PanelFrameStore {
    struct Screen: Equatable {
        let displayIdentifier: UInt32
        let visibleFrame: CGRect
    }

    /// A 24-by-24 point overlap is large enough to identify a real retained screen,
    /// while ignoring thin one-pixel seams created by changed display arrangements.
    nonisolated static let meaningfulIntersectionDimension: CGFloat = 24
    nonisolated static let inset: CGFloat = 12

    private let preferences: AppPreferences

    init(preferences: AppPreferences = .init()) {
        self.preferences = preferences
    }

    func restoreFrame(screens: [NSScreen] = NSScreen.screens) -> CGRect? {
        guard let saved = preferences.panelFrame else { return nil }
        return Self.restore(saved: saved, screens: Self.screens(from: screens))
    }

    func restoreFrame(currentSize: CGSize, screens: [NSScreen] = NSScreen.screens) -> CGRect? {
        guard let saved = preferences.panelFrame else { return nil }
        return Self.restore(saved: saved, currentSize: currentSize, screens: Self.screens(from: screens))
    }

    func save(frame: CGRect, on screen: NSScreen?) {
        guard let screen, Self.isValid(frame) else { return }
        let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let identifier else { return }
        preferences.panelFrame = PanelFrameRecord(
            displayIdentifier: identifier,
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.width,
            height: frame.height
        )
    }

    nonisolated static func restore(saved: PanelFrameRecord, screens: [Screen]) -> CGRect? {
        restore(saved: saved, currentSize: CGSize(width: saved.width, height: saved.height), screens: screens)
    }

    /// Restores the saved display and origin while allowing current SwiftUI
    /// content to replace a stale persisted size from an older app version.
    nonisolated static func restore(saved: PanelFrameRecord, currentSize: CGSize, screens: [Screen]) -> CGRect? {
        let savedFrame = CGRect(x: saved.x, y: saved.y, width: saved.width, height: saved.height)
        let currentFrame = CGRect(origin: savedFrame.origin, size: currentSize)
        guard isValid(savedFrame), isValid(currentFrame) else { return nil }

        let validScreens = screens.filter { isValid($0.visibleFrame) }
        guard !validScreens.isEmpty else { return nil }

        let target: Screen
        if let savedScreen = validScreens.first(where: { $0.displayIdentifier == saved.displayIdentifier }),
           hasMeaningfulIntersection(savedFrame, savedScreen.visibleFrame) {
            target = savedScreen
        } else {
            target = targetScreen(for: savedFrame, screens: validScreens)
        }

        return clamped(currentFrame, to: target.visibleFrame)
    }

    /// Re-clamps a currently displayed window after a screen topology change.
    /// It deliberately ignores the persisted record, which is only for first restore.
    nonisolated static func clamp(_ frame: CGRect, screens: [Screen]) -> CGRect? {
        guard isValid(frame) else { return nil }
        let validScreens = screens.filter { isValid($0.visibleFrame) }
        guard !validScreens.isEmpty else { return nil }
        return clamped(frame, to: targetScreen(for: frame, screens: validScreens).visibleFrame)
    }

    nonisolated static func hasMeaningfulIntersection(_ frame: CGRect, _ visibleFrame: CGRect) -> Bool {
        let intersection = frame.intersection(visibleFrame)
        return !intersection.isNull
            && intersection.width >= meaningfulIntersectionDimension
            && intersection.height >= meaningfulIntersectionDimension
    }

    nonisolated private static func clamped(_ frame: CGRect, to visibleFrame: CGRect) -> CGRect {
        let horizontalInset = min(inset, visibleFrame.width / 2)
        let verticalInset = min(inset, visibleFrame.height / 2)
        let insetFrame = visibleFrame.insetBy(dx: horizontalInset, dy: verticalInset)
        let availableWidth = insetFrame.width
        let availableHeight = insetFrame.height
        let width = min(frame.width, availableWidth)
        let height = min(frame.height, availableHeight)
        let minX = insetFrame.minX
        let minY = insetFrame.minY
        let maxX = insetFrame.maxX - width
        let maxY = insetFrame.maxY - height

        return CGRect(
            x: min(max(frame.minX, minX), maxX),
            y: min(max(frame.minY, minY), maxY),
            width: width,
            height: height
        )
    }

    nonisolated private static func targetScreen(for frame: CGRect, screens: [Screen]) -> Screen {
        if let intersectingScreen = screens
            .filter({ hasMeaningfulIntersection(frame, $0.visibleFrame) })
            .max(by: { intersectionArea(frame, $0.visibleFrame) < intersectionArea(frame, $1.visibleFrame) }) {
            return intersectingScreen
        }
        return screens.min(by: { distanceSquared(from: frame, to: $0.visibleFrame) < distanceSquared(from: frame, to: $1.visibleFrame) })!
    }

    private static func screens(from screens: [NSScreen]) -> [Screen] {
        screens.compactMap { screen in
            guard let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
                return nil
            }
            return Screen(displayIdentifier: identifier, visibleFrame: screen.visibleFrame)
        }
    }

    nonisolated private static func isValid(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    nonisolated private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    nonisolated private static func distanceSquared(from frame: CGRect, to visibleFrame: CGRect) -> CGFloat {
        let deltaX: CGFloat
        if frame.maxX < visibleFrame.minX {
            deltaX = visibleFrame.minX - frame.maxX
        } else if frame.minX > visibleFrame.maxX {
            deltaX = frame.minX - visibleFrame.maxX
        } else {
            deltaX = 0
        }

        let deltaY: CGFloat
        if frame.maxY < visibleFrame.minY {
            deltaY = visibleFrame.minY - frame.maxY
        } else if frame.minY > visibleFrame.maxY {
            deltaY = frame.minY - visibleFrame.maxY
        } else {
            deltaY = 0
        }
        return deltaX * deltaX + deltaY * deltaY
    }
}
