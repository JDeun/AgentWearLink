import XCTest
@testable import AgentWearLinkCore

final class AWLConnectionChainTests: XCTestCase {
    func testAllHealthyReadsAsReady() {
        let chain = AWLConnectionChain(observations: [
            .glasses: .ok, .phone: .ok, .network: .ok, .gateway: .ok, .agent: .ok,
        ])
        XCTAssertEqual(chain.summary, .allConnected)
        XCTAssertNil(chain.firstProblem)
        XCTAssertEqual(chain.links.map(\.id), [.glasses, .phone, .network, .gateway, .agent])
    }

    func testLinksAfterABreakAreUnknownNotOk() {
        // Behind a dead network route the app cannot know the gateway is
        // fine, even if the last observation said so.
        let chain = AWLConnectionChain(observations: [
            .glasses: .ok, .phone: .ok, .network: .broken(.networkUnreachable), .gateway: .ok, .agent: .ok,
        ])
        XCTAssertEqual(chain.status(of: .gateway), .unknown)
        XCTAssertEqual(chain.status(of: .agent), .unknown)
        XCTAssertEqual(chain.status(of: .phone), .ok)
    }

    func testFirstProblemIsTheEarliestBrokenLinkInChainOrder() {
        let chain = AWLConnectionChain(observations: [
            .glasses: .ok, .phone: .ok, .network: .broken(.networkUnreachable), .gateway: .broken(.gatewayUnreachable), .agent: .ok,
        ])
        XCTAssertEqual(chain.firstProblem?.link, .network)
        XCTAssertEqual(chain.firstProblem?.reason, .networkUnreachable)
        XCTAssertEqual(chain.summary, .problem(.network, .networkUnreachable))
    }

    func testMissingObservationIsUnknownAndNotAllConnected() {
        let chain = AWLConnectionChain(observations: [.glasses: .ok, .phone: .ok])
        XCTAssertEqual(chain.status(of: .network), .unknown)
        XCTAssertEqual(chain.summary, .checking)
    }

    func testEachProblemHasExactlyOneRepairAction() {
        for reason in AWLChainProblemReason.allCases {
            XCTAssertNotNil(AWLChainRepairAction.for(reason), "\(reason) has no repair action")
        }
        XCTAssertEqual(AWLChainRepairAction.for(.networkUnreachable), .recheck)
        XCTAssertEqual(AWLChainRepairAction.for(.pairingRevoked), .runSetupAgain)
        XCTAssertEqual(AWLChainRepairAction.for(.microphoneDenied), .openAppSettings)
    }
}
