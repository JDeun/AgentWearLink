import Foundation

/// The one-time setup flow. After `finished` the app never asks again.
public enum SetupStep: Int, CaseIterable, Sendable, Comparable, Identifiable {
    case metaRegistration
    case microphone
    case tailscale
    case gateway
    case practice

    public var id: Int { rawValue }
    public var number: Int { rawValue + 1 }

    public static func < (lhs: SetupStep, rhs: SetupStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Tailscale guidance is informational and the call practice is optional;
    /// the rest are required for a working connection.
    public var isSkippable: Bool {
        self == .tailscale || self == .practice
    }
}

public struct SetupProgress: Equatable, Sendable {
    public private(set) var completed: Set<SetupStep> = []

    public init(completed: Set<SetupStep> = []) {
        self.completed = completed
    }

    /// The first step not done yet, or nil when setup is finished.
    public var current: SetupStep? {
        SetupStep.allCases.first { !completed.contains($0) }
    }

    public var isFinished: Bool { current == nil }

    /// Steps completed in order, for "처음 한 번만 · 4/5단계".
    public var position: Int { (current ?? .practice).number }

    public enum StepState: Equatable, Sendable { case done, current, upcoming }

    public func state(of step: SetupStep) -> StepState {
        if completed.contains(step) { return .done }
        return step == current ? .current : .upcoming
    }

    public mutating func complete(_ step: SetupStep) {
        completed.insert(step)
    }

    /// Skipping is only allowed for informational/optional steps.
    @discardableResult
    public mutating func skip(_ step: SetupStep) -> Bool {
        guard step.isSkippable else { return false }
        completed.insert(step)
        return true
    }

    /// "맥미니 승인만 다시 받기": go back to the Gateway step only.
    public mutating func restartGatewayApproval() {
        completed.remove(.gateway)
        completed.remove(.practice)
    }
}
