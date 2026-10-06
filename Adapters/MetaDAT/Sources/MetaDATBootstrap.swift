import MWDATCore

public enum MetaDATBootstrap {
    /// Must be called once during application launch before accessing
    /// Wearables.shared.
    public static func configure() throws {
        try Wearables.configure()
    }
}
