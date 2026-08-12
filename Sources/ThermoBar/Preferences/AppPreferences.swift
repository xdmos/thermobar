import Foundation

struct PanelFrameRecord: Codable, Equatable, Sendable {
    let displayIdentifier: UInt32
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

@MainActor
final class AppPreferences {
    private enum Key {
        static let panelVisible = "thermobar.panelVisible"
        static let panelOpacity = "thermobar.panelOpacity"
        static let launchAtLogin = "thermobar.launchAtLogin"
        static let thermalNotifications = "thermobar.thermalNotifications"
        static let panelFrame = "thermobar.panelFrame"
    }

    private let defaults: UserDefaults
    private let panelOpacityRange: ClosedRange<Double> = 0.30...1.00
    private let defaultPanelOpacity = 1.00

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var panelVisible: Bool {
        get { defaults.object(forKey: Key.panelVisible) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.panelVisible) }
    }

    var panelOpacity: Double {
        get {
            guard let value = defaults.object(forKey: Key.panelOpacity) as? Double,
                  value.isFinite,
                  panelOpacityRange.contains(value) else {
                return defaultPanelOpacity
            }
            return value
        }
        set {
            let value = newValue.isFinite ? min(max(newValue, panelOpacityRange.lowerBound), panelOpacityRange.upperBound) : defaultPanelOpacity
            defaults.set(value, forKey: Key.panelOpacity)
        }
    }

    var launchAtLogin: Bool {
        get { defaults.object(forKey: Key.launchAtLogin) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.launchAtLogin) }
    }

    var thermalNotifications: Bool {
        get { defaults.object(forKey: Key.thermalNotifications) as? Bool ?? false }
        set { defaults.set(newValue, forKey: Key.thermalNotifications) }
    }

    var panelFrame: PanelFrameRecord? {
        get {
            guard let data = defaults.data(forKey: Key.panelFrame) else { return nil }
            return try? JSONDecoder().decode(PanelFrameRecord.self, from: data)
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.panelFrame)
                return
            }
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Key.panelFrame)
        }
    }
}
