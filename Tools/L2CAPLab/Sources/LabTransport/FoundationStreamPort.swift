import Foundation

public enum StreamPortError: Error { case closed, failed, invalidSize }

/// Foundation adapter for a future CBL2CAPChannel input/output stream pair.
/// The platform owner schedules/opens the pair on its serial run loop; it must
/// pump on readiness plus an independent deadline timer, never busy-loop.
/// This wrapper has no Bluetooth API or connection ownership.
public final class FoundationStreamPort: LabPort {
    private let input: InputStream
    private let output: OutputStream
    public private(set) var isClosed = false

    public init(input: InputStream, output: OutputStream) {
        self.input = input
        self.output = output
    }

    public func write(_ bytes: [UInt8]) throws -> Int {
        guard !isClosed else { throw StreamPortError.closed }
        guard !bytes.isEmpty, bytes.count <= LabSession.chunkLimit else { throw StreamPortError.invalidSize }
        switch output.streamStatus {
        case .error: throw StreamPortError.failed
        case .closed, .atEnd: throw StreamPortError.closed
        default: break
        }
        guard output.hasSpaceAvailable else { return 0 }
        let written = bytes.withUnsafeBufferPointer {
            output.write($0.baseAddress!, maxLength: $0.count)
        }
        guard written >= 0 else { throw StreamPortError.failed }
        return written
    }

    public func read(maxBytes: Int) throws -> LabRead {
        guard !isClosed else { throw StreamPortError.closed }
        guard maxBytes > 0, maxBytes <= LabSession.chunkLimit else { throw StreamPortError.invalidSize }
        switch input.streamStatus {
        case .error: throw StreamPortError.failed
        case .atEnd, .closed: return .end
        default: break
        }
        guard input.hasBytesAvailable else { return .wouldBlock }
        var bytes = [UInt8](repeating: 0, count: maxBytes)
        let length = bytes.withUnsafeMutableBufferPointer {
            input.read($0.baseAddress!, maxLength: $0.count)
        }
        guard length >= 0, length <= maxBytes else { throw StreamPortError.failed }
        return length == 0 ? .end : .bytes(Array(bytes.prefix(length)))
    }

    /// Caller removes scheduled streams and retires delegates separately.
    public func close() {
        guard !isClosed else { return }
        isClosed = true
        input.close()
        output.close()
    }
}
