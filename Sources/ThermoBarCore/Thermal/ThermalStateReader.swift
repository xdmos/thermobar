import Foundation

public struct ThermalStateReader: Sendable {
    public init() {}

    public func read() -> ThermalLevel {
        Self.thermalLevel(for: ProcessInfo.processInfo.thermalState)
    }

    static func thermalLevel(for thermalState: ProcessInfo.ThermalState) -> ThermalLevel {
        switch thermalState {
        case .nominal:
            .nominal
        case .fair:
            .fair
        case .serious:
            .serious
        case .critical:
            .critical
        @unknown default:
            .critical
        }
    }
}
