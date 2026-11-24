import AgentWearLinkOpenClaw
import Foundation

/// Maps a failed Gateway connect to the hop it most likely broke. Raw
/// errors are never shown or logged; only this category is.
public enum GatewayFailure: String, Equatable, Sendable {
    /// No route to the host (Tailscale off, host asleep, no internet).
    case networkUnreachable
    /// The host answered but the Gateway refused or failed.
    case gatewayUnreachable
    /// The device is waiting for approval on the Gateway host.
    case pairingPending
    /// The stored approval was rejected or is missing: approve again.
    case pairingRevoked

    private static let authCodes: Set<String> = [
        "AUTH_FAILED", "DEVICE_TOKEN_REJECTED", "UNAUTHORIZED", "FORBIDDEN",
    ]

    private static let networkCodes: Set<URLError.Code> = [
        .cannotFindHost, .cannotConnectToHost, .notConnectedToInternet,
        .timedOut, .networkConnectionLost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
    ]

    public static func classify(_ error: Error, usedStoredGrant: Bool) -> GatewayFailure {
        switch error {
        case OpenClawHandshakeError.pairingRequired:
            return .pairingPending
        case let AWLOpenClawError.gateway(code, _, _):
            if code == "PAIRING_REQUIRED" { return .pairingPending }
            if authCodes.contains(code) { return usedStoredGrant ? .pairingRevoked : .gatewayUnreachable }
            return .gatewayUnreachable
        case OpenClawHandshakeError.challengeTimeout:
            // The socket opened nothing that spoke the Gateway protocol in time.
            return .networkUnreachable
        case let urlError as URLError:
            return networkCodes.contains(urlError.code) ? .networkUnreachable : .gatewayUnreachable
        default:
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               networkCodes.contains(URLError.Code(rawValue: nsError.code)) {
                return .networkUnreachable
            }
            if nsError.domain == NSPOSIXErrorDomain { return .networkUnreachable }
            return .gatewayUnreachable
        }
    }

    /// The signals this failure implies for the network and gateway hops.
    public func apply(to signals: inout ConnectionSignals, at date: Date) {
        switch self {
        case .networkUnreachable:
            signals.network = .unreachable
            signals.gateway = .unknown
        case .gatewayUnreachable:
            signals.network = .reachable
            signals.gateway = .unreachable
        case .pairingPending:
            signals.network = .reachable
            signals.gateway = .pairingPending
        case .pairingRevoked:
            signals.network = .reachable
            signals.gateway = .pairingRevoked
        }
        signals.checkedAt[.network] = date
        signals.checkedAt[.gateway] = date
    }
}
