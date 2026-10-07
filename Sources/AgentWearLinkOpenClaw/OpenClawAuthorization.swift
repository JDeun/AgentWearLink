import Foundation

public struct OpenClawAuthorizationSnapshot: Sendable, Equatable {
    public let role: String
    public let scopes: Set<String>

    public init(role: String, scopes: [String]) {
        self.role = role
        self.scopes = Set(scopes)
    }

    public func grants(_ requiredScope: String) -> Bool {
        if scopes.contains("operator.admin") {
            return true
        }
        return scopes.contains(requiredScope)
    }
}

public enum OpenClawAuthorizationError: Error, Sendable, Equatable {
    case notReady
    case roleMismatch(expected: String, actual: String)
    case missingScope(String)
}

public extension OpenClawGatewayState {
    func authorizationSnapshot() throws -> OpenClawAuthorizationSnapshot {
        guard connectionState == .ready, let hello else {
            throw OpenClawAuthorizationError.notReady
        }
        return OpenClawAuthorizationSnapshot(
            role: hello.auth.role,
            scopes: hello.auth.scopes
        )
    }

    func requireOperatorScope(_ scope: String) throws {
        let authorization = try authorizationSnapshot()
        guard authorization.role == "operator" else {
            throw OpenClawAuthorizationError.roleMismatch(
                expected: "operator",
                actual: authorization.role
            )
        }
        guard authorization.grants(scope) else {
            throw OpenClawAuthorizationError.missingScope(scope)
        }
    }
}
