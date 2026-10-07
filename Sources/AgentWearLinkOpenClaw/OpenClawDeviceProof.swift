import Foundation

private extension Data {
    var base64URLEncodedString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct OpenClawDeviceProof: Encodable, Sendable, Equatable {
    public let id: String
    public let publicKey: String
    public let signature: String
    public let signedAt: Int64
    public let nonce: String
}

public struct OpenClawDeviceProofBuilder: Sendable {
    public init() {}

    /// Mirrors OpenClaw buildDeviceAuthPayloadV3 field order exactly.
    ///
    /// Scope order is intentionally preserved. The signed token must be the
    /// same effective token used by the connect auth selection.
    public func buildPayloadV3(
        deviceID: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String],
        token: String?,
        nonce: String,
        signedAt: Int64,
        platform: String,
        deviceFamily: String
    ) -> Data {
        let fields = [
            "v3",
            deviceID,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(signedAt),
            token ?? "",
            nonce,
            platform
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
            deviceFamily
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        ]
        return Data(fields.joined(separator: "|").utf8)
    }

    public func makeProof(
        identity: OpenClawDeviceIdentity,
        client: OpenClawGatewayClientIdentity = .backend,
        role: String = "operator",
        scopes: [String],
        token: String?,
        challenge: OpenClawConnectChallenge
    ) throws -> OpenClawDeviceProof {
        guard challenge.ts >= 0, !challenge.nonce.isEmpty else {
            throw OpenClawDeviceProofError.invalidChallenge
        }

        let id = try identity.deviceID
        let payload = buildPayloadV3(
            deviceID: id,
            clientID: client.id,
            clientMode: client.mode,
            role: role,
            scopes: scopes,
            token: token,
            nonce: challenge.nonce,
            signedAt: challenge.ts,
            platform: client.platform,
            deviceFamily: client.deviceFamily
        )
        let signature = try identity.sign(payload)

        return OpenClawDeviceProof(
            id: id,
            publicKey: try identity.publicKeyRaw.base64URLEncodedString,
            signature: signature.base64URLEncodedString,
            signedAt: challenge.ts,
            nonce: challenge.nonce
        )
    }
}

public enum OpenClawDeviceProofError: Error, Sendable, Equatable {
    case invalidChallenge
}
