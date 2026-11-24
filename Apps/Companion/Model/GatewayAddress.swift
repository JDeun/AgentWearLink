import AgentWearLinkOpenClaw
import Foundation

public enum GatewayAddressError: Error, Equatable, Sendable {
    case empty
    case invalid
    /// A plaintext `ws://` address outside the tailnet would expose the
    /// device proof; only TLS or a Tailscale address is accepted.
    case insecure
}

/// Turns what the user scanned, pasted or typed into a validated private
/// Gateway endpoint. Public plaintext addresses are refused.
public enum GatewayAddress {
    /// Accepts `wss://host`, `https://host`, `host.tailnet.ts.net`,
    /// `100.x.y.z:18789` and MagicDNS short names (`gateway-host:18789`).
    public static func endpoint(fromUserInput raw: String) throws -> OpenClawEndpoint {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw GatewayAddressError.empty }
        let candidate: String
        if text.contains("://") {
            candidate = text
        } else {
            let host = text.split(separator: ":").first.map(String.init) ?? text
            candidate = (host.lowercased().hasSuffix(".ts.net") ? "wss://" : "ws://") + text
        }
        guard let url = URL(string: candidate) else { throw GatewayAddressError.invalid }
        return try endpoint(for: url)
    }

    /// Picks the strictest exposure profile the URL satisfies.
    public static func endpoint(for rawURL: URL) throws -> OpenClawEndpoint {
        guard var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            throw GatewayAddressError.invalid
        }
        switch scheme {
        case "wss", "https": components.scheme = "wss"
        case "ws", "http": components.scheme = "ws"
        default: throw GatewayAddressError.invalid
        }
        // A query or fragment never belongs to a Gateway address (and could
        // smuggle a token into persisted settings).
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        guard let url = components.url else { throw GatewayAddressError.invalid }
        let secure = components.scheme == "wss"

        if secure, let endpoint = try? OpenClawEndpoint(gatewayURL: url, exposure: .tailnetServe) {
            return endpoint
        }
        if let endpoint = try? OpenClawEndpoint(gatewayURL: url, exposure: .tailnetDirect) {
            return endpoint
        }
        if secure, let endpoint = try? OpenClawEndpoint(
            gatewayURL: url, exposure: .privateReverseProxy
        ) {
            return endpoint
        }
        throw secure ? GatewayAddressError.invalid : GatewayAddressError.insecure
    }

    /// Default display name for the paired Gateway: the first DNS label of
    /// its host (`mac-mini.tail1234.ts.net` → `mac-mini`), or the whole host
    /// for an IP address. Empty when no Gateway is paired.
    public static func defaultName(forGatewayURL gatewayURL: String) -> String {
        guard let host = URL(string: gatewayURL)?.host, !host.isEmpty else { return "" }
        let isIP = host.contains(":") || host.allSatisfy { $0.isNumber || $0 == "." }
        if isIP { return host }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}
