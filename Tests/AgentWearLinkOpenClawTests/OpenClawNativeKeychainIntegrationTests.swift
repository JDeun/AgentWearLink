import Foundation
import Security
import XCTest
@testable import AgentWearLinkOpenClaw

#if os(macOS)
/// Real Security.framework / macOS Keychain smoke, not an in-memory mock.
///
/// Deliberately opt-in on a fresh GitHub Actions runner. Running the ordinary
/// local XCTest suite must never create items in a developer's login Keychain.
final class OpenClawNativeKeychainIntegrationTests: XCTestCase {
    func testIsolatedNativeKeychainIdentityAndScopedReadOnlyGrantCAS() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CI"] == "true",
              environment["AWL_RUN_NATIVE_KEYCHAIN_INTEGRATION"] == "1" else {
            throw XCTSkip("Only run against a disposable macOS CI Keychain")
        }

        let service = "dev.agentwearlink.ci.keychain."
            + UUID().uuidString.lowercased()
        let cleanupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        // Delete only the items in this single random test service, including
        // on assertion failures; never touch the production Keychain service.
        defer {
            let status = SecItemDelete(cleanupQuery as CFDictionary)
            XCTAssertTrue(
                status == errSecSuccess || status == errSecItemNotFound,
                "Synthetic Keychain service cleanup must succeed"
            )
        }

        let identityStore = KeychainOpenClawDeviceIdentityStore(service: service)
        let firstLoad = try await identityStore.load()
        XCTAssertNil(firstLoad)

        let generated = OpenClawDeviceIdentity.generate()
        let winner = try await identityStore.loadOrCreate(generated)
        XCTAssertEqual(winner, generated)

        // A *different* storage actor must recover the exact private signing
        // key through the native Keychain API.
        let independentIdentityStore = KeychainOpenClawDeviceIdentityStore(
            service: service
        )
        let independentLoad = try await independentIdentityStore.load()
        XCTAssertEqual(independentLoad, generated)
        let secondCandidate = OpenClawDeviceIdentity.generate()
        let persistedWinner = try await independentIdentityStore.loadOrCreate(
            secondCandidate
        )
        XCTAssertEqual(persistedWinner, generated)

        let deviceID = try generated.deviceID
        let namespaceA = try OpenClawGatewayCredentialNamespace(
            stableIdentifier: "synthetic-gateway-A"
        )
        let namespaceB = try OpenClawGatewayCredentialNamespace(
            stableIdentifier: "synthetic-gateway-B"
        )
        let scopedA = GatewayScopedOpenClawDeviceCredentialStore(
            base: KeychainOpenClawDeviceCredentialStore(service: service),
            namespace: namespaceA
        )
        let scopedAIndependent = GatewayScopedOpenClawDeviceCredentialStore(
            base: KeychainOpenClawDeviceCredentialStore(service: service),
            namespace: namespaceA
        )
        let scopedB = GatewayScopedOpenClawDeviceCredentialStore(
            base: KeychainOpenClawDeviceCredentialStore(service: service),
            namespace: namespaceB
        )

        let initial = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            requestedRole: "operator",
            scopes: ["operator.read"],
            token: "synthetic-read-grant-" + UUID().uuidString
        )
        let inserted = try await scopedA.compareAndSave(initial, expected: nil)
        XCTAssertTrue(inserted)
        let duplicate = try await scopedA.compareAndSave(initial, expected: nil)
        XCTAssertFalse(duplicate)

        let freshActorRead = try await scopedAIndependent.load(
            deviceID: deviceID, role: "operator"
        )
        XCTAssertEqual(freshActorRead, initial)
        XCTAssertTrue(OpenClawReadOnlyGrantAdmission.permits(freshActorRead))

        // Endpoint namespace isolation is mandatory even for two records
        // with the same device ID and authenticated role.
        let wrongGateway = try await scopedB.load(
            deviceID: deviceID, role: "operator"
        )
        XCTAssertNil(wrongGateway)

        let rotated = OpenClawDeviceCredential(
            deviceID: deviceID,
            role: "operator",
            requestedRole: "operator",
            scopes: ["operator.read"],
            token: "synthetic-rotated-grant-" + UUID().uuidString
        )
        let replaced = try await scopedAIndependent.compareAndSave(
            rotated, expected: initial
        )
        XCTAssertTrue(replaced)
        let staleOverwrite = try await scopedA.compareAndSave(
            initial, expected: initial
        )
        XCTAssertFalse(staleOverwrite)
        let staleRemove = try await scopedA.compareAndRemove(
            deviceID: deviceID, role: "operator", expected: initial
        )
        XCTAssertFalse(staleRemove)

        let rotatedRead = try await scopedA.load(
            deviceID: deviceID, role: "operator"
        )
        XCTAssertEqual(rotatedRead, rotated)
        let removed = try await scopedAIndependent.compareAndRemove(
            deviceID: deviceID, role: "operator", expected: rotated
        )
        XCTAssertTrue(removed)
        let finalRead = try await scopedA.load(
            deviceID: deviceID, role: "operator"
        )
        XCTAssertNil(finalRead)
    }
}
#endif
