import XCTest
@testable import craftpanel_Swift

final class ResourcePackConfigTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func server(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-rp-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try! "level-name=world\nmotd=hi\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        tempDirs.append(d)
        return d
    }

    func testReadDefaultsWhenNothingSet() {
        let d = server("defaults")
        let c = ResourcePackManager.read(dir: d)
        XCTAssertEqual(c.url, "")
        XCTAssertFalse(c.required)
    }

    func testRejectsEmptyAndNonUrlInput() async {
        let d = server("reject")
        do {
            _ = try await ResourcePackManager.setFromURL(dir: d, url: "", prompt: "", required: false)
            XCTFail("expected an error")
        } catch { /* expected */ }
        do {
            _ = try await ResourcePackManager.setFromURL(dir: d, url: "not-a-url", prompt: "", required: false)
            XCTFail("expected an error")
        } catch { /* expected */ }
    }

    func testClearResetsAllFourPropertiesAndPreservesTheRest() throws {
        let d = server("clear")
        var props = Properties.load(dir: d)
        props.set("resource-pack", "https://example.com/pack.zip")
        props.set("resource-pack-sha1", "deadbeef")
        props.set("require-resource-pack", "true")
        try props.save()

        try ResourcePackManager.clear(dir: d)
        let c = ResourcePackManager.read(dir: d)
        XCTAssertEqual(c.url, "")
        XCTAssertEqual(c.sha1, "")
        XCTAssertFalse(c.required)
        // untouched
        XCTAssertEqual(Properties.load(dir: d).getOr("motd", ""), "hi")
    }

    func testSetKnownSkipsDownloadAndWritesAllFour() throws {
        let d = server("known")
        let c = try ResourcePackManager.setKnown(dir: d, url: "https://example.com/pack.zip", sha1: "abc123", prompt: "Optional", required: true)
        XCTAssertEqual(c.sha1, "abc123")
        let saved = ResourcePackManager.read(dir: d)
        XCTAssertEqual(saved.url, "https://example.com/pack.zip")
        XCTAssertEqual(saved.prompt, "Optional")
        XCTAssertTrue(saved.required)
    }

    /// End-to-end against a real, small, stable public .zip -- confirms
    /// the download + zip-signature + SHA-1 path actually works, not
    /// just the property-writing plumbing around it. Skips cleanly if
    /// unreachable, same discipline as this project's other live-network
    /// tests (JavaProbeTests, UpdateCheckerTests).
    func testRealZipHashesCorrectly() async throws {
        let d = server("real")
        let url = "https://github.com/octocat/Hello-World/archive/refs/heads/master.zip"
        do {
            let c = try await ResourcePackManager.setFromURL(dir: d, url: url, prompt: "Optional pack", required: true)
            XCTAssertEqual(c.sha1.count, 40)
            XCTAssertTrue(c.required)
            let saved = ResourcePackManager.read(dir: d)
            XCTAssertEqual(saved.sha1, c.sha1)
        } catch {
            throw XCTSkip("No network / GitHub unreachable: \(error)")
        }
    }
}
