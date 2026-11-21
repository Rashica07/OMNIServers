import XCTest
import CryptoKit
@testable import craftpanel_Swift

/// Bedrock 26.60 (NetherNet): TCP sign-in + UDP game. Mirrors BedrockNetworkTests.cs on Windows/Linux.
final class BedrockNetworkTests: XCTestCase {
    private var dirs: [URL] = []
    private let jar = Data((0..<150_000).map { UInt8(truncatingIfNeeded: $0 &* 11) })

    override func tearDown() {
        for d in dirs { try? FileManager.default.removeItem(at: d) }
        dirs = []
        CrossplayManager.fetch = { try await URLSession.shared.data(for: $0).0 }
        super.tearDown()
    }

    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-nn-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        dirs.append(d); return d
    }

    private func write(_ d: URL, _ rel: String, _ text: String = "x") {
        let f = d.appending(path: rel)
        try! FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: f, atomically: true, encoding: .utf8)
    }

    private func serve(build: Int, sha: String? = nil, geyserDownloadFails: Bool = false) {
        let jar = self.jar
        let digest = sha ?? SHA256.hash(data: jar).map { String(format: "%02x", $0) }.joined()
        CrossplayManager.fetch = { request in
            let path = request.url!.path
            let project = path.contains("/floodgate/") ? "floodgate" : "geyser"
            if path.hasSuffix("/builds/latest") {
                return Data(#"{"version":"2.12.1","build":\#(build),"downloads":{"spigot":{"name":"\#(project)-Spigot.jar","sha256":"\#(digest)"}}}"#.utf8)
            }
            if path.contains("/downloads/") {
                if geyserDownloadFails && project == "geyser" { throw URLError(.badServerResponse) }
                return jar
            }
            throw URLError(.fileDoesNotExist)
        }
    }

    // MARK: launch flag

    func testGeyserGetsTheNetherNetFlag() {
        XCTAssertEqual(BedrockNetwork.withGeyserFlags(nil, geyserInstalled: true, configTransport: nil), "-DgeyserTransport=nethernet")
        XCTAssertEqual(BedrockNetwork.withGeyserFlags("  -Xmx4G ", geyserInstalled: true, configTransport: "raknet"), "-Xmx4G -DgeyserTransport=nethernet")
    }

    func testNoGeyserLeavesArgsAlone() {
        XCTAssertNil(BedrockNetwork.withGeyserFlags(nil, geyserInstalled: false, configTransport: nil))
        XCTAssertEqual(BedrockNetwork.withGeyserFlags("-Xmx2G", geyserInstalled: false, configTransport: nil), "-Xmx2G")
    }

    func testUserChoiceWins() {
        for t in ["both", "NetherNet", " both "] {
            XCTAssertEqual(BedrockNetwork.withGeyserFlags("-Xmx1G", geyserInstalled: true, configTransport: t), "-Xmx1G")
        }
        XCTAssertEqual(BedrockNetwork.withGeyserFlags("-DgeyserTransport=both", geyserInstalled: true, configTransport: nil), "-DgeyserTransport=both")
    }

    func testLaunchArgsFromServerDir() {
        let d = tempDir()
        XCTAssertEqual(CrossplayManager.launchJvmArgs(serverDir: d, serverType: .paper, userArgs: "-Xmx2G"), "-Xmx2G")
        write(d, "plugins/Geyser-Spigot.jar")
        XCTAssertEqual(CrossplayManager.launchJvmArgs(serverDir: d, serverType: .paper, userArgs: "-Xmx2G"), "-Xmx2G -DgeyserTransport=nethernet")
        XCTAssertEqual(CrossplayManager.launchJvmArgs(serverDir: d, serverType: .paper, userArgs: nil), "-DgeyserTransport=nethernet")
        XCTAssertEqual(CrossplayManager.launchJvmArgs(serverDir: d, serverType: .vanilla, userArgs: "-Xmx1G"), "-Xmx1G")
        write(d, "plugins/Geyser-Spigot/config.yml", "bedrock:\n  transport: both\n")
        XCTAssertEqual(CrossplayManager.launchJvmArgs(serverDir: d, serverType: .paper, userArgs: "-Xmx1G"), "-Xmx1G")
    }

    // MARK: build tracking

    func testNeedsUpdateRules() {
        XCTAssertTrue(BedrockNetwork.geyserNeedsUpdate(geyserInstalled: true, installedBuild: nil))
        XCTAssertTrue(BedrockNetwork.geyserNeedsUpdate(geyserInstalled: true, installedBuild: 1272))
        XCTAssertFalse(BedrockNetwork.geyserNeedsUpdate(geyserInstalled: true, installedBuild: 1273))
        XCTAssertFalse(BedrockNetwork.geyserNeedsUpdate(geyserInstalled: false, installedBuild: nil))
    }

    func testParseBuildJSON() {
        let ok = BedrockNetwork.parseGeyserBuild(["build": 1273, "version": "2.12.1"])
        XCTAssertEqual(ok?.build, 1273); XCTAssertEqual(ok?.version, "2.12.1")
        XCTAssertNil(BedrockNetwork.parseGeyserBuild(["build": "x", "version": "2.12.1"]))
        XCTAssertNil(BedrockNetwork.parseGeyserBuild(["version": "2.12.1"]))
        XCTAssertNil(BedrockNetwork.parseGeyserBuild(nil))
    }

    func testOldGeyserWithNoRecordNeedsUpdate() {
        let d = tempDir(); write(d, "plugins/Geyser-Spigot.jar")
        let s = CrossplayManager.status(serverDir: d, serverType: .paper)
        XCTAssertTrue(s.geyser); XCTAssertNil(s.geyserBuild); XCTAssertTrue(s.needsUpdate)
    }

    func testNoGeyserIgnoresStaleRecord() {
        let d = tempDir(); write(d, ".craftpanel-geyser.json", #"{"build":5,"version":"1"}"#)
        let s = CrossplayManager.status(serverDir: d, serverType: .paper)
        XCTAssertFalse(s.geyser); XCTAssertNil(s.geyserBuild); XCTAssertFalse(s.needsUpdate)
    }

    func testEnableRecordsTheBuild() async throws {
        serve(build: 1280)
        let d = tempDir()
        let s = try await CrossplayManager.enable(serverDir: d, serverType: .paper)
        XCTAssertEqual(s.geyserBuild, 1280); XCTAssertFalse(s.needsUpdate)
        XCTAssertEqual(CrossplayManager.installedBuild(d), 1280)
        XCTAssertTrue(s.floodgate)
    }

    func testChecksumMismatchInstallsNothing() async {
        serve(build: 1280, sha: String(repeating: "0", count: 64))
        let d = tempDir()
        do { _ = try await CrossplayManager.enable(serverDir: d, serverType: .paper); XCTFail("should throw") }
        catch { XCTAssertTrue(error.localizedDescription.contains("checksum"), error.localizedDescription) }
        XCTAssertFalse(CrossplayManager.status(serverDir: d, serverType: .paper).geyser)
        XCTAssertNil(CrossplayManager.installedBuild(d))
    }

    func testUpdateReplacesOldJarAndKeepsOthers() async throws {
        serve(build: 1290)
        let d = tempDir()
        write(d, "plugins/Geyser-Spigot.jar", "old geyser"); write(d, "plugins/floodgate-spigot.jar", "fg"); write(d, "plugins/EssentialsX.jar", "x")
        let s = try await CrossplayManager.updateGeyser(serverDir: d, serverType: .paper)
        XCTAssertEqual(s.geyserBuild, 1290); XCTAssertFalse(s.needsUpdate)
        XCTAssertEqual(try Data(contentsOf: d.appending(path: "plugins/Geyser-Spigot.jar")), jar)
        let names = try FileManager.default.contentsOfDirectory(atPath: d.appending(path: "plugins").path)
        XCTAssertEqual(names.filter { $0.lowercased().contains("geyser") && $0.hasSuffix(".jar") }.count, 1)
        XCTAssertTrue(names.contains("floodgate-spigot.jar")); XCTAssertTrue(names.contains("EssentialsX.jar"))
        let trash = FileManager.default.enumerator(atPath: d.appending(path: ".craftpanel-trash").path)?.allObjects as? [String] ?? []
        XCTAssertTrue(trash.contains { (try? String(contentsOf: d.appending(path: ".craftpanel-trash/\($0)"), encoding: .utf8)) == "old geyser" })
    }

    func testFailedUpdateKeepsOldGeyser() async throws {
        serve(build: 1290, geyserDownloadFails: true)
        let d = tempDir(); write(d, "plugins/Geyser-Spigot.jar", "old geyser")
        do { _ = try await CrossplayManager.updateGeyser(serverDir: d, serverType: .paper); XCTFail("should throw") } catch {}
        XCTAssertEqual(try String(contentsOf: d.appending(path: "plugins/Geyser-Spigot.jar"), encoding: .utf8), "old geyser")
        XCTAssertNil(CrossplayManager.installedBuild(d))
    }

    func testUpdateRefusedForVanilla() async {
        do { _ = try await CrossplayManager.updateGeyser(serverDir: tempDir(), serverType: .vanilla); XCTFail("should throw") } catch {}
    }

    func testDisableForgetsBuild() async throws {
        serve(build: 1290)
        let d = tempDir()
        _ = try await CrossplayManager.enable(serverDir: d, serverType: .paper)
        CrossplayManager.disable(serverDir: d, serverType: .paper)
        XCTAssertNil(CrossplayManager.installedBuild(d))
    }

    // MARK: config reading

    func testBedrockSectionOnlyReadsItsOwnKeys() {
        let yml = "java:\n  port: 25565\n  transport: raknet\nbedrock:\n  address: 0.0.0.0\n  port: 19133\n  transport: both\n  clone-remote-port: true\n  signaling:\n    mode: builtin\n    port: 9999\n\nmotd:\n  port: 1\n"
        let r = BedrockNetwork.readBedrockSection(yml.components(separatedBy: "\n"))
        XCTAssertEqual(r.port, 19133); XCTAssertEqual(r.transport, "both"); XCTAssertTrue(r.clone)
    }

    func testNestedBlocksDontLeak() {
        let r = BedrockNetwork.readBedrockSection("bedrock:\n  signaling:\n    port: 9999\n    transport: x\n    clone-remote-port: true\n".components(separatedBy: "\n"))
        XCTAssertNil(r.port); XCTAssertNil(r.transport); XCTAssertFalse(r.clone)
    }

    func testCloneRemotePortReportedInStatus() {
        let d = tempDir(); write(d, "plugins/Geyser-Spigot.jar"); write(d, "plugins/Geyser-Spigot/config.yml", "bedrock:\n  port: 19133\n  clone-remote-port: true\n")
        let s = CrossplayManager.status(serverDir: d, serverType: .paper)
        XCTAssertTrue(s.cloneRemotePort); XCTAssertEqual(s.bedrockPort, 19133)
    }

    // MARK: rules & addresses

    func testGeyserNeedsOnePortOnBothProtocols() {
        XCTAssertEqual(BedrockNetwork.geyserRules(bedrockPort: 19133).map { "\($0.proto.rawValue)\($0.port)" }, ["both19133"])
    }

    func testDefaultGeyserRulesAddTheJavaPort() {
        let d = tempDir()
        XCTAssertNil(BedrockNetwork.defaultGeyserRules(serverDir: d, serverType: .paper))
        write(d, "server.properties", "server-port=25570\n"); write(d, "plugins/Geyser-Spigot.jar"); write(d, "plugins/Geyser-Spigot/config.yml", "bedrock:\n  port: 19133\n")
        let r = BedrockNetwork.defaultGeyserRules(serverDir: d, serverType: .paper)!
        XCTAssertEqual(r.map { "\($0.proto.rawValue)\($0.port)" }, ["tcp25570", "both19133"])
    }

    func testDescribeReadsLikeAPerson() {
        XCTAssertEqual(BedrockNetwork.describe(BedrockNetwork.geyserRules(bedrockPort: 19132)), "TCP 19132 and UDP 19132")
        XCTAssertEqual(BedrockNetwork.describe([PortRule(proto: .tcp, port: 25565)] + BedrockNetwork.geyserRules(bedrockPort: 19132)), "TCP 25565, TCP 19132 and UDP 19132")
        XCTAssertEqual(BedrockNetwork.describe([PortRule(proto: .tcp, port: 25565)]), "TCP 25565")
        XCTAssertEqual(BedrockNetwork.describe([]), "no ports")
    }

    func testBedrockAddressNeverUsesTheJavaPortOrTheTunnel() {
        XCTAssertEqual(BedrockNetwork.bedrockAddress(publicIP: "203.0.113.9", lanIP: "192.168.1.5", port: 19132), "203.0.113.9:19132")
        XCTAssertEqual(BedrockNetwork.bedrockAddress(publicIP: "203.0.113.9:25565", lanIP: "192.168.1.5", port: 19133), "203.0.113.9:19133")
        XCTAssertEqual(BedrockNetwork.bedrockAddress(publicIP: "", lanIP: "192.168.1.5", port: 19132), "192.168.1.5:19132")
        XCTAssertEqual(BedrockNetwork.bedrockAddress(publicIP: nil, lanIP: " 192.168.1.5 ", port: 19132), "192.168.1.5:19132")
        XCTAssertEqual(BedrockNetwork.bedrockAddress(publicIP: nil, lanIP: nil, port: 19132), "")
    }

    func testSchoolRequestNamesBothProtocols() {
        XCTAssertTrue(NetworkInvite.schoolNetworkRequest(port: 19132, udp: true, bothProtocols: true).contains("TCP and UDP port 19132"))
        XCTAssertTrue(NetworkInvite.schoolNetworkRequest(port: 25565, udp: false).contains("TCP port 25565"))
    }
}
