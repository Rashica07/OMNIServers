import XCTest
@testable import craftpanel_Swift

final class RamAdvisorTests: XCTestCase {
    private func mac(_ gb: Int, cores: Int = 11) -> SystemMemory {
        SystemMemory(totalMB: gb * 1024, availableMB: gb * 512, memoryType: "LPDDR5", chip: "Apple M3 Pro", cores: cores)
    }

    func testSafeLimit() {
        XCTAssertEqual(mac(18).safeMaxMB, 13824)   // 75%
        XCTAssertEqual(mac(4).safeMaxMB, 2048)     // leaves 2 GB
        XCTAssertEqual(mac(2).safeMaxMB, 1024)     // floor
    }

    func testRecommendationScalesWithPlayersAndKind() {
        let safe = mac(18).safeMaxMB
        XCTAssertEqual(RamAdvisor.recommend(kind: .minigame, players: 2, safeMaxMB: safe), 2560)
        XCTAssertEqual(RamAdvisor.recommend(kind: .vanillaLike, players: 20, safeMaxMB: safe), 4608)
        XCTAssertEqual(RamAdvisor.recommend(kind: .modpack, players: 4, safeMaxMB: safe), 5120)
        XCTAssertLessThan(RamAdvisor.recommend(kind: .minigame, players: 2, safeMaxMB: safe),
                          RamAdvisor.recommend(kind: .modded, players: 2, safeMaxMB: safe))
        // capped at the safe limit on a small Mac
        XCTAssertEqual(RamAdvisor.recommend(kind: .modpack, players: 50, safeMaxMB: mac(8).safeMaxMB), 6144)
    }

    func testWarnings() {
        let big = mac(18)
        XCTAssertTrue(RamAdvisor.warnings(chosenMB: 2560, kind: .minigame, players: 2, system: big).isEmpty)
        XCTAssertTrue(RamAdvisor.warnings(chosenMB: 16384, kind: .minigame, players: 2, system: big).contains { $0.level == .serious })
        XCTAssertFalse(RamAdvisor.warnings(chosenMB: 1024, kind: .modpack, players: 10, system: big).isEmpty)
        XCTAssertFalse(RamAdvisor.warnings(chosenMB: 2048, kind: .vanillaLike, players: 2, system: mac(6)).isEmpty)  // weak Mac
        XCTAssertTrue(RamAdvisor.warnings(chosenMB: 8192, kind: .vanillaLike, players: 2, system: big, otherAllocatedMB: 8192).contains { $0.level == .serious })
        XCTAssertTrue(RamAdvisor.warnings(chosenMB: 99999, kind: .bedrock, players: 2, system: big).isEmpty)
    }

    func testMemoryTypeParsing() {
        XCTAssertEqual(SystemMemory.parseType(["dimm_type": "LPDDR5", "SPMemoryDataType": "18 GB"]), "LPDDR5")
        XCTAssertEqual(SystemMemory.parseType(["_items": [["dimm_type": "empty"], ["dimm_type": "DDR4", "dimm_speed": "2667 MHz"]]]), "DDR4 2667 MHz")
        XCTAssertNil(SystemMemory.parseType([:]))
    }

    func testLiveSystemFacts() async {
        let m = await SystemMemory.detailed()
        XCTAssertGreaterThan(m.totalMB, 1024)
        XCTAssertGreaterThan(m.availableMB, 0)
        XCTAssertFalse(m.chip.isEmpty)
    }
}
