import XCTest
import CryptoKit
@testable import craftpanel_Swift

final class PumpkinEngineTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-pumpkin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func testAssetNamePerPlatform() {
        XCTAssertEqual(PumpkinEngine.assetName(os: "macOS", arch: "arm64"), "pumpkin-ARM64-macOS")
        XCTAssertEqual(PumpkinEngine.assetName(os: "linux", arch: "x64"), "pumpkin-X64-Linux")
        XCTAssertEqual(PumpkinEngine.assetName(os: "windows", arch: "x64"), "pumpkin-X64-Windows.exe")
        XCTAssertNil(PumpkinEngine.assetName(os: "macOS", arch: "x64"), "no Intel Mac build exists")
    }

    func testDownloadURLEncodesThePlusInTheTag() {
        XCTAssertEqual(PumpkinEngine.downloadURL(tag: "0.2.2+26.3-26.60", file: "pumpkin-ARM64-macOS")?.absoluteString,
                       "https://github.com/Pumpkin-MC/Pumpkin/releases/download/0.2.2%2B26.3-26.60/pumpkin-ARM64-macOS")
    }

    func testParseChecksumsReadsTheRealFileFormatAndSkipsJunk() {
        let h = String(repeating: "ab", count: 32)
        let text = "\(h)  pumpkin-ARM64-macOS\nnot a checksum line\nshort  file\n\(h.uppercased())  other\n"
        let sums = PumpkinEngine.parseChecksums(text)
        XCTAssertEqual(sums["pumpkin-ARM64-macOS"], h)
        XCTAssertEqual(sums["other"], h, "hex is lower-cased")
        XCTAssertEqual(sums.count, 2)
    }

    func testPlaceInstallsAVerifiedFileAsExecutable() throws {
        let root = tempDir(), src = tempDir().appending(path: "dl")
        let data = Data("fake engine".utf8)
        try data.write(to: src)
        let placed = try PumpkinEngine.place(downloaded: src, expectedSHA256: sha(data), tag: "9.9.9", root: root)
        XCTAssertEqual(placed.path, PumpkinEngine.binaryURL(tag: "9.9.9", root: root).path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: placed.path))
        XCTAssertEqual(try Data(contentsOf: placed), data)
    }

    func testPlaceRefusesAWrongChecksumAndInstallsNothing() throws {
        let root = tempDir(), src = tempDir().appending(path: "dl")
        try Data("tampered".utf8).write(to: src)
        XCTAssertThrowsError(try PumpkinEngine.place(downloaded: src, expectedSHA256: sha(Data("original".utf8)), tag: "9.9.9", root: root))
        XCTAssertNil(PumpkinEngine.installedBinary(root: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: PumpkinEngine.binaryURL(tag: "9.9.9", root: root).path))
    }

    func testInstalledBinaryPrefersPinnedThenNewest() throws {
        let root = tempDir(), src = tempDir().appending(path: "dl")
        let data = Data("x".utf8); try data.write(to: src)
        XCTAssertNil(PumpkinEngine.installedBinary(root: root))
        _ = try PumpkinEngine.place(downloaded: src, expectedSHA256: sha(data), tag: "0.1.0", root: root)
        _ = try PumpkinEngine.place(downloaded: src, expectedSHA256: sha(data), tag: "0.3.0", root: root)
        XCTAssertTrue(PumpkinEngine.installedBinary(root: root)!.path.contains("/0.3.0/"))
        _ = try PumpkinEngine.place(downloaded: src, expectedSHA256: sha(data), tag: PumpkinEngine.pinnedTag, root: root)
        XCTAssertTrue(PumpkinEngine.installedBinary(root: root)!.path.contains(PumpkinEngine.pinnedTag))
    }
}

final class PumpkinConfigTests: XCTestCase {
    private let base = PumpkinConfig.Settings(motd: "Kiqa's world", port: 25601, maxPlayers: 6,
                                              gamemode: "creative", difficulty: "easy", seed: "")

    func testRenderWritesTheSettingsAndTurnsTelemetryAndBedrockOff() {
        let t = PumpkinConfig.render(base)
        XCTAssertTrue(t.contains("default_gamemode = \"Creative\""))
        XCTAssertTrue(t.contains("default_difficulty = \"Easy\""))
        XCTAssertTrue(t.contains("[telemetry]\nenabled = false"))
        XCTAssertTrue(t.contains("[networking.bedrock]\nenabled = false"))
        XCTAssertTrue(t.contains("address = \"0.0.0.0:25601\""))
        XCTAssertTrue(t.contains("online_mode = true"))
        XCTAssertTrue(t.contains("max_players = 6"))
        XCTAssertTrue(t.contains("motd = \"Kiqa's world\""))
        XCTAssertFalse(t.contains("seed"), "blank seed means random")
    }

    func testSeedIsWrittenWhenGiven() {
        var s = base; s.seed = " 12345 "
        XCTAssertTrue(PumpkinConfig.render(s).hasPrefix("seed = \"12345\""))
    }

    func testMotdIsEscapedSoTheFileStaysValid() {
        var s = base; s.motd = "Say \"hi\" \\ there\nsecond line"
        XCTAssertTrue(PumpkinConfig.render(s).contains("motd = \"Say \\\"hi\\\" \\\\ there second line\""))
        s.motd = ""
        XCTAssertTrue(PumpkinConfig.render(s).contains("motd = \"A Minecraft Server\""))
    }

    func testMaxPlayersIsClamped() {
        var s = base; s.maxPlayers = 0
        XCTAssertTrue(PumpkinConfig.render(s).contains("max_players = 1\n"))
        s.maxPlayers = 99999
        XCTAssertTrue(PumpkinConfig.render(s).contains("max_players = 1000\n"))
    }

    func testPortRoundTripsAndIgnoresOtherSections() {
        XCTAssertEqual(PumpkinConfig.javaPort(in: PumpkinConfig.render(base)), 25601)
        let toml = "[networking.query]\naddress = \"0.0.0.0:1111\"\n\n[networking.java]\nenabled = true\naddress = \"0.0.0.0:25577\"\n"
        XCTAssertEqual(PumpkinConfig.javaPort(in: toml), 25577)
        XCTAssertNil(PumpkinConfig.javaPort(in: "[networking.query]\naddress = \"0.0.0.0:1111\"\n"))
        XCTAssertNil(PumpkinConfig.javaPort(in: "[networking.java]\naddress = \"0.0.0.0:0\"\n"))
    }

    func testNetworkInfoReadsThePumpkinPort() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-pk-port-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(NetworkInfo.port(serverDir: dir), 25565)
        try PumpkinConfig.render(base).write(to: dir.appending(path: "pumpkin.toml"), atomically: true, encoding: .utf8)
        XCTAssertEqual(NetworkInfo.port(serverDir: dir), 25601)
    }
}
