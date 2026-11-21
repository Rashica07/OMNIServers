import XCTest
@testable import craftpanel_Swift

/// Direct port of `crossplay.rs`'s own `#[cfg(test)]` module, mirrored
/// test-by-test.
final class CrossplayManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-xp-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testPlatformAndFolder() {
        XCTAssertEqual(CrossplayManager.platform(.paper), "spigot")
        XCTAssertEqual(CrossplayManager.platform(.fabric), "fabric")
        XCTAssertNil(CrossplayManager.platform(.vanilla))
        XCTAssertEqual(CrossplayManager.folder(.paper), "plugins")
        XCTAssertEqual(CrossplayManager.folder(.fabric), "mods")
    }

    func testStatusDetectsJarsAndReadsPort() throws {
        let d = makeTempDir()
        let plugins = d.appending(path: "plugins")
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 200).write(to: plugins.appending(path: "Geyser-Spigot.jar"))
        let cfgDir = plugins.appending(path: "Geyser-Spigot")
        try FileManager.default.createDirectory(at: cfgDir, withIntermediateDirectories: true)
        try "bedrock:\n  address: 0.0.0.0\n  port: 19144\n".write(
            to: cfgDir.appending(path: "config.yml"), atomically: true, encoding: .utf8
        )

        let s = CrossplayManager.status(serverDir: d, serverType: .paper)
        XCTAssertTrue(s.compatible && s.geyser && !s.floodgate)
        XCTAssertEqual(s.bedrockPort, 19144)
    }
}
