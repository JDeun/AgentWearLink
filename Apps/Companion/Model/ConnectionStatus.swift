import AgentWearLinkCore
import Foundation

/// Raw, honest observations from the live app. Anything not observed stays
/// `.unknown`; the mapping never upgrades unknown to ok.
public struct ConnectionSignals: Equatable, Sendable {
    public enum Glasses: Equatable, Sendable {
        case unknown
        /// Meta registration is missing (or this build is not provisioned).
        case registrationRequired
        /// Folded, in the case, charging or out of range: a normal state.
        case waiting
        case connecting
        case connected
        case updateRequired
    }

    public enum Permission: Equatable, Sendable { case unknown, granted, denied }
    public enum Reachability: Equatable, Sendable { case unknown, reachable, unreachable }
    public enum Gateway: Equatable, Sendable {
        case unknown, ok, unreachable, pairingPending, pairingRevoked
    }

    public var glasses: Glasses = .unknown
    public var glassesBattery: Int?
    public var glassesCharging = false
    public var microphone: Permission = .unknown
    public var listenEnabled = true
    /// The voice runtime is running (DAT listener + Gateway session).
    public var listening = false
    public var network: Reachability = .unknown
    public var gateway: Gateway = .unknown
    public var agentFailing = false
    public var lastReplyAt: Date?
    public var lastReplyLatency: TimeInterval?
    /// When each hop was last observed.
    public var checkedAt: [AWLChainLinkID: Date] = [:]

    public init() {}

    static let criticalBattery = 5

    /// Per-hop observations for `AWLConnectionChain`.
    public var observations: [AWLChainLinkID: AWLChainLinkStatus] {
        var result: [AWLChainLinkID: AWLChainLinkStatus] = [:]
        switch glasses {
        case .registrationRequired: result[.glasses] = .broken(.metaRegistrationMissing)
        case .updateRequired: result[.glasses] = .broken(.glassesUpdateRequired)
        case .connected:
            if let battery = glassesBattery, battery <= Self.criticalBattery, !glassesCharging {
                result[.glasses] = .broken(.glassesBatteryCritical)
            } else {
                result[.glasses] = .ok
            }
        // Waiting is not an error and not a claim of health: the hop stays
        // unobserved so the rest of the chain can still be checked.
        case .waiting, .connecting, .unknown: break
        }

        if microphone == .denied {
            result[.phone] = .broken(.microphoneDenied)
        } else {
            // This code runs, so the app is alive on this iPhone.
            result[.phone] = .ok
        }

        switch network {
        case .reachable: result[.network] = .ok
        case .unreachable: result[.network] = .broken(.networkUnreachable)
        case .unknown: break
        }

        switch gateway {
        case .ok: result[.gateway] = .ok
        case .unreachable: result[.gateway] = .broken(.gatewayUnreachable)
        case .pairingPending: result[.gateway] = .broken(.pairingPending)
        case .pairingRevoked: result[.gateway] = .broken(.pairingRevoked)
        case .unknown: break
        }

        if agentFailing {
            result[.agent] = .broken(.agentNotResponding)
        } else if lastReplyAt != nil, gateway == .ok {
            result[.agent] = .ok
        }
        return result
    }

    public var chain: AWLConnectionChain {
        AWLConnectionChain(observations: observations)
    }
}

/// What Home shows. Pure, so every state is unit-tested.
public struct HomeViewState: Equatable, Sendable {
    public enum Banner: Equatable, Sendable {
        case allConnected(checkedAt: Date?)
        /// "안경 대기 중 · 쓰면 자동 연결": NOT an error.
        case waitingForGlasses
        case listeningOff
        case problem(AWLChainProblem)
        case checking
    }

    public enum RowState: Equatable, Sendable {
        case ok
        case problem(AWLChainProblemReason)
        case waiting
        /// Not observed yet.
        case checking
        /// Cannot be observed because an earlier hop is broken.
        case notCheckable
    }

    public struct Row: Equatable, Sendable, Identifiable {
        public let id: AWLChainLinkID
        public let state: RowState
        public let checkedAt: Date?
    }

    public let banner: Banner
    public let rows: [Row]
    /// Only offered when Telegram delivery is configured.
    public let showsTelegramLink: Bool

    public init(signals: ConnectionSignals, telegramConfigured: Bool) {
        let chain = signals.chain
        var upstreamBroken = false
        rows = chain.links.map { link in
            let state: RowState
            switch link.status {
            case .ok: state = .ok
            case let .broken(reason): state = .problem(reason)
            case .unknown:
                if upstreamBroken {
                    state = .notCheckable
                } else if link.id == .glasses, signals.glasses == .waiting {
                    state = .waiting
                } else {
                    state = .checking
                }
            }
            if case .broken = link.status { upstreamBroken = true }
            return Row(id: link.id, state: state, checkedAt: signals.checkedAt[link.id])
        }

        let throughGateway = rows.filter { $0.id <= .gateway && $0.id != .glasses }
        if let problem = chain.firstProblem {
            banner = .problem(problem)
        } else if !signals.listenEnabled {
            banner = .listeningOff
        } else if signals.glasses == .waiting,
                  throughGateway.allSatisfy({ $0.state == .ok || $0.state == .checking }) {
            banner = .waitingForGlasses
        } else if rows.filter({ $0.id <= .gateway }).allSatisfy({ $0.state == .ok }) {
            let times = rows.filter { $0.id <= .gateway }.compactMap(\.checkedAt)
            banner = .allConnected(checkedAt: times.min())
        } else {
            banner = .checking
        }
        showsTelegramLink = telegramConfigured
    }
}

/// Likely causes shown on the Repair screen, most likely first.
public enum RepairCause: String, CaseIterable, Sendable {
    case glassesOffOrInCase
    case glassesOutOfRange
    case glassesBatteryLow
    case glassesFirmwareOld
    case metaAppNotRegistered
    case microphoneNotAllowed
    case tailscaleOff
    case hostAsleep
    case weakInternet
    case gatewayStopped
    case approvalPending
    case approvalRevoked
    case agentBusy
}

public struct RepairGuide: Equatable, Sendable {
    public let link: AWLChainLinkID
    public let reason: AWLChainProblemReason
    public let causes: [RepairCause]
    public let action: AWLChainRepairAction?
    /// The app cannot detect or open Tailscale; it can only suggest VPN On Demand.
    public let showsTailscaleOnDemandHint: Bool

    public init(problem: AWLChainProblem) {
        link = problem.link
        reason = problem.reason
        action = problem.repair
        showsTailscaleOnDemandHint = problem.reason == .networkUnreachable
        switch problem.reason {
        case .glassesNotConnected: causes = [.glassesOffOrInCase, .glassesOutOfRange]
        case .glassesBatteryCritical: causes = [.glassesBatteryLow]
        case .glassesUpdateRequired: causes = [.glassesFirmwareOld]
        case .metaRegistrationMissing: causes = [.metaAppNotRegistered]
        case .microphoneDenied: causes = [.microphoneNotAllowed]
        case .appNotRunning: causes = []
        case .networkUnreachable: causes = [.tailscaleOff, .hostAsleep, .weakInternet]
        case .gatewayUnreachable: causes = [.gatewayStopped, .hostAsleep]
        case .pairingPending: causes = [.approvalPending]
        case .pairingRevoked: causes = [.approvalRevoked]
        case .agentNotResponding: causes = [.agentBusy, .gatewayStopped]
        }
    }
}
