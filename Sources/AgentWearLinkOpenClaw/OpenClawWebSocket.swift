import Foundation

public protocol OpenClawWebSocket: Sendable {
    func connect() async
    func send(text: String) async throws
    func currentConnectionGeneration() async -> UInt64
    func send(text: String, connectionGeneration: UInt64) async throws
    func receive() async throws -> String
    func close() async
    func close(code: Int, reason: String?) async
}

public extension OpenClawWebSocket {
    func currentConnectionGeneration() async -> UInt64 {
        0
    }

    func send(text: String, connectionGeneration: UInt64) async throws {
        try await send(text: text)
    }

    func close(code: Int, reason: String?) async {
        await close()
    }
}

public actor URLSessionOpenClawWebSocket: OpenClawWebSocket {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var connectionGenerationValue: UInt64 = 0

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect() async {
        guard task == nil else { return }
        connectionGenerationValue &+= 1
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
    }

    public func currentConnectionGeneration() async -> UInt64 {
        connectionGenerationValue
    }

    public func send(text: String) async throws {
        guard let task else { throw AWLOpenClawError.disconnected }
        try await task.send(.string(text))
    }

    public func send(
        text: String,
        connectionGeneration expectedGeneration: UInt64
    ) async throws {
        try Task.checkCancellation()
        guard let task,
              connectionGenerationValue == expectedGeneration else {
            throw AWLOpenClawError.disconnected
        }

        do {
            try await task.send(.string(text))
        } catch {
            // Once the URLSession WebSocket send has been invoked, local code can
            // no longer prove that the remote peer did not receive the frame.
            throw AWLOpenClawError.deliveryUncertain
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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    public func close(code: Int, reason: String?) async {
        guard let task else { return }
        let closeCode = URLSessionWebSocketTask.CloseCode(rawValue: code)
            ?? .goingAway
        let reasonData = reason?.data(using: .utf8)
        task.cancel(with: closeCode, reason: reasonData)
        self.task = nil
    }
}
