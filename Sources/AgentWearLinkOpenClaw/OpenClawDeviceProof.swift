import Foundation

public struct OpenClawDeviceProof: Encodable, Sendable, Equatable {
    public let id: String
    public let publicKey: String
    public let signature: String
    public let signedAt: Int64
    public let nonce: String
}

public struct OpenClawDeviceProofBuilder: Sendable {
    public init() {}

    /// Canonical AWL v3 device-auth payload.
    ///
    /// Keep this builder isolated: if OpenClaw changes its canonical payload,
    /// only the protocol adapter and its golden-vector tests should change.
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
            scopes.sorted().joined(separator: ","),
            token ?? "",
            nonce,
            String(signedAt),
            platform,
            deviceFamily
        ]
        return Data(fields.joined(separator: "|").utf8)
    }

    public func makeProof(
        identity: OpenClawDeviceIdentity,
        clientID: String = "agentwearlink",
        clientMode: String = "operator",
        role: String = "operator",
        scopes: [String],
        token: String?,
        challenge: OpenClawConnectChallenge,
        platform: String = "ios",
        deviceFamily: String = "iphone"
    ) throws -> OpenClawDeviceProof {
        guard challenge.ts >= 0, !challenge.nonce.isEmpty else {
            throw OpenClawDeviceProofError.invalidChallenge
        }

        let id = try identity.deviceID
        let payload = buildPayloadV3(
            deviceID: id,
            clientID: clientID,
            clientMode: clientMode,
            role: role,
            scopes: scopes,
            token: token,
            nonce: challenge.nonce,
            signedAt: challenge.ts,
            platform: platform,
            deviceFamily: deviceFamily
        )
        let signature = try identity.sign(payload)

        return OpenClawDeviceProof(
            id: id,
            publicKey: try identity.publicKeyRaw.base64EncodedString(),
            signature: signature.base64EncodedString(),
            signedAt: challenge.ts,
            nonce: challenge.nonce
        )
    }
}

public enum OpenClawDeviceProofError: Error, Sendable, Equatable {
    case invalidChallenge
}
