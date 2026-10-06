/// Snapshot capture generation. Every new capture/invalidating lifecycle edge
/// advances the token; late completion from an older generation is rejected.
public actor MetaDATCaptureGeneration {
    public typealias Token = UInt64
    private var current: Token = 0

    public init() {}

    public func begin() -> Token {
        current &+= 1
        return current
    }

    public func invalidate() { current &+= 1 }

    public func isCurrent(_ token: Token) -> Bool { token == current }
}
