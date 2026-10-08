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
    public static let voiceLaunchArgument = "--awl-meta-voice-ui-testing"
    public static let wakeLaunchArgument = "--awl-meta-wake-ui-testing"
    public static let portFileEnvironment = "MWDAT_TEST_SERVER_PORT_FILE"

    public static func configureIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws {
        guard arguments.contains(launchArgument) else { return }

        #if DEBUG
        try Wearables.configure()
        MockDeviceKit.shared.enable(
            config: MockDeviceKitConfig(
                initiallyRegistered: arguments.contains(voiceLaunchArgument)
                    || arguments.contains(wakeLaunchArgument)
            )
        )
        _ = try await MockDeviceKit.shared.startTestServer(
            portFilePath: environment[portFileEnvironment]
        )
        #else
        throw MetaDATMockHostError.unavailableInReleaseBuild
        #endif
    }

    /// Injects a final DAT Speech transcript through the real vendor callback
    /// chain, after a successful post-ack foreground media handoff.
    public static func sendFinalMockTranscript(_ text: String) throws {
        #if DEBUG
        guard !text.isEmpty,
              let glasses = MockDeviceKit.shared.pairedDevices
                .compactMap({ $0 as? MockGlasses }).first else {
            throw MetaDATMockHostError.noPairedDevices
        }
        glasses.services.speech.simulateTranscription(
            text: text, isFinal: true, confidence: 1
        )
        #else
        throw MetaDATMockHostError.unavailableInReleaseBuild
        #endif
    }

    /// Configure the same deterministic captured photo on both current mock
    /// still-capture routes. Called by the UI-test host *after* pairing so no
    /// test fixture is installed in the release adapter or stored persistently.
    public static func configureCapturedPhotoFixture(fileURL: URL) throws -> Int {
        #if DEBUG
        let paired = MockDeviceKit.shared.pairedDevices
        guard !paired.isEmpty else { throw MetaDATMockHostError.noPairedDevices }
        var configured = 0
        for device in paired {
            guard let glasses = device as? MockGlasses else { continue }
            glasses.services.camera.setCapturedImage(fileURL: fileURL)
            glasses.services.cameraCapture.setCapturedPhoto(fileURL: fileURL)
            configured += 1
        }
        guard configured > 0 else { throw MetaDATMockHostError.noPairedDevices }
        return configured
        #else
        throw MetaDATMockHostError.unavailableInReleaseBuild
        #endif
    }
}

public enum MetaDATMockHostError: Error, Equatable {
    case unavailableInReleaseBuild
    case noPairedDevices
}
