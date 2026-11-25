import Foundation

public enum LabFramePump: Equatable {
    case idle, wouldBlock, progress(Int), end
}

/// One-frame TX + one-frame RX over the same bounded LabPort used by the raw
/// lab. No implicit retries, queue, peer identity or physical connection ownership.
/// Single serial owner supplies readiness, deadlines and cancellation.
public struct LabFramedTransport {
    public let generation: UUID
    public private(set) var failure: LabFrameError?
    public private(set) var isRetired = false
    private var decoder: LabFrameDecoder
    private var pending: [UInt8] = []
    private var offset = 0
    private var nextSequence: UInt32 = 1

    public init(generation: UUID) {
        self.generation = generation
        decoder = LabFrameDecoder(generation: generation)
    }

    public var hasFrame: Bool { decoder.hasFrame }
    public var hasPendingWrite: Bool { !pending.isEmpty }
    public var inputEnded: Bool { decoder.inputEnded }
    /// Logical retained wire/payload bytes, not allocator overhead.
    public var bufferedBytes: Int { pending.count + decoder.bufferedBytes }

    private func check(_ token: UUID) throws {
        guard token == generation else { throw LabFrameError.staleGeneration }
        guard !isRetired else { throw LabFrameError.retired }
        if let failure { throw failure }
    }

    private mutating func fail(_ error: LabFrameError) {
        failure = error
        pending = []
        offset = 0
        decoder.retire(generation: generation)
    }

    /// Nil means TX backpressure; the caller must retain/retry its own frame
    /// only after space becomes available. A rejected enqueue consumes no sequence.
    @discardableResult
    public mutating func enqueue(kind: LabFrameKind, correlation: UInt32, payload: [UInt8],
                                 generation token: UUID) throws -> UInt32? {
        try check(token)
        guard !hasPendingWrite else { return nil }
        guard nextSequence <= LabFrameCodec.maxSequence else { throw LabFrameError.sequenceExhausted }
        let sequence = nextSequence
        pending = try LabFrameCodec.encode(LabFrame(kind: kind, sequence: sequence,
                                                     correlation: correlation, payload: payload))
        offset = 0
        nextSequence += 1
        return sequence
    }

    /// Exactly one bounded I/O operation per invocation; partial acceptance is
    /// not delivery. Local errors poison both directions, discarding pending data.
    public mutating func pumpWrite(generation token: UUID, port: LabPort) throws -> LabFramePump {
        try check(token)
        guard hasPendingWrite else { return .idle }
        let count = min(LabSession.chunkLimit, pending.count - offset)
        do {
            let written = try port.write(Array(pending[offset..<(offset + count)]))
            guard written >= 0, written <= count else { throw LabFrameError.invalidIOCount }
            guard written > 0 else { return .wouldBlock }
            offset += written
            if offset == pending.count {
                pending = []
                offset = 0
            }
            return .progress(written)
        } catch let error as LabFrameError {
            fail(error)
            throw error
        } catch {
            fail(.ioFailure)
            throw LabFrameError.ioFailure
        }
    }

    /// No read is attempted while one decoded frame awaits consumption.
    /// EOF is an input-side event only; the owner decides whether to retire.
    public mutating func pumpRead(generation token: UUID, port: LabPort) throws -> LabFramePump {
        try check(token)
        if inputEnded { return .end }
        let count = decoder.nextReadLimit
        guard count > 0 else { return .idle }
        do {
            switch try port.read(maxBytes: count) {
            case .wouldBlock: return .wouldBlock
            case .end:
                try decoder.endOfInput(generation: token)
                return .end
            case .bytes(let bytes):
                guard !bytes.isEmpty, bytes.count <= count else { throw LabFrameError.invalidIOCount }
                let used = try decoder.ingest(bytes[...], generation: token)
                guard used == bytes.count else { throw LabFrameError.invalidIOCount }
                return .progress(used)
            }
        } catch let error as LabFrameError {
            fail(error)
            throw error
        } catch {
            fail(.ioFailure)
            throw LabFrameError.ioFailure
        }
    }

    public mutating func take(generation token: UUID) throws -> LabFrame? {
        try check(token)
        return try decoder.take(generation: token)
    }

    /// Does not close LabPort or any OS object; the connection owner must do so.
    public mutating func retire(generation token: UUID) {
        guard token == generation else { return }
        pending = []
        offset = 0
        decoder.retire(generation: token)
        isRetired = true
    }
}
