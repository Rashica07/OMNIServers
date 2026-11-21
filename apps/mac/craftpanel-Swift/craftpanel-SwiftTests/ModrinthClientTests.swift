import XCTest
@testable import craftpanel_Swift

final class ModrinthClientTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func makeTempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-mr-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    // MARK: - Pure logic, no network

    func testLoaderFacets() {
        XCTAssertEqual(ModrinthClient.loaderFacet(.fabric), "fabric")
        XCTAssertEqual(ModrinthClient.loaderFacet(.paper), "paper")
        XCTAssertEqual(ModrinthClient.loaderFacet(.vanilla), "datapack")
    }

    func testManifestRoundtrip() throws {
        let d = makeTempDir()
        let list = [InstalledEntry(
            projectID: "abc", slug: "lithium", title: "Lithium", filename: "lithium-0.11.jar",
            versionID: "v1", versionNumber: "0.11", dependency: false, update: nil
        )]
        let data = try JSONEncoder().encode(list)
        try data.write(to: d.appending(path: ".craftpanel-modrinth.json"))

        let back = ModrinthClient.installed(serverDir: d)
        XCTAssertEqual(back.count, 1)
        XCTAssertEqual(back[0].slug, "lithium")
    }

    func testContentDirByType() {
        let d = URL(fileURLWithPath: "/srv")
        XCTAssertTrue(ModrinthClient.contentDir(d, serverType: .fabric, projectType: "mod").path.hasSuffix("mods"))
        XCTAssertTrue(ModrinthClient.contentDir(d, serverType: .paper, projectType: "mod").path.hasSuffix("plugins"))
        XCTAssertTrue(ModrinthClient.contentDir(d, serverType: .vanilla, projectType: "datapack").path.hasSuffix("datapacks"))
    }

    // MARK: - Live network, skip cleanly if unreachable

    func testLiveSearchFabric() async throws {
        do {
            let r = try await ModrinthClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .fabric, query: "lithium",
                projectType: "mod", category: nil, mcVersion: "1.21.1", offset: 0
            )
            XCTAssertTrue(r.hits.contains { $0.slug == "lithium" })
        } catch {
            throw XCTSkip("Modrinth unreachable: \(error)")
        }
    }

    func testLiveSearchExcludesClientOnlyAndMarksOld() async throws {
        do {
            // Sodium is client-only -> must NOT appear in a server search
            let r = try await ModrinthClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .fabric, query: "sodium",
                projectType: "mod", category: nil, mcVersion: "1.21.1", offset: 0
            )
            XCTAssertFalse(r.hits.contains { $0.slug == "sodium" }, "sodium is client-only")
            // The server_side:required/optional facet meaningfully filters
            // results but isn't a hard 100% guarantee from Modrinth's own
            // search index -- confirmed live (a direct query for this exact
            // facet combination returns at least one hit reporting
            // server_side "unsupported" anyway, e.g. "boosters" as of this
            // writing). Assert the facet does most of its job rather than
            // pinning an absolute the live API doesn't actually promise.
            let unsupportedCount = r.hits.filter { $0.serverSide == "unsupported" }.count
            XCTAssertLessThan(unsupportedCount, r.hits.count / 2, "the server_side facet should filter out most client-only hits")
            // a very old MC version -> current mods have no build, must be marked
            let old = try await ModrinthClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .fabric, query: "lithium",
                projectType: "mod", category: nil, mcVersion: "1.7.10", offset: 0
            )
            if let l = old.hits.first(where: { $0.slug == "lithium" }) {
                XCTAssertFalse(l.compatible, "lithium has no 1.7.10 build")
            }
        } catch {
            throw XCTSkip("Modrinth unreachable: \(error)")
        }
    }

    /// Regression test for the "Paper Plugins search returns nothing
    /// real" bug: Modrinth indexes plugins under its own "plugin"
    /// project_type facet, not "mod", even for a Paper server.
    func testLiveSearchPaperFindsRealPlugins() async throws {
        do {
            let bedwars = try await ModrinthClient.search(
                serverDir: URL(fileURLWithPath: "/tmp"), serverType: .paper, query: "bedwars",
                projectType: "mod", category: "minigame", mcVersion: nil, offset: 0
            )
            XCTAssertTrue(bedwars.hits.contains { $0.slug.contains("bedwars") },
                          "expected a real BedWars plugin in Paper plugin search")
        } catch {
            throw XCTSkip("Modrinth unreachable: \(error)")
        }
    }

    func testLiveGalleryReturnsRealImageURLs() async throws {
        do {
            // Faithful 64x -- known to have gallery images
            let urls = try await ModrinthClient.gallery(projectID: "r4GILswZ")
            XCTAssertFalse(urls.isEmpty)
            XCTAssertTrue(urls[0].hasPrefix("https://cdn.modrinth.com/"))
        } catch {
            throw XCTSkip("Modrinth unreachable: \(error)")
        }
    }

    func testLiveInstallResourcepackFromSearch() async throws {
        let d = makeTempDir()
        try! "level-name=world\n".write(to: d.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        do {
            let r = try await ModrinthClient.search(
                serverDir: d, serverType: .paper, query: "faithful",
                projectType: "resourcepack", category: nil, mcVersion: "1.21.1", offset: 0
            )
            guard let hit = r.hits.first else {
                throw XCTSkip("no resourcepack hits returned")
            }
            let cfg = try await ModrinthClient.installResourcepack(
                serverDir: d, projectID: hit.projectID, mcVersion: "1.21.1", prompt: "Optional pack", required: false
            )
            XCTAssertTrue(cfg.url.hasPrefix("https://cdn.modrinth.com/"))
            XCTAssertEqual(cfg.sha1.count, 40)

            // nothing was dropped into mods/ or tracked in the mod manifest --
            // this is a server.properties change, not a mod install
            XCTAssertFalse(FileManager.default.fileExists(atPath: d.appending(path: "mods").path))
            XCTAssertTrue(ModrinthClient.installed(serverDir: d).isEmpty)

            let saved = ResourcePackManager.read(dir: d)
            XCTAssertEqual(saved.url, cfg.url)
        } catch {
            throw XCTSkip("Modrinth unreachable: \(error)")
        }
    }
}
