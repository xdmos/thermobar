import Foundation

public struct SamplingSnapshot: Equatable, Sendable {
    public let value: SystemSnapshot
    public let transitionID: UUID
    public init(value: SystemSnapshot, transitionID: UUID) { self.value = value; self.transitionID = transitionID }
}
public struct ThermalSample: Equatable, Sendable {
    public let level: ThermalLevel
    public let monotonicNanoseconds: UInt64
    public init(level: ThermalLevel, monotonicNanoseconds: UInt64) { self.level = level; self.monotonicNanoseconds = monotonicNanoseconds }
}
public struct SamplingTransitionReceipt: Equatable, Sendable {
    public let requestedTransitionID: UUID
    public let currentTransitionID: UUID
    public let currentMode: SamplingMode
    public let isCurrent: Bool
    public init(requestedTransitionID: UUID, currentTransitionID: UUID, currentMode: SamplingMode, isCurrent: Bool) { self.requestedTransitionID = requestedTransitionID; self.currentTransitionID = currentTransitionID; self.currentMode = currentMode; self.isCurrent = isCurrent }
}
