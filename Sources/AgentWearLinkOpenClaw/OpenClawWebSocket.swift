import Foundation

public enum OpenClawTransportSendError: Error, Sendable, Equatable {
    /// The socket implementation cannot provide an atomic transport-generation
    /// fence, so the dispatcher must not risk sending a request across reconnects.
    case generationBindingUnavailable

    /// The request was bound to a transport generation that was retired before
    /// the socket accepted the frame. The frame is definitely not sent by the
    /// current transport.
    case staleGeneration

    /// The frame was handed to the old transport, but reconnect/close or a send
    /// failure made remote acceptance impossible to determine safely.
    case deliveryUncertain
}

public protocol OpenClawWebSocket: Sendable {
    func connect() async
    func send(text: String) async throws

    /// Returns the currently active transport generation when the implementation
    /// can atomically fence outbound sends. Request dispatch requires this.
    func transportGeneration() async -> UInt64?

    /// Sends only if the same transport generation is still active when this
    /// method enters the socket actor.
    func send(text: String, expectedGeneration: UInt64) async throws

    func receive() async throws -> String
    func close() async
    func close(code: Int, reason: String?) async
}

public extension OpenClawWebSocket {
    func transportGeneration() async -> UInt64? { nil }

    func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        throw OpenClawTransportSendError.generationBindingUnavailable
    }

    func close(code: Int, reason: String?) async {
        await close()
    }
}

public actor URLSessionOpenClawWebSocket: OpenClawWebSocket {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var generation: UInt64 = 0

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect() async {
        guard task == nil else { return }
        generation &+= 1
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
    }

    public func transportGeneration() async -> UInt64? {
        task == nil ? nil : generation
    }

    public func send(text: String) async throws {
        guard let task else { throw AWLOpenClawError.disconnected }
        try await task.send(.string(text))
    }

    public func send(
        text: String,
        expectedGeneration: UInt64
    ) async throws {
        guard generation == expectedGeneration,
              let task else {
            throw OpenClawTransportSendError.staleGeneration
        }

        // Cancellation before this point is a definite "not sent" outcome.
        try Task.checkCancellation()

        do {
            // Capture the concrete URLSessionWebSocketTask before suspension.
            // Actor reentrancy can retire/reconnect the transport while this
            // await is in flight, but it can never redirect this send to a new task.
            try await task.send(.string(text))
        } catch {
            // Once URLSession has accepted the send operation locally, a failure
            // cannot prove whether the peer observed the frame.
            throw OpenClawTransportSendError.deliveryUncertain
        }

        guard generation == expectedGeneration,
              let currentTask = self.task,
              currentTask === task else {
            throw OpenClawTransportSendError.deliveryUncertain
        }
    }

    public func receive() async throws -> String {
        guard let task else { throw AWLOpenClawError.disconnected }

        switch try await task.receive() {
        case let .string(text):
            return text
        case let .data(data):
            guard let text = String(data: data, encoding: .utf8) else {
                throw OpenClawFrameError.malformedFrame
            }
            return text
        @unknown default:
            throw OpenClawFrameError.malformedFrame
        }
    }

    public func close() async {
        guard let task else { return }
        generation &+= 1
        task.cancel(with: .normalClosure, reason: nil)
        self.task = nil
    }

    public func close(code: Int, reason: String?) async {
        guard let task else { return }
        generation &+= 1
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code)
            ?? .goingAway
        let reasonData = reason?.data(using: .utf8)
        task.cancel(with: closeCode, reason: reasonData)
        self.task = nil
    }
}
