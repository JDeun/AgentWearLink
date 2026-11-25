import Foundation

enum LabDriverStage: Equatable {
    case idle, centralInit, scanning, confirmFixture, connecting, service, marker, markerRead, opening
    case serverInit, publishing, adding, advertising, listening, confirmIncoming
    case transfer, draining, finished

    var acceptsCentralDisconnect: Bool {
        switch self {
        case .connecting, .service, .marker, .markerRead, .opening, .transfer, .draining: return true
        default: return false
        }
    }
}

enum LabDriverTick: Equatable {
    case proceed, ignored, confirmFixture, terminate(String)
}

/// Pure main-owner lifecycle; actual BLE object identities are fenced by the
/// adapter before invoking this policy. No radio commands or simulated hardware evidence.
struct LabDriverLifecycle {
    private(set) var stage: LabDriverStage = .idle
    private(set) var generation: UUID?
    private(set) var deadline: UInt64?
    private var lastNow: UInt64 = 0
    private var pendingServerOperation: LabDriverStage?

    private static func limit(_ now: UInt64, _ delta: UInt64) -> UInt64 {
        let (sum, overflow) = now.addingReportingOverflow(delta)
        return overflow ? UInt64.max : sum
    }

    mutating func begin(generation token: UUID, stage initial: LabDriverStage, nowMS: UInt64) -> Bool {
        guard generation == nil, initial == .centralInit || initial == .serverInit else { return false }
        generation = token
        stage = initial
        lastNow = nowMS
        pendingServerOperation = nil
        deadline = Self.limit(nowMS, 15_000)
        return true
    }

    /// Does not permit scan completion via callbacks: only the timer tick
    /// can reach confirmFixture. Check deadlines before processing callbacks.
    mutating func move(generation token: UUID, to target: LabDriverStage, nowMS: UInt64) -> Bool {
        guard generation == token, nowMS >= lastNow else { return false }
        guard deadline.map({ nowMS < $0 }) ?? true else { return false }
        switch (stage, target) {
        case (.centralInit, .scanning):
            deadline = min(deadline ?? nowMS, Self.limit(nowMS, 5_000))
        case (.confirmFixture, .connecting), (.listening, .confirmIncoming):
            deadline = nil
        case (.connecting, .service), (.service, .marker), (.marker, .markerRead),
             (.markerRead, .opening), (.opening, .transfer), (.confirmIncoming, .transfer):
            break
        case (.serverInit, .publishing), (.publishing, .adding), (.adding, .advertising):
            break
        case (.advertising, .listening):
            deadline = Self.limit(nowMS, 90_000)
        case (.transfer, .draining):
            deadline = Self.limit(nowMS, 2_000)
        default:
            return false
        }
        stage = target
        switch target {
        case .publishing, .adding, .advertising: pendingServerOperation = target
        default: pendingServerOperation = nil
        }
        lastNow = nowMS
        return true
    }

    mutating func tick(generation token: UUID, nowMS: UInt64, hasCandidate: Bool) -> LabDriverTick {
        guard generation == token else { return .ignored }
        guard nowMS >= lastNow else { return .terminate("clockRegression") }
        lastNow = nowMS
        guard let deadline, nowMS >= deadline else { return .proceed }
        switch stage {
        case .scanning:
            guard hasCandidate else { return .terminate("no-fixture") }
            stage = .confirmFixture
            self.deadline = Self.limit(nowMS, 30_000)
            return .confirmFixture
        case .draining:
            return .terminate("responder-drain-deadline")
        default:
            return .terminate("setup-timeout")
        }
    }

    /// Mark delivery before processing an accepted server callback. If its
    /// deadline crosses while handling the result, cleanup must not treat
    /// this operation as pending again, even if stage has not advanced.
    mutating func acknowledgeServerOperation(generation token: UUID, stage expected: LabDriverStage) -> Bool {
        guard generation == token, stage == expected, pendingServerOperation == expected else { return false }
        pendingServerOperation = nil
        return true
    }

    mutating func retire(generation token: UUID) -> LabRetiredCallbacks? {
        guard generation == token else { return nil }
        let callbacks = LabRetiredCallbacks(stage: pendingServerOperation)
        pendingServerOperation = nil
        generation = nil
        stage = .finished
        deadline = nil
        return callbacks
    }
}

/// Which single server operation may still complete after cancellation.
/// Object identity, success and manager availability remain adapter checks.
/// Does not claim cleanup happened. All requests are owned by the retired run.
struct LabRetiredCallbacks {
    private var pending: LabDriverStage?

    init(stage: LabDriverStage? = nil) {
        switch stage {
        case .publishing, .adding, .advertising: pending = stage
        default: pending = nil
        }
    }

    func isPending(_ stage: LabDriverStage) -> Bool { pending == stage }

    mutating func consume(_ stage: LabDriverStage) -> Bool {
        guard pending == stage else { return false }
        pending = nil
        return true
    }
}
