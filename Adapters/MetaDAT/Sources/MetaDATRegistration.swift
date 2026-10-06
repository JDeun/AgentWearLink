import Foundation
import MWDATCore

/// Thin registration façade used by the iOS reference application.
///
/// Registration remains an application concern because it can switch to the
/// Meta AI app and requires URL callback handling.
public struct MetaDATRegistration {
    private let wearables: any WearablesInterface

    public init(wearables: any WearablesInterface = Wearables.shared) {
        self.wearables = wearables
    }

    public func start() async throws {
        try await wearables.startRegistration()
    }

    public func unregister() async throws {
        try await wearables.startUnregistration()
    }

    @discardableResult
    public func handleCallback(_ url: URL) async throws -> Bool {
        guard
            let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ),
            components.queryItems?.contains(
                where: { $0.name == "metaWearablesAction" }
            ) == true
        else {
            return false
        }

        return try await wearables.handleUrl(url)
    }
}
