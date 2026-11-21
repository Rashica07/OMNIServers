import XCTest
@testable import craftpanel_Swift

final class PropertiesTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func dirWith(_ contents: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-props-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! contents.write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d
    }

    func testReadsValuesIncludingEscapedColon() {
        let d = dirWith("#head\nlevel-type=minecraft\\:normal\nserver-port=25565\nmotd=Hi there\n")
        let p = Properties.load(dir: d)
        XCTAssertEqual(p.get("level-type"), "minecraft:normal")
        XCTAssertEqual(p.get("server-port"), "25565")
        XCTAssertEqual(p.get("motd"), "Hi there")
        XCTAssertNil(p.get("nope"))
    }

    /// Direct port of `set_only_touches_its_own_line` — the hard
    /// constraint this whole file exists to uphold: an untouched key's
    /// line stays byte-identical, only the actually-changed key's line
    /// is rewritten, a genuinely new key gets appended.
    func testSetOnlyTouchesItsOwnLine() {
        let original = "#Minecraft server properties\n#Sat Aug 29\nenable-rcon=false\nonline-mode=false\nmotd=A Minecraft Server\n"
        let d = dirWith(original)
        var p = Properties.load(dir: d)

        XCTAssertTrue(p.set("enable-rcon", "true"))
        XCTAssertFalse(p.set("online-mode", "false")) // unchanged -> no-op
        XCTAssertTrue(p.set("rcon.password", "abc123")) // new key -> appended

        let out = p.render()
        XCTAssertTrue(out.contains("#Minecraft server properties\n#Sat Aug 29\n"))
        XCTAssertTrue(out.contains("enable-rcon=true\n"))
        XCTAssertTrue(out.contains("online-mode=false\n"))
        XCTAssertTrue(out.contains("motd=A Minecraft Server\n"))
        XCTAssertTrue(out.trimmingCharacters(in: .newlines).hasSuffix("rcon.password=abc123"))
        // online-mode line is byte-identical to the original
        XCTAssertTrue(out.contains("\nonline-mode=false\n"))
    }

    func testHandlesMissingFile() {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-props-missing-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        var p = Properties.load(dir: d)
        XCTAssertFalse(p.existed)
        p.set("enable-rcon", "true")
        XCTAssertEqual(p.render(), "enable-rcon=true\n")
    }

    func testEntriesReturnsFileOrderLastWinsOnDuplicates() {
        let d = dirWith("a=1\nb=2\na=3\n")
        let p = Properties.load(dir: d)
        let entries = p.entries()
        XCTAssertEqual(entries.map(\.0), ["a", "b"])
        XCTAssertEqual(p.get("a"), "3")
    }
}
