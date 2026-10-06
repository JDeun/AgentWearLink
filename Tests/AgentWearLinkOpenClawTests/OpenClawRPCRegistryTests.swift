import XCTest
@testable import AgentWearLinkOpenClaw

final class OpenClawRPCRegistryTests: XCTestCase {
    func testResolveRemovesPendingRequest() async throws {
        let registry = OpenClawRPCRegistry()
        try await registry.register(id: "1", method: "health")

        let resolved = try await registry.resolve(id: "1")

        XCTAssertEqual(resolved.method, "health")
        XCTAssertEqual(await registry.count, 0)
    }

    func testDuplicateRequestIDIsRejected() async throws {
        let registry = OpenClawRPCRegistry()
        try await registry.register(id: "1", method: "health")

        do {
            try await registry.register(id: "1", method: "status")
            XCTFail("Expected duplicate request failure")
        } catch let error as OpenClawRPCRegistryError {
            XCTAssertEqual(error, .duplicateRequestID("1"))
        }
    }

    func testDisconnectDrainDoesNotPreserveRequestsForReplay() async throws {
        let registry = OpenClawRPCRegistry()
        try await registry.register(id: "1", method: "agent")
        try await registry.register(id: "2", method: "health")

        let drained = await registry.drainForDisconnect()

        XCTAssertEqual(drained.count, 2)
        XCTAssertEqual(await registry.count, 0)
    }
}
