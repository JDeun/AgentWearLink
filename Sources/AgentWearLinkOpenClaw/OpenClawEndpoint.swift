import Foundation

public struct OpenClawEndpoint: Sendable, Equatable {
    public enum Exposure: String, Sendable, Equatable, CaseIterable {
        case loopback
        case tailnetDirect = "tailnet-direct"
        case tailnetServe = "tailnet-serve"
        case privateReverseProxy = "private-reverse-proxy"
    }

    public let gatewayURL: URL
    public let exposure: Exposure

    public init(gatewayURL: URL, exposure: Exposure) throws {
        guard let scheme = gatewayURL.scheme?.lowercased(),
              ["ws", "wss", "http", "https"].contains(scheme) else {
            throw OpenClawEndpointError.unsupportedScheme
        }
        guard let host = gatewayURL.host, !host.isEmpty else {
            throw OpenClawEndpointError.invalidHostname
        }

        switch exposure {
        case .loopback:
            guard Self.isLoopbackHost(host) else {
                throw OpenClawEndpointError.exposureHostMismatch
            }

        case .tailnetDirect:
            guard Self.isTailnetDirectHost(host) else {
                throw OpenClawEndpointError.exposureHostMismatch
            }

        case .tailnetServe:
            guard Self.isTailnetHostname(host) else {
                throw OpenClawEndpointError.exposureHostMismatch
            }
            guard scheme == "wss" || scheme == "https" else {
                throw OpenClawEndpointError.secureTransportRequired
            }

        case .privateReverseProxy:
            guard scheme == "wss" || scheme == "https" else {
                throw OpenClawEndpointError.secureTransportRequired
            }
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

    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "localhost"
            || normalized == "::1"
            || normalized.hasPrefix("127.")
    }

    private static func isTailnetHostname(_ host: String) -> Bool {
        host.lowercased().hasSuffix(".ts.net")
    }

    private static func isTailnetDirectHost(_ host: String) -> Bool {
        let normalized = host.lowercased()

        if isTailnetHostname(normalized)
            || normalized.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }

        // MagicDNS short hostnames are intentionally allowed only when the
        // caller explicitly selected tailnetDirect.
        if !normalized.contains(".") && !normalized.contains(":") {
            return true
        }

        let octets = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = Int(octets[0]),
              let second = Int(octets[1]),
              octets.dropFirst(2).allSatisfy({
                  guard let value = Int($0) else { return false }
                  return (0...255).contains(value)
              }),
              first == 100,
              (64...127).contains(second) else {
            return false
        }
        return true
    }
}

public enum OpenClawEndpointError: Error, Sendable, Equatable {
    case unsupportedScheme
    case webSocketSchemeRequired
    case secureTransportRequired
    case invalidHostname
    case exposureHostMismatch
}
