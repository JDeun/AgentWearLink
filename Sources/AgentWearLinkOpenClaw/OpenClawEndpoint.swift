import Foundation

public struct OpenClawEndpoint: Sendable, Equatable {
    public enum Exposure: Sendable, Equatable {
        case loopback
        case tailnetDirect
        case tailnetServe
        case privateReverseProxy
    }

    public let gatewayURL: URL
    public let exposure: Exposure

    public init(gatewayURL: URL, exposure: Exposure) throws {
        guard let scheme = gatewayURL.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme) else {
            throw OpenClawEndpointError.unsupportedScheme
        }

        switch exposure {
        case .tailnetServe, .privateReverseProxy:
            guard scheme == "wss" || scheme == "https" else {
                throw OpenClawEndpointError.secureTransportRequired
            }
        case .loopback, .tailnetDirect:
            break
        }

        self.gatewayURL = gatewayURL
        self.exposure = exposure
    }

    public static func tailnetServe(hostname: String) throws -> Self {
        guard !hostname.isEmpty, !hostname.contains("/") else {
            throw OpenClawEndpointError.invalidHostname
        }
        guard let url = URL(string: "wss://\(hostname)") else {
            throw OpenClawEndpointError.invalidHostname
        }
        return try .init(gatewayURL: url, exposure: .tailnetServe)
    }
}

public enum OpenClawEndpointError: Error, Sendable, Equatable {
    case unsupportedScheme
    case secureTransportRequired
    case invalidHostname
}
