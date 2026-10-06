import Foundation

public struct OpenClawPairingRequired: Sendable, Equatable {
    public let requestID: String?
    public let deviceID: String?
    public let reason: String?
    public let recommendedNextStep: String?
    public let waitForResolution: Bool
    public let pauseReconnect: Bool

    public init(
        requestID: String?,
        deviceID: String?,
        reason: String?,
        recommendedNextStep: String?,
        waitForResolution: Bool,
        pauseReconnect: Bool
    ) {
        self.requestID = requestID
        self.deviceID = deviceID
        self.reason = reason
        self.recommendedNextStep = recommendedNextStep
        self.waitForResolution = waitForResolution
        self.pauseReconnect = pauseReconnect
    }

    public init?(error: OpenClawResponseEnvelope.GatewayError) {
        guard case let .object(details)? = error.details,
              case let .string(code)? = details["code"],
              code == "PAIRING_REQUIRED" else {
            return nil
        }

        func string(_ key: String) -> String? {
            guard case let .string(value)? = details[key] else { return nil }
            return value
        }

        func bool(_ key: String) -> Bool {
            guard case let .bool(value)? = details[key] else { return false }
            return value
        }

        self.init(
            requestID: string("requestId"),
            deviceID: string("deviceId"),
            reason: string("reason"),
            recommendedNextStep: string("recommendedNextStep"),
            waitForResolution: bool("waitForResolution"),
            pauseReconnect: bool("pauseReconnect")
        )
    }
}

public enum OpenClawPairingState: Sendable, Equatable {
    case unknown
    case required(OpenClawPairingRequired)
    case approved
    case rejected
    case expired
}
