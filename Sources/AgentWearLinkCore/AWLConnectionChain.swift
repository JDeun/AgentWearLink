import Foundation

/// The five hops between the wearer's voice and the agent, in signal order.
public enum AWLChainLinkID: Int, CaseIterable, Sendable, Comparable {
    case glasses   // wearable via Meta DAT
    case phone     // this iPhone app (alive, permissions)
    case network   // private route to the gateway host (e.g. Tailscale)
    case gateway   // OpenClaw gateway (this device paired)
    case agent     // the agent answering turns

    public static func < (lhs: AWLChainLinkID, rhs: AWLChainLinkID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Why a link is broken. Each has exactly one repair action.
public enum AWLChainProblemReason: String, CaseIterable, Sendable {
    case glassesNotConnected
    case glassesBatteryCritical
    case glassesUpdateRequired
    case metaRegistrationMissing
    case microphoneDenied
    case appNotRunning
    case networkUnreachable
    case gatewayUnreachable
    case pairingPending
    case pairingRevoked
    case agentNotResponding
}

public enum AWLChainLinkStatus: Equatable, Sendable {
    case ok
    case broken(AWLChainProblemReason)
    /// Not observed, or not observable because an earlier link is broken.
    case unknown
}

public enum AWLChainRepairAction: Equatable, Sendable {
    case reconnectGlasses
    case chargeGlasses
    case openMetaAIApp
    case openAppSettings
    case reopenApp
    case recheck
    case retryGateway
    case waitForApproval
    case runSetupAgain
    case sendTestTurn

    public static func `for`(_ reason: AWLChainProblemReason) -> AWLChainRepairAction? {
        switch reason {
        case .glassesNotConnected: .reconnectGlasses
        case .glassesBatteryCritical: .chargeGlasses
        case .glassesUpdateRequired: .openMetaAIApp
        case .metaRegistrationMissing: .openMetaAIApp
        case .microphoneDenied: .openAppSettings
        case .appNotRunning: .reopenApp
        case .networkUnreachable: .recheck
        case .gatewayUnreachable: .retryGateway
        case .pairingPending: .waitForApproval
        case .pairingRevoked: .runSetupAgain
        case .agentNotResponding: .sendTestTurn
        }
    }
}

public struct AWLChainLink: Equatable, Sendable {
    public let id: AWLChainLinkID
    public let status: AWLChainLinkStatus
}

public struct AWLChainProblem: Equatable, Sendable {
    public let link: AWLChainLinkID
    public let reason: AWLChainProblemReason
    public var repair: AWLChainRepairAction? { AWLChainRepairAction.for(reason) }
}

public enum AWLChainSummary: Equatable, Sendable {
    case allConnected
    case problem(AWLChainLinkID, AWLChainProblemReason)
    case checking
}

/// Derives what the app may honestly claim from raw per-link observations:
/// anything past the first broken hop is shown as unknown, never as ok.
public struct AWLConnectionChain: Equatable, Sendable {
    public let links: [AWLChainLink]

    public init(observations: [AWLChainLinkID: AWLChainLinkStatus]) {
        var upstreamBroken = false
        links = AWLChainLinkID.allCases.map { id in
            if upstreamBroken { return AWLChainLink(id: id, status: .unknown) }
            let status = observations[id] ?? .unknown
            if case .broken = status { upstreamBroken = true }
            return AWLChainLink(id: id, status: status)
        }
    }

    public func status(of id: AWLChainLinkID) -> AWLChainLinkStatus {
        links.first { $0.id == id }?.status ?? .unknown
    }

    public var firstProblem: AWLChainProblem? {
        for link in links {
            if case let .broken(reason) = link.status {
                return AWLChainProblem(link: link.id, reason: reason)
            }
        }
        return nil
    }

    public var summary: AWLChainSummary {
        if let problem = firstProblem { return .problem(problem.link, problem.reason) }
        return links.allSatisfy { $0.status == .ok } ? .allConnected : .checking
    }
}
