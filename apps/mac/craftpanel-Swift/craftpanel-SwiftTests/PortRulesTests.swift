import XCTest
@testable import craftpanel_Swift

final class PortRulesTests: XCTestCase {
    func testBuiltInPresets() {
        let byID = Dictionary(uniqueKeysWithValues: PortRules.builtIn.map { ($0.id, $0) })
        XCTAssertEqual(byID["minecraft-java"]?.rules, [PortRule(proto: .tcp, port: 25565, label: "Game")])
        XCTAssertTrue(byID["minecraft-bedrock"]!.rules.allSatisfy { $0.proto == .both })   // 26.60: TCP sign-in + UDP game
        XCTAssertEqual(byID["minecraft-geyser"]?.rules.map(\.proto), [.tcp, .both])
        XCTAssertEqual(byID["fivem"]?.rules.first?.port, 30120)
        XCTAssertTrue(byID["custom"]!.rules.isEmpty)
        XCTAssertEqual(PortRules.builtIn.count, Set(PortRules.builtIn.map(\.id)).count)
    }

    func testBothExpandsToTcpAndUdp() {
        let e = PortRules.expand([PortRule(proto: .both, port: 30120)])
        XCTAssertEqual(e.map { "\($0.proto.rawValue)\($0.port)" }, ["tcp30120", "udp30120"])
    }

    func testValidationCatchesBadAndRepeatedPorts() {
        let bad = PortRules.validate([PortRule(proto: .tcp, port: 0), PortRule(proto: .udp, port: 70000)])
        XCTAssertEqual(bad.filter { $0.level == .error }.count, 2)
        let dup = PortRules.validate([PortRule(proto: .tcp, port: 25565), PortRule(proto: .both, port: 25565)])
        XCTAssertTrue(dup.contains { $0.level == .error && $0.message.contains("TCP 25565") })
        XCTAssertFalse(PortRules.validate([PortRule(proto: .tcp, port: 25565), PortRule(proto: .udp, port: 25565)]).contains { $0.level == .error })
    }

    func testAdminPortsGetASecurityWarning() {
        let w = PortRules.validate([PortRule(proto: .tcp, port: 25575)])
        XCTAssertEqual(w.count, 1); XCTAssertEqual(w[0].level, .warning); XCTAssertTrue(w[0].message.contains("RCON"))
        XCTAssertTrue(PortRules.validate([PortRule(proto: .tcp, port: 25565)]).isEmpty)
    }

    func testConflictsFlagOtherServersAndBusyPorts() {
        let rules = [PortRule(proto: .both, port: 30120), PortRule(proto: .tcp, port: 25565)]
        let c = PortRules.findConflicts(rules, portsOfOtherServers: [25565]) { proto, port in !(proto == .udp && port == 30120) }
        XCTAssertEqual(c.count, 2)
        XCTAssertTrue(c.contains { $0.message.contains("Another OMNIServers server") && $0.message.contains("25565") })
        XCTAssertTrue(c.contains { $0.message.contains("UDP 30120") && $0.message.contains("another program") })
    }

    func testRealPortCheckSeesABusyPort() {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = INADDR_ANY
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: addr.sin_port))
        Darwin.listen(fd, 1)
        XCTAssertFalse(PortRules.portFree(.tcp, port))
    }

    func testCustomPresetsRoundTrip() {
        let f = FileManager.default.temporaryDirectory.appending(path: "omni-presets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: f) }
        XCTAssertTrue(PortRules.loadSaved(f).isEmpty)
        PortRules.save(f, PortRules.builtIn + [PortPreset(id: "mine", name: "My lobby", note: "", rules: [PortRule(proto: .udp, port: 4000, label: "Voice")], builtIn: false)])
        let back = PortRules.loadSaved(f)
        XCTAssertEqual(back.count, 1); XCTAssertEqual(back[0].name, "My lobby"); XCTAssertEqual(back[0].rules[0].proto, .udp)
        try? "{not json".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertTrue(PortRules.loadSaved(f).isEmpty)
    }
}
