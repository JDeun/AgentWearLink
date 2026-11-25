import Foundation

/// The application-session version is independent of the AWLF envelope version.
/// Exactly one implemented capability: deterministic synthetic echo.
public struct LabMessageAgreement: Equatable {
    public let version: UInt8
    public let capabilities: UInt16
    public let maximumPayload: Int
}

enum LabNegotiationError: Error, Equatable {
    case malformed, unsupportedVersion, unsupportedCapability
}

/// Fixed six-byte hello/accept payload:
/// min-version, max-version, 16-bit capabilities, 16-bit maximum payload.
/// Accept has min == max and only locally implemented/offered capability bits.
enum LabMessageNegotiation {
    static let version: UInt8 = 1
    static let syntheticEcho: UInt16 = 1
    static let correlation: UInt32 = 1

    struct Offer {
        let minimum: UInt8
        let maximum: UInt8
        let capabilities: UInt16
        let payloadLimit: Int
    }

    static func decode(_ bytes: [UInt8]) throws -> Offer {
        guard bytes.count == 6, bytes[0] != 0, bytes[0] <= bytes[1] else {
            throw LabNegotiationError.malformed
        }
        let limit = (Int(bytes[4]) << 8) | Int(bytes[5])
        guard (LabSize.small.rawValue...LabFrameCodec.maxPayloadBytes).contains(limit) else {
            throw LabNegotiationError.malformed
        }
        return Offer(minimum: bytes[0], maximum: bytes[1],
                     capabilities: (UInt16(bytes[2]) << 8) | UInt16(bytes[3]), payloadLimit: limit)
    }

    private static func encode(version: UInt8, capabilities: UInt16, payloadLimit: Int) -> [UInt8] {
        [version, version, UInt8(truncatingIfNeeded: capabilities >> 8), UInt8(truncatingIfNeeded: capabilities),
         UInt8(truncatingIfNeeded: payloadLimit >> 8), UInt8(truncatingIfNeeded: payloadLimit)]
    }

    static func hello(maximumSize: LabSize) -> [UInt8] {
        encode(version: version, capabilities: syntheticEcho, payloadLimit: maximumSize.rawValue)
    }

    static func select(hello bytes: [UInt8], maximumSize: LabSize) throws -> LabMessageAgreement {
        let offer = try decode(bytes)
        guard offer.minimum <= version, offer.maximum >= version else {
            throw LabNegotiationError.unsupportedVersion
        }
        let selected = offer.capabilities & syntheticEcho
        guard selected == syntheticEcho else { throw LabNegotiationError.unsupportedCapability }
        return LabMessageAgreement(version: version, capabilities: selected,
                                   maximumPayload: min(offer.payloadLimit, maximumSize.rawValue))
    }

    static func acceptBytes(_ agreement: LabMessageAgreement) -> [UInt8] {
        encode(version: agreement.version, capabilities: agreement.capabilities, payloadLimit: agreement.maximumPayload)
    }

    static func accept(_ bytes: [UInt8], offeredMaximum: LabSize) throws -> LabMessageAgreement {
        let selected = try decode(bytes)
        guard selected.minimum == version, selected.maximum == version else {
            throw LabNegotiationError.unsupportedVersion
        }
        guard selected.capabilities == syntheticEcho else { throw LabNegotiationError.unsupportedCapability }
        guard selected.payloadLimit <= offeredMaximum.rawValue else { throw LabNegotiationError.malformed }
        return LabMessageAgreement(version: version, capabilities: selected.capabilities,
                                   maximumPayload: selected.payloadLimit)
    }
}
