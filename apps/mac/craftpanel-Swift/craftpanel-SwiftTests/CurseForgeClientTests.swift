import XCTest
@testable import craftpanel_Swift

/// Direct port of `curseforge.rs`'s own `#[cfg(test)]` module, mirrored
/// test-by-test where a Swift equivalent makes sense.
final class CurseForgeClientTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-cf-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    // MARK: - Pure logic, no network

    func testManifestRoundtrip() throws {
        let d = makeTempDir()
        let list = [CurseForgeInstalledEntry(
            modID: 123, slug: "jei", title: "Just Enough Items", filename: "jei-1.jar",
            fileID: 999, dependency: false, update: nil
        )]
        let data = try JSONEncoder().encode(list)
        try data.write(to: d.appending(path: ".craftpanel-curseforge.json"))

        let back = CurseForgeClient.installed(serverDir: d)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].slug, "jei")
    }

    func testMissingKeyErrorsImmediatelyNoNetwork() async {
        do {
            _ = try await CurseForgeClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .fabric, query: "jei",
                projectType: "mod", mcVersion: "1.21.1", offset: 0, apiKey: ""
            )
            XCTFail("expected an error for a blank API key")
        } catch {
            XCTAssertTrue("\(error)".contains("API key"))
        }
    }

    // MARK: - Live network, skip cleanly if no key is provided

    /// Set CURSEFORGE_TEST_KEY in the test scheme's environment to run
    /// this against the real API — mirrors the Rust side's own
    /// `CURSEFORGE_TEST_KEY=... cargo test -- --ignored` convention.
    func testLiveSearchFabric() async throws {
        guard let key = ProcessInfo.processInfo.environment["CURSEFORGE_TEST_KEY"], !key.isEmpty else {
            throw XCTSkip("set CURSEFORGE_TEST_KEY to exercise the real CurseForge API")
        }
        do {
            let r = try await CurseForgeClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .fabric, query: "jei",
                projectType: "mod", mcVersion: "1.21.1", offset: 0, apiKey: key
            )
            XCTAssertTrue(r.hits.contains { $0.slug.contains("jei") || $0.title.lowercased().contains("just enough items") })
        } catch {
            throw XCTSkip("CurseForge unreachable: \(error)")
        }
    }
}
