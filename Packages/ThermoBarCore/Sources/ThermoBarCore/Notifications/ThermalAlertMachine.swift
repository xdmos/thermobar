public struct ThermalAlert: Equatable, Sendable {
    public enum Severity: Equatable, Sendable {
        case serious
        case critical
    }

    public let severity: Severity

    public init(severity: Severity) {
        self.severity = severity
    }
}

public struct ThermalAlertMachine: Sendable {
    private var baseline: ThermalLevel?

    public init() {}

    public mutating func establishBaseline(_ thermalLevel: ThermalLevel) {
        baseline = thermalLevel
    }

    public mutating func resetBaseline() {
        baseline = nil
    }

    public mutating func consume(_ thermalLevel: ThermalLevel) -> ThermalAlert? {
        guard let previous = baseline else {
            baseline = thermalLevel
            return nil
        }
        baseline = thermalLevel

        switch (previous, thermalLevel) {
        case (.nominal, .serious), (.fair, .serious):
            return ThermalAlert(severity: .serious)
        case (.nominal, .critical), (.fair, .critical), (.serious, .critical):
            return ThermalAlert(severity: .critical)
        default:
            return nil
        }
    }
}
