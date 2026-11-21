import XCTest
@testable import craftpanel_Swift

final class OmniHostTransferTests: XCTestCase {
    private func temp() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-xfer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// A small Java server folder shaped like a real Fabric 26.x one.
    private func javaServer(level: String = "world", properties: String? = nil) throws -> URL {
        let dir = temp()
        let fm = FileManager.default
        let props = properties ?? """
        difficulty=easy
        gamemode=creative
        level-name=\(level)
        level-seed=
        max-players=12
        motd=Hello there
        online-mode=false
        server-port=25570
        simulation-distance=8
        view-distance=10
        white-list=true
        """
        try props.write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        let region = dir.appending(path: "\(level)/dimensions/minecraft/overworld/region")
        try fm.createDirectory(at: region, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 5000).write(to: region.appending(path: "r.0.0.mca"))
        try Data("nbt".utf8).write(to: dir.appending(path: "\(level)/level.dat"))
        try Data("lock".utf8).write(to: dir.appending(path: "\(level)/session.lock"))
        try fm.createDirectory(at: dir.appending(path: "\(level)/vss-lod"), withIntermediateDirectories: true)
        try Data("mod data".utf8).write(to: dir.appending(path: "\(level)/vss-lod/x.bin"))
        try fm.createDirectory(at: dir.appending(path: "mods"), withIntermediateDirectories: true)
        for j in ["a.jar", "b.jar"] { try Data().write(to: dir.appending(path: "mods/\(j)")) }
        try "[{\"uuid\":\"u\",\"name\":\"kiqa\",\"level\":4,\"bypassesPlayerLimit\":false}]".write(to: dir.appending(path: "ops.json"), atomically: true, encoding: .utf8)
        try "[{\"uuid\":\"u\",\"name\":\"kiqa\"}]".write(to: dir.appending(path: "whitelist.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: dir.appending(path: "banned-players.json"), atomically: true, encoding: .utf8)
        try Data("png".utf8).write(to: dir.appending(path: "server-icon.png"))
        return dir
    }

    func testSettingsMapFromServerProperties() throws {
        let s = OmniHostTransfer.settings(from: Properties.load(dir: try javaServer()))
        XCTAssertEqual(s.port, 25570); XCTAssertEqual(s.maxPlayers, 12)
        XCTAssertEqual(s.gamemode, "creative"); XCTAssertEqual(s.difficulty, "easy")
        XCTAssertFalse(s.onlineMode); XCTAssertEqual(s.motd, "Hello there")
        XCTAssertEqual(s.viewDistance, 10); XCTAssertEqual(s.simulationDistance, 8)
        XCTAssertTrue(s.whitelist); XCTAssertFalse(s.enforceWhitelist)
        XCTAssertEqual(s.levelName, "world")
    }

    func testMissingOrOddPropertiesFallBackToSafeDefaults() throws {
        let s = OmniHostTransfer.settings(from: Properties.load(dir: try javaServer(properties: "server-port=0\nlevel-name=../evil\nonline-mode=maybe\nmax-players=x\n")))
        XCTAssertEqual(s.port, 25565); XCTAssertEqual(s.levelName, "world"); XCTAssertEqual(s.maxPlayers, 20)
        XCTAssertTrue(s.onlineMode, "anything but false stays online")
    }

    func testPlanDescribesWhatMovesAndWhatStaysBehind() throws {
        let plan = try OmniHostTransfer.plan(sourceDir: try javaServer(), name: "Survival")
        XCTAssertEqual(plan.modCount, 2); XCTAssertEqual(plan.pluginCount, 0)
        XCTAssertEqual(plan.lists, ["ops.json", "whitelist.json"], "empty banned list is not worth copying")
        XCTAssertTrue(plan.hasIcon)
        XCTAssertGreaterThan(plan.worldBytes, 0)
        XCTAssertEqual(OmniHostTransfer.requiredFreeBytes(plan), plan.worldBytes * 3 / 2 + 100_000_000)
    }

    func testPlanFailsWithoutAWorld() throws {
        let dir = temp()
        try "level-name=world\n".write(to: dir.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try OmniHostTransfer.plan(sourceDir: dir, name: "x")) {
            XCTAssertEqual(($0 as? OmniHostTransfer.TransferError)?.errorDescription, OmniHostTransfer.TransferError.noWorld.errorDescription)
        }
    }

    func testPerformCopiesWorldListsIconAndConfigAndLeavesTheSourceAlone() async throws {
        let src = try javaServer(), dest = temp().appending(path: "new", directoryHint: .isDirectory)
        let before = try FileManager.default.subpathsOfDirectory(atPath: src.path).sorted()
        let plan = try OmniHostTransfer.plan(sourceDir: src, name: "Survival")
        try await OmniHostTransfer.perform(plan, to: dest)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "world/level.dat").path))
        XCTAssertEqual(try Data(contentsOf: dest.appending(path: "world/dimensions/minecraft/overworld/region/r.0.0.mca")).count, 5000)
        XCTAssertFalse(fm.fileExists(atPath: dest.appending(path: "world/session.lock").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appending(path: "world/vss-lod").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "data/ops.json").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "data/whitelist.json").path))
        XCTAssertFalse(fm.fileExists(atPath: dest.appending(path: "data/banned-players.json").path))
        XCTAssertEqual(try Data(contentsOf: dest.appending(path: "server-icon.png")), Data("png".utf8), "keeps the server's own icon")
        XCTAssertFalse(fm.fileExists(atPath: dest.appending(path: "mods").path))
        let toml = try String(contentsOf: dest.appending(path: "pumpkin.toml"), encoding: .utf8)
        XCTAssertEqual(PumpkinConfig.javaPort(in: toml), 25570)
        XCTAssertTrue(toml.contains("online_mode = false"))
        XCTAssertTrue(toml.contains("white_list = true"))
        XCTAssertTrue(toml.contains("view_distance = 10"))
        XCTAssertFalse(toml.contains("default_level_name"), "world is the default name")
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: src.path).sorted(), before, "the Java server is untouched")
        XCTAssertTrue(fm.fileExists(atPath: src.appending(path: "world/session.lock").path))
    }

    func testCustomLevelNameIsKept() async throws {
        let src = try javaServer(level: "MyWorld"), dest = temp().appending(path: "n", directoryHint: .isDirectory)
        try await OmniHostTransfer.perform(try OmniHostTransfer.plan(sourceDir: src, name: "x"), to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appending(path: "MyWorld/level.dat").path))
        XCTAssertTrue(try String(contentsOf: dest.appending(path: "pumpkin.toml"), encoding: .utf8).contains("default_level_name = \"MyWorld\""))
    }

    func testNotEnoughSpaceStopsBeforeAnythingIsCreated() async throws {
        let plan = try OmniHostTransfer.plan(sourceDir: try javaServer(), name: "x")
        let dest = temp().appending(path: "n", directoryHint: .isDirectory)
        do { try await OmniHostTransfer.perform(plan, to: dest, free: 1000); XCTFail("should throw") }
        catch let e as OmniHostTransfer.TransferError { guard case .notEnoughSpace = e else { return XCTFail("\(e)") } }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testExistingDestinationIsNeverTouched() async throws {
        let plan = try OmniHostTransfer.plan(sourceDir: try javaServer(), name: "x")
        let dest = temp()
        try Data("keep".utf8).write(to: dest.appending(path: "mine.txt"))
        do { try await OmniHostTransfer.perform(plan, to: dest); XCTFail("should throw") } catch {}
        XCTAssertEqual(try Data(contentsOf: dest.appending(path: "mine.txt")), Data("keep".utf8))
    }

    func testAFailedCopyRemovesTheHalfMadeFolder() async throws {
        var plan = try OmniHostTransfer.plan(sourceDir: try javaServer(), name: "x")
        plan.levelName = "gone"   // the world vanished after the plan was made
        let dest = temp().appending(path: "n", directoryHint: .isDirectory)
        do { try await OmniHostTransfer.perform(plan, to: dest); XCTFail("should throw") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }

    func testOnlyJavaServersCanMove() {
        XCTAssertTrue(OmniHostTransfer.canTransfer(.fabric)); XCTAssertTrue(OmniHostTransfer.canTransfer(.vanilla))
        XCTAssertFalse(OmniHostTransfer.canTransfer(.omnihost)); XCTAssertFalse(OmniHostTransfer.canTransfer(.bedrock))
    }
}

final class OmniHostPlayerTransferTests: XCTestCase {
    private func temp() -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-pl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testOfflineIdMatchesWhatTheRealEngineAssigned() {
        // Seen in a real engine run: this name got this id.
        XCTAssertEqual(OmniHostTransfer.offlineUUID(name: "betsmaens"), "fcb14d8a-f0cf-b45e-924e-055fb0d2055b")
    }

    func testAdvancementsConvertToTheEnginesLayout() throws {
        let java = """
        {"DataVersion": 4000, "minecraft:story/root": {"criteria": {"crafting_table": "2026-08-29 17:40:46 +0200"}, "done": true},
         "minecraft:recipes/x": {"criteria": {"has_it": "2026-08-29 17:40:46 +0200"}, "done": false}}
        """
        let out = try XCTUnwrap(OmniHostTransfer.convertAdvancements(Data(java.utf8)))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertNil(obj["DataVersion"])
        let c = try XCTUnwrap((obj["minecraft:story/root"] as? [String: Any])?["crafting_table"] as? [String: Int])
        XCTAssertEqual(c["secs_since_epoch"], 1788018046)
        XCTAssertEqual(c["nanos_since_epoch"], 0)
    }

    func testRemapListRewritesIds() throws {
        let d = Data(#"[{"uuid":"AAA","name":"k"},{"uuid":"zzz","name":"o"}]"#.utf8)
        let out = try XCTUnwrap(OmniHostTransfer.remapList(d, map: ["aaa": "bbb"]))
        let arr = try XCTUnwrap(try JSONSerialization.jsonObject(with: out) as? [[String: String]])
        XCTAssertEqual(arr[0]["uuid"], "bbb"); XCTAssertEqual(arr[1]["uuid"], "zzz")
    }

    private func server(online: Bool) throws -> (src: URL, id: String) {
        let src = temp(), fm = FileManager.default
        let id = "1e9d1492-25f2-361c-91e1-75b37f001ed7"
        try "online-mode=\(online)\nlevel-name=world\nhardcore=true\nspawn-protection=0\npvp=false\nresource-pack=https://x.test/p.zip\nrequire-resource-pack=true\n"
            .write(to: src.appending(path: "server.properties"), atomically: true, encoding: .utf8)
        let world = src.appending(path: "world")
        for sub in ["players/data", "players/advancements", "players/stats"] { try fm.createDirectory(at: world.appending(path: sub), withIntermediateDirectories: true) }
        try Data("nbt".utf8).write(to: world.appending(path: "level.dat"))
        try Data("dat".utf8).write(to: world.appending(path: "players/data/\(id).dat"))
        try Data("old".utf8).write(to: world.appending(path: "players/data/\(id).dat_old"))
        try Data("{}".utf8).write(to: world.appending(path: "players/stats/\(id).json"))
        try Data(#"{"DataVersion":1,"a:b":{"criteria":{"c":"2026-08-29 17:40:46 +0200"},"done":true}}"#.utf8).write(to: world.appending(path: "players/advancements/\(id).json"))
        // A stranger with data but no known name: can't be mapped offline.
        try Data("x".utf8).write(to: world.appending(path: "players/data/00000000-0000-0000-0000-000000000009.dat"))
        try #"[{"uuid":"\#(id)","name":"betsmaens","expiresOn":"x"}]"#.write(to: src.appending(path: "usercache.json"), atomically: true, encoding: .utf8)
        try #"[{"uuid":"\#(id)","name":"betsmaens"}]"#.write(to: src.appending(path: "whitelist.json"), atomically: true, encoding: .utf8)
        try #"[{"uuid":"\#(id)","name":"betsmaens","level":4}]"#.write(to: src.appending(path: "ops.json"), atomically: true, encoding: .utf8)
        return (src, id)
    }

    func testOfflineTransferRenamesPlayerFilesAndListIds() async throws {
        let (src, id) = try server(online: false)
        let dest = temp().appending(path: "new", directoryHint: .isDirectory)
        let plan = try OmniHostTransfer.plan(sourceDir: src, name: "S")
        XCTAssertEqual(plan.playerCount, 2)
        try await OmniHostTransfer.perform(plan, to: dest)
        let new = OmniHostTransfer.offlineUUID(name: "betsmaens")
        let p = dest.appending(path: "world/players")
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: p.appending(path: "data/\(new).dat").path))
        XCTAssertTrue(fm.fileExists(atPath: p.appending(path: "data/\(new).dat_old").path))
        XCTAssertFalse(fm.fileExists(atPath: p.appending(path: "data/\(id).dat").path))
        XCTAssertTrue(fm.fileExists(atPath: p.appending(path: "stats/\(new).json").path))
        let adv = try XCTUnwrap(fm.contents(atPath: p.appending(path: "advancements/\(new).json").path))
        XCTAssertNotNil(try (JSONSerialization.jsonObject(with: adv) as? [String: Any])?["a:b"])
        XCTAssertTrue(try String(contentsOf: dest.appending(path: "data/whitelist.json"), encoding: .utf8).contains(new))
        XCTAssertTrue(try String(contentsOf: dest.appending(path: "data/ops.json"), encoding: .utf8).contains(new))
        // The Java server's own files are untouched.
        XCTAssertTrue(fm.fileExists(atPath: src.appending(path: "world/players/data/\(id).dat").path))
        XCTAssertTrue(fm.fileExists(atPath: dest.appending(path: "OMNIHost-transfer.txt").path))
        let toml = try String(contentsOf: dest.appending(path: "pumpkin.toml"), encoding: .utf8)
        XCTAssertTrue(toml.contains("encryption = false"))
        XCTAssertTrue(toml.contains("hardcore = true")); XCTAssertTrue(toml.contains("spawn_protection = 0"))
        XCTAssertTrue(toml.contains("[pvp]")); XCTAssertTrue(toml.contains("url = \"https://x.test/p.zip\""))
        XCTAssertTrue(toml.contains("force = true"))
    }

    func testOnlineTransferKeepsIdsAndStaysEncrypted() async throws {
        let (src, id) = try server(online: true)
        let dest = temp().appending(path: "new", directoryHint: .isDirectory)
        try await OmniHostTransfer.perform(try OmniHostTransfer.plan(sourceDir: src, name: "S"), to: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appending(path: "world/players/data/\(id).dat").path))
        XCTAssertTrue(try String(contentsOf: dest.appending(path: "pumpkin.toml"), encoding: .utf8).contains("encryption = true"))
    }

    func testModsAreSortedByWhatTheyAre() throws {
        let src = temp(), mods = src.appending(path: "mods")
        try FileManager.default.createDirectory(at: mods, withIntermediateDirectories: true)
        func jar(_ file: String, _ json: String) throws {
            let work = temp()
            try json.write(to: work.appending(path: "fabric.mod.json"), atomically: true, encoding: .utf8)
            let r = try Subprocess.run("/usr/bin/zip", ["-j", "-q", mods.appending(path: file).path, work.appending(path: "fabric.mod.json").path], timeout: 10)
            XCTAssertEqual(r.status, 0)
        }
        try jar("sodium.jar", #"{"id":"sodium","name":"Sodium","environment":"client"}"#)
        try jar("lithium.jar", #"{"id":"lithium","name":"Lithium","environment":"*"}"#)
        try jar("create.jar", #"{"id":"create","name":"Create","environment":"*"}"#)
        try jar("fabric-api.jar", #"{"id":"fabric-api","name":"Fabric API"}"#)
        let r = OmniHostTransfer.classifyMods(in: src)
        XCTAssertEqual(r.clientOnly, ["Sodium"]); XCTAssertEqual(r.notNeeded, ["Lithium"]); XCTAssertEqual(r.gameplay, ["Create"])
    }
}
