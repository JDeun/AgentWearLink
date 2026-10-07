import Foundation

/// Tracks request/response correlation for one WebSocket connection.
///
/// Disconnect fails every pending request. Requests are never retained for
/// implicit replay on a new connection.
public actor OpenClawRPCRegistry {
    public struct Pending: Sendable, Equatable {
        public let id: String
        public let method: String

        public init(id: String, method: String) {
            self.id = id
            self.method = method
        }
    }

    private var pending: [String: Pending] = [:]
    private let beforeRegister: (@Sendable () async -> Void)?
    public let maximumPendingRequests: Int

    public init(maximumPendingRequests: Int = 64) {
        precondition(maximumPendingRequests > 0)
        self.maximumPendingRequests = maximumPendingRequests
        self.beforeRegister = nil
    }

    init(
        maximumPendingRequests: Int = 64,
        beforeRegister: @escaping @Sendable () async -> Void
    ) {
        precondition(maximumPendingRequests > 0)
        self.maximumPendingRequests = maximumPendingRequests
        self.beforeRegister = beforeRegister
    }

    public func register(id: String, method: String) async throws {
        if let beforeRegister {
            await beforeRegister()
        }

        guard pending[id] == nil else {
            throw OpenClawRPCRegistryError.duplicateRequestID(id)
        }
        guard pending.count < maximumPendingRequests else {
            throw OpenClawRPCRegistryError.tooManyPendingRequests(
                maximum: maximumPendingRequests
            )
        }
        pending[id] = Pending(id: id, method: method)
    }

    @discardableResult
    public func resolve(id: String) throws -> Pending {
        guard let value = pending.removeValue(forKey: id) else {
            throw OpenClawRPCRegistryError.unknownResponseID(id)
        }
        return value
    }

    public func remove(id: String) {
        pending[id] = nil
    }

    public func drainForDisconnect() -> [Pending] {
        let values = Array(pending.values)
        pending.removeAll(keepingCapacity: false)
        return values
    }

    public var count: Int { pending.count }
}

public enum OpenClawRPCRegistryError: Error, Sendable, Equatable {
    case duplicateRequestID(String)
    case unknownResponseID(String)
    case tooManyPendingRequests(maximum: Int)
}
