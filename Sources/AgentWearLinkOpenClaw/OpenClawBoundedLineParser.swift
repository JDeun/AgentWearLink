import Foundation
import AgentWearLinkCore

/// Incrementally frames compatibility-SSE lines without allowing Foundation's
/// AsyncLineSequence to materialize an arbitrarily large unterminated line.
struct OpenClawBoundedLineParser {
    private static let dataFieldPrefixAllowance = "data: ".utf8.count

    private let maximumLineBytes: Int
    private var buffer = Data()
    private var skipLeadingLF = false

    init(maximumEventBytes: Int) {
        precondition(maximumEventBytes > 0)

        let allowance = Self.dataFieldPrefixAllowance
        if maximumEventBytes > Int.max - allowance {
            self.maximumLineBytes = Int.max
        } else {
            self.maximumLineBytes = maximumEventBytes + allowance
        }

        buffer.reserveCapacity(min(maximumLineBytes, 4_096))
    }

    mutating func append(_ byte: UInt8) throws -> String? {
        if skipLeadingLF {
            skipLeadingLF = false
            if byte == 0x0A {
                return nil
            }
        }

        switch byte {
        case 0x0D:
            let line = decodeAndReset()
            skipLeadingLF = true
            return line
        case 0x0A:
            return decodeAndReset()
        default:
            guard buffer.count < maximumLineBytes else {
                resetAfterLimitViolation()
                throw AWLError.transport(
                    "SSE event exceeds configured byte limit"
                )
            }
            buffer.append(byte)
            return nil
        }
    }

    mutating func finish() -> String? {
        guard !buffer.isEmpty else { return nil }
        return decodeAndReset()
    }

    private mutating func decodeAndReset() -> String {
        let line = String(decoding: buffer, as: UTF8.self)
        buffer.removeAll(keepingCapacity: true)
        return line
    }

    private mutating func resetAfterLimitViolation() {
        buffer.removeAll(keepingCapacity: false)
        skipLeadingLF = false
    }
}
