import Testing
@testable import ThermoBarCore

@Test func alertMatrixCoversEveryThermalLevelPair() {
    let expectations: [(ThermalLevel, ThermalLevel, ThermalAlert?)] = [
        (.nominal, .nominal, nil), (.nominal, .fair, nil), (.nominal, .serious, .init(severity: .serious)), (.nominal, .critical, .init(severity: .critical)),
        (.fair, .nominal, nil), (.fair, .fair, nil), (.fair, .serious, .init(severity: .serious)), (.fair, .critical, .init(severity: .critical)),
        (.serious, .nominal, nil), (.serious, .fair, nil), (.serious, .serious, nil), (.serious, .critical, .init(severity: .critical)),
        (.critical, .nominal, nil), (.critical, .fair, nil), (.critical, .serious, nil), (.critical, .critical, nil)
    ]

    for (old, new, expected) in expectations {
        var machine = ThermalAlertMachine()
        machine.establishBaseline(old)
        #expect(machine.consume(new) == expected, "\\(old) -> \\(new)")
    }
}

@Test func repeatedHotStateDoesNotRepeatAnAlert() {
    var machine = ThermalAlertMachine()
    machine.establishBaseline(.nominal)
    #expect(machine.consume(.serious) == .init(severity: .serious))
    #expect(machine.consume(.serious) == nil)
    #expect(machine.consume(.critical) == .init(severity: .critical))
    #expect(machine.consume(.critical) == nil)
}

@Test func firstConsumedStateOnlyEstablishesABaseline() {
    var machine = ThermalAlertMachine()
    #expect(machine.consume(.critical) == nil)
    #expect(machine.consume(.critical) == nil)
}

@Test func explicitHotBaselineNeverCreatesARetroactiveAlert() {
    var machine = ThermalAlertMachine()
    machine.establishBaseline(.serious)
    #expect(machine.consume(.serious) == nil)
    machine.establishBaseline(.critical)
    #expect(machine.consume(.critical) == nil)
}

@Test func retainingMachineAcrossSleepSuppressesSameHotStateButEscalatesOnce() {
    var machine = ThermalAlertMachine()
    machine.establishBaseline(.serious)
    #expect(machine.consume(.serious) == nil)
    #expect(machine.consume(.critical) == .init(severity: .critical))
    #expect(machine.consume(.critical) == nil)
}

@Test func nominalOrFairStartsANewHotEpisode() {
    var machine = ThermalAlertMachine()
    machine.establishBaseline(.nominal)
    #expect(machine.consume(.serious) == .init(severity: .serious))
    #expect(machine.consume(.fair) == nil)
    #expect(machine.consume(.serious) == .init(severity: .serious))
}

@Test func resetClearsBaselineUntilItIsExplicitlyEstablishedAgain() {
    var machine = ThermalAlertMachine()
    machine.establishBaseline(.serious)
    machine.resetBaseline()
    #expect(machine.consume(.serious) == nil)
    machine.establishBaseline(.critical)
    #expect(machine.consume(.critical) == nil)
}
