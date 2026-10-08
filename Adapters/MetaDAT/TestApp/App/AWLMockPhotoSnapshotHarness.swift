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
        do {
            try await adapter.connect()
            status = "photo-capturing"
            let image = try await adapter.captureSnapshot(
                interactionID: InteractionID()
            )
            guard image.format == .jpeg, image.data.count >= 4,
                  image.data.prefix(2) == Data([0xFF, 0xD8]),
                  image.data.suffix(2) == Data([0xFF, 0xD9]) else {
                status = "photo-invalid-jpeg"
                await adapter.disconnect()
                return
            }
            status = "photo-snapshot-verified"
        } catch {
            // Never surface SDK error strings or private image bytes to UI.
            status = status == "photo-connecting" ? "photo-connect-failed" : "photo-capture-failed"
        }
        await adapter.disconnect()
    }
}
