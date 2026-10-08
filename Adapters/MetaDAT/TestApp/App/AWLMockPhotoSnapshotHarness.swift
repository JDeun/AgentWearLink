import AgentWearLinkCore
import AgentWearLinkMetaDATIntegration
import Foundation
import SwiftUI

/// Real vendor adapter snapshot path backed by app-hosted MockDeviceKit.
/// Test-only: never contacts a Gateway, uploads media or uses camera hardware.
@MainActor
final class AWLMockPhotoSnapshotHarness: ObservableObject {
    @Published private(set) var status = "photo-not-started"
    private var capturing = false

    func captureOnce() async {
        guard !capturing else { return }
        capturing = true
        defer { capturing = false }

        let adapter = MetaDATDeviceAdapter(
            connectTimeout: .seconds(15),
            snapshotTimeout: .seconds(5)
        )
        status = "photo-connecting"
        let result: String
        do {
            try await adapter.connect()
            status = "photo-capturing"
            let image = try await adapter.captureSnapshot(
                interactionID: InteractionID()
            )
            if image.format == .jpeg, image.data.count >= 4,
               image.data.prefix(2) == Data([0xFF, 0xD8]),
               image.data.suffix(2) == Data([0xFF, 0xD9]) {
                result = "photo-snapshot-verified"
            } else {
                result = "photo-invalid-jpeg"
            }
        } catch {
            // Never surface SDK error strings or private image bytes to UI.
            result = status == "photo-connecting"
                ? "photo-connect-failed" : "photo-capture-failed"
        }
        // Both success and failure become terminal only after all camera
        // resources/session ownership have been retired. UI tests can safely
        // start a second run or unpair after observing this marker.
        await adapter.disconnect()
        status = result
    }
}
