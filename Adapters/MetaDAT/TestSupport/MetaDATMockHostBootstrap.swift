import Foundation
import MWDATCore

#if DEBUG
import MWDATMockDevice
#endif

/// Test-only bootstrap used by an iOS host application.
///
/// The production adapter never enables MockDeviceKit. Keeping this behind
/// DEBUG plus an explicit launch argument prevents a test transport from being
/// activated accidentally in a release host.
public enum MetaDATMockHostBootstrap {
    public static let launchArgument = "--awl-meta-ui-testing"
    public static let portFileEnvironment = "MWDAT_TEST_SERVER_PORT_FILE"

    public static func configureIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard arguments.contains(launchArgument) else { return }

        #if DEBUG
        try Wearables.configure()
        MockDeviceKit.shared.enable(
            config: MockDeviceKitConfig(initiallyRegistered: false)
        )
        _ = try await MockDeviceKit.shared.startTestServer(
            portFilePath: environment[portFileEnvironment]
        )
        #else
        throw MetaDATMockHostError.unavailableInReleaseBuild
        #endif
    }
}

public enum MetaDATMockHostError: Error, Equatable {
    case unavailableInReleaseBuild
}
