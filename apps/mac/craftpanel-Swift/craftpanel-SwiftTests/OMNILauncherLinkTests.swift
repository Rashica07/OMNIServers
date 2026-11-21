import XCTest
@testable import craftpanel_Swift

final class OMNILauncherLinkTests: XCTestCase {
    func testFindsLauncherInApplications() {
        let url = OMNILauncherLink.installedURL(fileExists: { $0 == "/Applications/OMNI Launcher.app" }, home: "/Users/x")
        XCTAssertEqual(url?.path, "/Applications/OMNI Launcher.app")
    }
    func testFindsLauncherInUserApplications() {
        let url = OMNILauncherLink.installedURL(fileExists: { $0 == "/Users/x/Applications/OMNI Launcher.app" }, home: "/Users/x")
        XCTAssertEqual(url?.path, "/Users/x/Applications/OMNI Launcher.app")
    }
    func testNilWhenNotInstalled() {
        XCTAssertNil(OMNILauncherLink.installedURL(fileExists: { _ in false }, home: "/Users/x"))
    }

    func testRequestUsesTheLaunchersJSONKeys() throws {
        let r = OMNILauncherLink.JoinRequest(name: "Survival", address: "localhost:25565", publicAddress: "play.example.gg:25565", minecraft: "1.21.4", created: 1000)
        let json = String(data: try OMNILauncherLink.encode(r), encoding: .utf8)!
        XCTAssertEqual(json, #"{"address":"localhost:25565","created":1000,"minecraft":"1.21.4","name":"Survival","public_address":"play.example.gg:25565"}"#)
    }
    func testRequestWithoutPublicAddressOmitsIt() throws {
        let r = OMNILauncherLink.JoinRequest(name: "S", address: "a:1", publicAddress: nil, minecraft: "1.21.4", created: 1)
        XCTAssertFalse(String(data: try OMNILauncherLink.encode(r), encoding: .utf8)!.contains("public_address"))
    }
    func testRequestLivesInTheLaunchersDataFolder() {
        XCTAssertEqual(OMNILauncherLink.requestURL(home: "/Users/x").path, "/Users/x/Library/Application Support/omni-launcher/join-request.json")
    }
    func testWriteCreatesTheFolderAndTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("omni-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data/join-request.json")
        let r = OMNILauncherLink.JoinRequest(name: "S", address: "a:1", publicAddress: nil, minecraft: "1.21.4", created: 5)
        try OMNILauncherLink.write(r, to: url)
        XCTAssertEqual(try JSONDecoder().decode(OMNILauncherLink.JoinRequest.self, from: Data(contentsOf: url)), r)
    }
    func testPlayNeedsTheLauncherAndAVersion() {
        XCTAssertTrue(OMNILauncherLink.canPlay(minecraft: "1.21.4", installed: true))
        XCTAssertFalse(OMNILauncherLink.canPlay(minecraft: "1.21.4", installed: false))
        XCTAssertFalse(OMNILauncherLink.canPlay(minecraft: nil, installed: true))
        XCTAssertFalse(OMNILauncherLink.canPlay(minecraft: "  ", installed: true))
    }
}

final class OMNILauncherLinkDevTests: XCTestCase {
    private func home(dev: Bool) throws -> String {
        let h = FileManager.default.temporaryDirectory.appendingPathComponent("omni-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: h, withIntermediateDirectories: true)
        if dev { try FileManager.default.createDirectory(at: h.appendingPathComponent(".omni-launcher-dev"), withIntermediateDirectories: true) }
        return h.path
    }
    private let req = OMNILauncherLink.JoinRequest(name: "S", address: "localhost:25565", publicAddress: nil, minecraft: "26.3", created: 1)

    func testRequestAlsoGoesToTheDevLauncherFolderWhenItExists() throws {
        let h = try home(dev: true)
        try OMNILauncherLink.writeEverywhere(req, urls: OMNILauncherLink.requestURLs(home: h))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h + "/Library/Application Support/omni-launcher/join-request.json"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: h + "/.omni-launcher-dev/join-request.json"))
    }
    func testNoDevFolderMeansOnlyTheInstalledLocation() throws {
        let h = try home(dev: false)
        XCTAssertEqual(OMNILauncherLink.requestURLs(home: h).count, 1)
    }
    func testAGameRunningLauncherCountsAsPlayable() {
        XCTAssertTrue(OMNILauncherLink.canPlay(minecraft: "26.3", installed: true))
        XCTAssertFalse(OMNILauncherLink.canPlay(minecraft: "", installed: true))
    }
}

final class ServerSessionEngineTests: XCTestCase {
    func testTheOMNIHostEngineIsRecognisedAsAServerProcess() {
        // This very test process isn't a server; a pid that doesn't exist isn't alive.
        XCTAssertFalse(ServerSession.serverAlive(pid: 999_999))
        XCTAssertFalse(ServerSession.serverAlive(pid: getpid()))
    }
}
