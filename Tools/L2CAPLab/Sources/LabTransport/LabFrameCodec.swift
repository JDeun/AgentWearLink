import Foundation

/// Independent synthetic lab protocol. Not a Meta/Visor wire format.
public enum LabFrameKind: UInt8, Equatable {
    case request = 1, response = 2
}

public struct LabFrame: Equatable {
    public let kind: LabFrameKind
    public let sequence: UInt32
    public let correlation: UInt32
    public let payload: [UInt8]

    public init(kind: LabFrameKind, sequence: UInt32, correlation: UInt32, payload: [UInt8]) {
        self.kind = kind
        self.sequence = sequence
        self.correlation = correlation
        self.payload = payload
    }

    /// Directional sequence numbers are independent. This is matching, not
    /// authentication or replay prevention across separate physical runs.
    public func isResponse(to request: LabFrame) -> Bool {
        kind == .response && request.kind == .request && correlation == request.correlation
    }
}

public enum LabFrameError: Error, Equatable {
    case staleGeneration, retired, inputEnded
    case invalidMagic, unsupportedVersion, invalidKind, invalidLength
    case invalidSequence, invalidCorrelation, sequenceExhausted
    case badChecksum, truncatedFrame, invalidIOCount, ioFailure
}

struct LabFrameHeader {
    let kind: LabFrameKind
    let length: Int
    let sequence: UInt32
    let correlation: UInt32
    var wireLength: Int { LabFrameCodec.headerBytes + length + LabFrameCodec.checksumBytes }
}

public enum LabFrameCodec {
    public static let headerBytes = 16
    public static let checksumBytes = 4
    public static let maxPayloadBytes = 4096
    public static let maxFrameBytes = headerBytes + maxPayloadBytes + checksumBytes
    public static let maxSequence: UInt32 = 1024
    private static let magic: [UInt8] = [0x41, 0x57, 0x4C, 0x46] // AWLF
    private static let version: UInt8 = 1

    private static func bigEndian32(_ value: UInt32) -> [UInt8] {
        [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    }

    static func read32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in offset..<(offset + 4) { value = (value << 8) | UInt32(bytes[i]) }
        return value
    }

    /// CRC-32/ISO-HDLC (IEEE); accidental corruption detection only.
    /// No authentication, encryption or authorization is provided by a CRC.
    public static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (crc & 1 == 0 ? 0 : 0xEDB88320)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    private static func validate(length: Int, sequence: UInt32, correlation: UInt32) throws {
        guard (1...maxPayloadBytes).contains(length) else { throw LabFrameError.invalidLength }
        guard (1...maxSequence).contains(sequence) else { throw LabFrameError.invalidSequence }
        guard correlation != 0 else { throw LabFrameError.invalidCorrelation }
    }

    public static func encode(_ frame: LabFrame) throws -> [UInt8] {
        try validate(length: frame.payload.count, sequence: frame.sequence, correlation: frame.correlation)
        var bytes = magic
        bytes.reserveCapacity(headerBytes + frame.payload.count + checksumBytes)
        bytes.append(version)
        bytes.append(frame.kind.rawValue)
        bytes.append(UInt8(truncatingIfNeeded: frame.payload.count >> 8))
        bytes.append(UInt8(truncatingIfNeeded: frame.payload.count))
        bytes.append(contentsOf: bigEndian32(frame.sequence))
        bytes.append(contentsOf: bigEndian32(frame.correlation))
        bytes.append(contentsOf: frame.payload)
        bytes.append(contentsOf: bigEndian32(checksum(bytes)))
        return bytes
    }

    /// Validate the entire fixed header before accepting even one payload byte.
    static func decodeHeader(_ bytes: [UInt8], expectedSequence: UInt32) throws -> LabFrameHeader {
        guard bytes.count == headerBytes else { throw LabFrameError.invalidLength }
        guard bytes.prefix(4).elementsEqual(magic) else { throw LabFrameError.invalidMagic }
        guard bytes[4] == version else { throw LabFrameError.unsupportedVersion }
        guard let kind = LabFrameKind(rawValue: bytes[5]) else { throw LabFrameError.invalidKind }
        let length = (Int(bytes[6]) << 8) | Int(bytes[7])
        let sequence = read32(bytes, at: 8)
        let correlation = read32(bytes, at: 12)
        try validate(length: length, sequence: sequence, correlation: correlation)
        guard sequence == expectedSequence else { throw LabFrameError.invalidSequence }
        return LabFrameHeader(kind: kind, length: length, sequence: sequence, correlation: correlation)
    }
}

/// Single-owner incremental parser. Holds at most one partial wire frame OR
/// one completed payload; caller retains the unconsumed suffix. Any wire error
/// poisons the generation (no scan-for-magic resynchronization).
public struct LabFrameDecoder {
    public let generation: UUID
    public private(set) var failure: LabFrameError?
    public private(set) var inputEnded = false
    public private(set) var isRetired = false
    private var wire: [UInt8] = []
    private var header: LabFrameHeader?
    private var ready: LabFrame?
    private var expectedSequence: UInt32 = 1

    public init(generation: UUID) { self.generation = generation }

    public var hasFrame: Bool { ready != nil }
    public var bufferedBytes: Int { wire.count + (ready?.payload.count ?? 0) }

    /// Read only the remainder of the header/body; leaves a coalesced suffix
    /// in the underlying stream until the consumer takes the first frame.
    public var nextReadLimit: Int {
        guard !isRetired, failure == nil, !inputEnded, ready == nil else { return 0 }
        return min(LabSession.chunkLimit, (header?.wireLength ?? LabFrameCodec.headerBytes) - wire.count)
    }

    private func check(_ token: UUID) throws {
        guard token == generation else { throw LabFrameError.staleGeneration }
        guard !isRetired else { throw LabFrameError.retired }
        if let failure { throw failure }
    }

    private mutating func poison(_ error: LabFrameError) {
        failure = error
        wire = []
        header = nil
        ready = nil
    }

    /// Returns the exact consumed count, at most one frame. Zero with hasFrame
    /// is backpressure. Bytes beyond that frame are not copied or inspected.
    @discardableResult
    public mutating func ingest(_ bytes: ArraySlice<UInt8>, generation token: UUID) throws -> Int {
        try check(token)
        guard !inputEnded else { throw LabFrameError.inputEnded }
        guard ready == nil, !bytes.isEmpty else { return 0 }
        do {
            guard expectedSequence <= LabFrameCodec.maxSequence else { throw LabFrameError.sequenceExhausted }
            var consumed = 0
            if header == nil {
                let count = min(LabFrameCodec.headerBytes - wire.count, bytes.count)
                wire.append(contentsOf: bytes.prefix(count))
                consumed += count
                guard wire.count == LabFrameCodec.headerBytes else { return consumed }
                header = try LabFrameCodec.decodeHeader(wire, expectedSequence: expectedSequence)
            }
            guard let parsed = header else { throw LabFrameError.invalidLength }
            let count = min(parsed.wireLength - wire.count, bytes.count - consumed)
            wire.append(contentsOf: bytes.dropFirst(consumed).prefix(count))
            consumed += count
            if wire.count == parsed.wireLength {
                let trailer = parsed.wireLength - LabFrameCodec.checksumBytes
                guard LabFrameCodec.checksum(wire.prefix(trailer)) == LabFrameCodec.read32(wire, at: trailer)
                else { throw LabFrameError.badChecksum }
                ready = LabFrame(kind: parsed.kind, sequence: parsed.sequence, correlation: parsed.correlation,
                                 payload: Array(wire[LabFrameCodec.headerBytes..<trailer]))
                wire = []
                header = nil
                expectedSequence += 1 // bounded by maxSequence; never wraps
            }
            return consumed
        } catch let error as LabFrameError {
            poison(error)
            throw error
        } catch {
            poison(.ioFailure)
            throw LabFrameError.ioFailure
        }
    }

    public mutating func take(generation token: UUID) throws -> LabFrame? {
        try check(token)
        let frame = ready
        ready = nil
        return frame
    }

    /// EOF is clean only at a frame boundary. A ready complete frame remains
    /// available; EOF does not prove a response or successful exchange.
    public mutating func endOfInput(generation token: UUID) throws {
        try check(token)
        guard !inputEnded else { return }
        guard wire.isEmpty else {
            poison(.truncatedFrame)
            throw LabFrameError.truncatedFrame
        }
        inputEnded = true
    }

    /// A fresh generation must use a fresh decoder; never reset/replay this one.
    public mutating func retire(generation token: UUID) {
        guard token == generation else { return }
        wire = []
        header = nil
        ready = nil
        isRetired = true
    }
}
