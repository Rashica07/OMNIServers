import XCTest
@testable import craftpanel_Swift

final class JoinLinkTests: XCTestCase {
    func testBedrockGetsALinkThatAddsTheServer() {
        let p = JoinLink.plan(isBedrock: true, name: "Our world", address: "192.168.1.9:19132")
        XCTAssertTrue(p.bedrock)
        XCTAssertEqual(p.uri, "minecraft://?addExternalServer=Our%20world|192.168.1.9:19132")
    }
    func testJavaHasNoLinkSoItCopiesTheAddress() {
        let p = JoinLink.plan(isBedrock: false, name: "SMP", address: "192.168.1.9:25565")
        XCTAssertFalse(p.bedrock); XCTAssertNil(p.uri); XCTAssertEqual(p.address, "192.168.1.9:25565")
    }
}
