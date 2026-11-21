import XCTest
@testable import craftpanel_Swift

final class BedrockResourcePackManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func manifest(name: String, uuid: String, description: String? = nil) -> String {
        """
        {
          "format_version": 2,
          "header": {
            "name": "\(name)",
            "uuid": "\(uuid)",
            "version": [1, 2, 0]\(description.map { ",\n    \"description\": \"\($0)\"" } ?? "")
          },
          "modules": []
        }
        """
    }

    /// A server dir with two real pack folders (one with an icon, one
    /// without) and one folder that isn't a pack at all (no manifest) —
    /// the last one must be silently skipped, not shown as a broken row.
    private func srv(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-brp-\(tag)-\(UUID().uuidString)")
        let fm = FileManager.default
        let packs = d.appending(path: "resource_packs")

        let a = packs.appending(path: "vivid-pack")
        try! fm.createDirectory(at: a, withIntermediateDirectories: true)
        try! Data(manifest(name: "Vivid", uuid: "AAAAAAAA-0000-0000-0000-000000000001", description: "Bright textures").utf8)
            .write(to: a.appending(path: "manifest.json"))
        try! Data("not a real png, just needs to exist".utf8).write(to: a.appending(path: "pack_icon.png"))

        let b = packs.appending(path: "muted-pack")
        try! fm.createDirectory(at: b, withIntermediateDirectories: true)
        try! Data(manifest(name: "Muted", uuid: "BBBBBBBB-0000-0000-0000-000000000002").utf8)
            .write(to: b.appending(path: "manifest.json"))

        let notAPack = packs.appending(path: "stray-folder")
        try! fm.createDirectory(at: notAPack, withIntermediateDirectories: true)
        try! Data("hello".utf8).write(to: notAPack.appending(path: "readme.txt"))

        tempDirs.append(d)
        return d
    }

    func testListsPacksAndSkipsFoldersWithoutManifest() {
        let d = srv("list")
        let packs = BedrockResourcePackManager.list(serverDir: d)
        XCTAssertEqual(packs.count, 2)
        XCTAssertEqual(packs.map(\.name), ["Muted", "Vivid"]) // sorted by name
        let vivid = packs.first { $0.name == "Vivid" }!
        XCTAssertEqual(vivid.id, "AAAAAAAA-0000-0000-0000-000000000001")
        XCTAssertEqual(vivid.versionLabel, "1.2.0")
        XCTAssertEqual(vivid.description, "Bright textures")
        XCTAssertNotNil(vivid.iconURL)
        let muted = packs.first { $0.name == "Muted" }!
        XCTAssertNil(muted.iconURL)
    }

    func testEmptyResourcePacksFolderReturnsEmptyList() {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-brp-empty-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        XCTAssertTrue(BedrockResourcePackManager.list(serverDir: d).isEmpty)
    }

    func testDeleteMovesFolderToTrashAndLeavesTheOtherPackAlone() throws {
        let d = srv("delete")
        let before = BedrockResourcePackManager.list(serverDir: d)
        let vivid = before.first { $0.name == "Vivid" }!

        try BedrockResourcePackManager.delete(serverDir: d, pack: vivid)

        let after = BedrockResourcePackManager.list(serverDir: d)
        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after.first?.name, "Muted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: vivid.folderURL.path))

        // moved into trash, not hard-deleted
        let trashDir = d.appending(path: ".craftpanel-trash")
        let trashed = try FileManager.default.contentsOfDirectory(at: trashDir, includingPropertiesForKeys: nil)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertTrue(trashed[0].lastPathComponent.hasSuffix("vivid-pack"))
    }

    /// The real regression this needs to guard: deleting one pack must
    /// remove *only* its own entry from `world_resource_packs.json`,
    /// leaving every other world's reference to a still-installed pack
    /// intact.
    func testDeleteRemovesOnlyTheMatchingWorldConfigEntry() throws {
        let d = srv("prune")
        let worldDir = d.appending(path: "worlds/Bedrock level")
        try FileManager.default.createDirectory(at: worldDir, withIntermediateDirectories: true)
        let configJSON = """
        [
          {"pack_id": "aaaaaaaa-0000-0000-0000-000000000001", "version": [1, 2, 0]},
          {"pack_id": "BBBBBBBB-0000-0000-0000-000000000002", "version": [1, 0, 0]}
        ]
        """
        let configURL = worldDir.appending(path: "world_resource_packs.json")
        try Data(configJSON.utf8).write(to: configURL)

        let vivid = BedrockResourcePackManager.list(serverDir: d).first { $0.name == "Vivid" }!
        try BedrockResourcePackManager.delete(serverDir: d, pack: vivid)

        let raw = try Data(contentsOf: configURL)
        let entries = try JSONSerialization.jsonObject(with: raw) as! [[String: Any]]
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual((entries[0]["pack_id"] as? String)?.lowercased(), "bbbbbbbb-0000-0000-0000-000000000002")
    }

    func testDeletingAlreadyGoneFolderThrows() {
        let d = srv("gone")
        let vivid = BedrockResourcePackManager.list(serverDir: d).first { $0.name == "Vivid" }!
        try? FileManager.default.removeItem(at: vivid.folderURL)
        XCTAssertThrowsError(try BedrockResourcePackManager.delete(serverDir: d, pack: vivid))
    }
}
