import XCTest
@testable import craftpanel_Swift

final class MinecraftAdapterTests: XCTestCase {
    func makeTempDir(_ name: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-test-\(name)-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: d)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func write(_ url: URL, _ content: String = "") {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testFabricWinsOverBundledVanillaJar() {
        // modern Fabric: versioned launcher jar + the vanilla server.jar
        // it wraps, and NO fabric-server-launch.jar — must not be misread
        // as Vanilla. This is the single most load-bearing test in the
        // whole detector.
        let d = makeTempDir("fabric-modern")
        write(d.appending(path: "fabric-server-mc.1.21.1-loader.0.16.5-launcher.1.0.1.jar"))
        write(d.appending(path: "server.jar"))

        let got = MinecraftAdapter.inspect(at: d)
        XCTAssertEqual(got?.serverType, .fabric)
        XCTAssertTrue(got?.launchTarget.hasPrefix("fabric-server-mc") ?? false)
        XCTAssertEqual(got?.mcVersion, "1.21.1")
    }

    func testFabricDetectedFromSideMarkersOnly() {
        let d = makeTempDir("fabric-markers")
        try! FileManager.default.createDirectory(at: d.appending(path: ".fabric"), withIntermediateDirectories: true)
        write(d.appending(path: "fabric-server-launcher.properties"), "serverJar=server.jar")
        write(d.appending(path: "server.jar"))

        let got = MinecraftAdapter.inspect(at: d)
        XCTAssertEqual(got?.serverType, .fabric)
    }

    func testVersionFromVersionsDirNewScheme() {
        let d = makeTempDir("fabric-newver")
        write(d.appending(path: "fabric-server-launch.jar"))
        try! FileManager.default.createDirectory(
            at: d.appending(path: "versions/26.2"), withIntermediateDirectories: true)
        write(d.appending(path: "versions/26.2/server-26.2.jar"))

        let got = MinecraftAdapter.inspect(at: d)
        XCTAssertEqual(got?.serverType, .fabric)
        XCTAssertEqual(got?.mcVersion, "26.2")
    }

    func testVersionFromVersionsDirOldScheme() {
        let d = makeTempDir("fabric-oldver")
        write(d.appending(path: "fabric-server-launch.jar"))
        try! FileManager.default.createDirectory(
            at: d.appending(path: "versions/1.18.2"), withIntermediateDirectories: true)

        let got = MinecraftAdapter.inspect(at: d)
        XCTAssertEqual(got?.mcVersion, "1.18.2")
    }

    func testDetectsForgeByRunScript() {
        let d = makeTempDir("forge")
        write(d.appending(path: "run.sh"))
        XCTAssertEqual(MinecraftAdapter.inspect(at: d)?.serverType, .forge)
    }

    func testDetectsNeoForgeSeparatelyFromForge() {
        let d = makeTempDir("neoforge")
        write(d.appending(path: "run.sh"))
        try! FileManager.default.createDirectory(
            at: d.appending(path: "libraries/net/neoforged/neoforge/21.1.172"), withIntermediateDirectories: true)
        XCTAssertEqual(MinecraftAdapter.inspect(at: d)?.serverType, .neoforge)
        XCTAssertEqual(ModrinthClient.loaderFacet(.neoforge), "neoforge")
        XCTAssertNil(CrossplayManager.platform(.forge))
    }

    func testJavaInstallerOffersOnlyBundledMajors() {
        XCTAssertNil(JavaInstaller.offerableFeature(requiredJava: 8))
        XCTAssertEqual(JavaInstaller.offerableFeature(requiredJava: 21), 21)
        XCTAssertTrue(JavaInstaller.installDir(feature: 21).path.hasSuffix("CraftPanel/jre/21/mac-\(JavaInstaller.archName)"))
    }

    func testFindCompatibleJavaReturnsNilForImpossibleVersion() async {
        let r = await JavaProbe.findCompatibleJava(required: 99)
        XCTAssertNil(r)
    }

    func testDetectsPaperAndVersionFromHistory() {
        let d = makeTempDir("paper")
        write(d.appending(path: "paper-1.21.1-40.jar"))
        write(d.appending(path: "version_history.json"), #"{"currentVersion":"git-Paper-40 (MC: 1.21.1)"}"#)

        let got = MinecraftAdapter.inspect(at: d)
        XCTAssertEqual(got?.serverType, .paper)
        XCTAssertEqual(got?.mcVersion, "1.21.1")
    }

    func testVanillaAndEmptyFolder() {
        let d = makeTempDir("vanilla")
        write(d.appending(path: "server.jar"))
        XCTAssertEqual(MinecraftAdapter.inspect(at: d)?.serverType, .vanilla)

        let empty = makeTempDir("empty")
        XCTAssertNil(MinecraftAdapter.inspect(at: empty))
    }

    func testExtractsVersionTokensBothSchemes() {
        XCTAssertEqual(MinecraftAdapter.extractVersionToken("minecraft_server.1.20.4.jar"), "1.20.4")
        XCTAssertEqual(MinecraftAdapter.extractVersionToken("server-26.2.jar"), "26.2")
        XCTAssertEqual(MinecraftAdapter.extractVersionToken("paper-1.8.9-R0.1.jar"), "1.8.9")
        XCTAssertNil(MinecraftAdapter.extractVersionToken("paper.jar"))
        // a lone loader build number must not be mistaken for a MC version
        XCTAssertNil(MinecraftAdapter.extractVersionToken("fabric-loader-0.16.5.jar"))
        XCTAssertNil(MinecraftAdapter.extractVersionToken("something-3.4.jar"))
    }

    func testParseStatusReadsConsole() {
        let a = MinecraftAdapter()
        XCTAssertEqual(
            a.parseStatus(output: "[12:00:00] [Server thread/INFO]: Done (12.345s)! For help, type \"help\""),
            .running
        )
        XCTAssertEqual(
            a.parseStatus(output: "[12:00:00] [Server thread/INFO]: Stopping the server"),
            .stopping
        )
    }

    // MARK: - Bedrock + orchestration

    func testBedrockDetectedAsFallback() async {
        let d = makeTempDir("bedrock")
        write(d.appending(path: BedrockAdapter.binaryName))
        let result = await ServerDetector.detect(at: d, javaExecutable: "definitely-not-a-real-java-binary")
        XCTAssertTrue(result.detected)
        XCTAssertEqual(result.serverType, .bedrock)
        XCTAssertTrue(result.warnings.isEmpty, "Bedrock needs no Java — shouldn't warn about missing it")
    }

    func testNothingDetectedGivesActionableWarning() async {
        let d = makeTempDir("nothing")
        let result = await ServerDetector.detect(at: d, javaExecutable: "definitely-not-a-real-java-binary")
        XCTAssertFalse(result.detected)
        XCTAssertTrue(result.warnings.first?.contains("bedrock_server") ?? false)
    }

    func testNotAFolderIsRejected() async {
        let file = makeTempDir("parent").appending(path: "not-a-folder.txt")
        write(file, "hi")
        let result = await ServerDetector.detect(at: file, javaExecutable: "definitely-not-a-real-java-binary")
        XCTAssertFalse(result.detected)
        XCTAssertEqual(result.warnings, ["That path is not a folder."])
    }
}

final class JavaProbeTests: XCTestCase {
    func testParsesLegacyAndModernBanners() {
        XCTAssertEqual(JavaProbe.parseMajor("openjdk version \"1.8.0_361\"\n"), 8)
        XCTAssertEqual(JavaProbe.parseMajor("openjdk version \"17.0.8\" 2023-07-18\n"), 17)
        XCTAssertEqual(JavaProbe.parseMajor("java version \"21\" 2023-09-19 LTS\n"), 21)
        XCTAssertEqual(JavaProbe.parseMajor("openjdk version \"11.0.20.1\"\n"), 11)
    }

    func testMapsMCVersionsToRequiredJava() {
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.8.9"), 8)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.16.5"), 8)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.17.1"), 16)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.18.2"), 17)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.20.1"), 17)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.20.4"), 17)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.20.6"), 21)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "1.21.1"), 21)
        // the year-based scheme that replaced "1.x" starting in 2026
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "26.0"), 25)
        XCTAssertEqual(JavaProbe.requiredJava(forMC: "26.1"), 25)
    }

    func testWarnsOnlyOnRealMismatch() {
        let j17 = JavaInfo(path: "java", raw: "", major: 17, is64Bit: true)
        XCTAssertNil(JavaProbe.compatibilityWarning(java: j17, mcVersion: "1.20.1"))
        XCTAssertNotNil(JavaProbe.compatibilityWarning(java: j17, mcVersion: "1.21.1"))
        XCTAssertNil(JavaProbe.compatibilityWarning(java: j17, mcVersion: nil))
    }

    /// Hits the real `java` on this Mac if one's on PATH — confirms the
    /// stderr-not-stdout gotcha and the process-launch path actually work
    /// end to end, not just the string parsing in isolation.
    func testLiveProbeAgainstRealJavaIfInstalled() async throws {
        guard let info = await JavaProbe.probe() else {
            throw XCTSkip("no java on PATH in this environment — parsing-only tests above still cover the logic")
        }
        XCTAssertGreaterThan(info.major, 0)
        XCTAssertFalse(info.raw.isEmpty)
    }
}
