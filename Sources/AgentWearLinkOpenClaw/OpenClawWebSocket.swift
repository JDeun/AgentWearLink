import Foundation

public protocol OpenClawWebSocket: Sendable {
    func connect() async
    func send(text: String) async throws
    func receive() async throws -> String
    func close() async
    func close(code: Int, reason: String?) async
}

public extension OpenClawWebSocket {
    func close(code: Int, reason: String?) async {
        await close()
    }
}

public actor URLSessionOpenClawWebSocket: OpenClawWebSocket {
    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    public init(url: URL, session: URLSession = .shared) {
        self.url = url
        self.session = session
    }

    public func connect() async {
        guard task == nil else { return }
        let socket = session.webSocketTask(with: url)
        task = socket
        socket.resume()
    }

    public func send(text: String) async throws {
        guard let task else { throw AWLOpenClawError.disconnected }
        try await task.send(.string(text))
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
