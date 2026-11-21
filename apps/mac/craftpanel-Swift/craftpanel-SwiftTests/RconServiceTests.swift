import XCTest
@testable import craftpanel_Swift

final class RconServiceTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeRecord(propertiesContents: String?) -> ServerRecord {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-rconsvc-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        if let propertiesContents {
            try! propertiesContents.write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        }
        return ServerRecord(
            name: "test", path: d.path, serverType: .vanilla, launchTarget: "server.jar",
            mcVersion: nil, javaPath: "java", ramMB: 1024
        )
    }

    func testEndpointErrorsWhenNoPropertiesFile() async {
        let rec = makeRecord(propertiesContents: nil)
        do {
            _ = try await RconService.shared.endpoint(for: rec)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("start it once"))
        }
    }

    func testEndpointErrorsWhenRconDisabled() async {
        let rec = makeRecord(propertiesContents: "enable-rcon=false\n")
        do {
            _ = try await RconService.shared.endpoint(for: rec)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("isn't enabled"))
        }
    }

    func testEndpointErrorsWhenPasswordBlank() async {
        let rec = makeRecord(propertiesContents: "enable-rcon=true\nrcon.port=25575\n")
        do {
            _ = try await RconService.shared.endpoint(for: rec)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("blank"))
        }
    }

    func testEndpointResolvesWhenFullyConfigured() async throws {
        let rec = makeRecord(propertiesContents: "enable-rcon=true\nrcon.port=25575\nrcon.password=hunter2\n")
        let (port, password) = try await RconService.shared.endpoint(for: rec)
        XCTAssertEqual(port, 25575)
        XCTAssertEqual(password, "hunter2")
    }

    /// Mirrors the Rust `rcon_setup` behavior: only ever writes the four
    /// RCON keys, generates a port/password when missing, and is
    /// idempotent (a second call changes nothing already correct).
    func testSetupOnlyWritesRconKeysAndIsIdempotent() async throws {
        let rec = makeRecord(propertiesContents: "online-mode=false\nmotd=Hello\n")
        let result = try await RconService.shared.setup(for: rec, isRunning: false)
        XCTAssertTrue(result.changed.contains("enable-rcon=true"))
        XCTAssertTrue(result.changed.contains(where: { $0.hasPrefix("rcon.port=") }))
        XCTAssertTrue(result.changed.contains(where: { $0.hasPrefix("rcon.password=") }))
        XCTAssertFalse(result.restartRequired)

        let settings = await RconService.shared.settings(for: rec)
        XCTAssertTrue(settings.enabled)
        XCTAssertTrue(settings.hasPassword)

        // online-mode / motd must be untouched
        let props = Properties.load(dir: URL(fileURLWithPath: rec.path))
        XCTAssertEqual(props.get("online-mode"), "false")
        XCTAssertEqual(props.get("motd"), "Hello")

        // second call: already fully set up, nothing changes
        let second = try await RconService.shared.setup(for: rec, isRunning: true)
        XCTAssertTrue(second.changed.isEmpty)
        XCTAssertTrue(second.restartRequired)
    }

    func testSetupRequiresAnExistingPropertiesFile() async {
        let rec = makeRecord(propertiesContents: nil)
        do {
            _ = try await RconService.shared.setup(for: rec, isRunning: false)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Start the server"))
        }
    }

    /// A stopping server waits for its RCON clients to hang up; ours must close at once and not reconnect.
    func testShuttingDownRefusesRconUntilItIsCleared() async {
        let svc = RconService()
        let rec = makeRecord(propertiesContents: "enable-rcon=true\nrcon.port=1\nrcon.password=pw\n")
        var idle = await svc.isShuttingDown(rec.id)
        XCTAssertFalse(idle)

        await svc.beginShutdown(rec.id)
        let during = await svc.isShuttingDown(rec.id)
        XCTAssertTrue(during)
        do {
            _ = try await svc.run(record: rec, command: "list")
            XCTFail("expected a refusal while shutting down")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("shutting down"), "got: \(error.localizedDescription)")
        }

        await svc.endShutdown(rec.id)            // a restart lets RCON back in: the failure is now a normal connection error
        idle = await svc.isShuttingDown(rec.id)
        XCTAssertFalse(idle)
        do { _ = try await svc.run(record: rec, command: "list") }
        catch { XCTAssertFalse(error.localizedDescription.contains("shutting down")) }
    }
}
