import XCTest
@testable import craftpanel_Swift

/// End-to-end: a throwaway Fabric server + BlueMap, booted for real, map
/// served on its port, chat sent with tellraw. Downloads ~100 MB and takes
/// minutes, so it only runs when CP_E2E is set.
@MainActor
final class ZZBlueMapE2E: XCTestCase {
    func testFabricServerWithBlueMap() async throws {
        guard ProcessInfo.processInfo.environment["CP_E2E"] != nil else { throw XCTSkip("set CP_E2E") }
        let dir = FileManager.default.temporaryDirectory.appending(path: "cp-e2e-\(UUID().uuidString.prefix(6))")
        let mc = "26.2"
        let java = try XCTUnwrap(JavaProbe.autoResolve(javaPath: "java", mcVersion: mc))
        let created = try await Provisioner.create(CreateSpec(loader: .fabric, mcVersion: mc, loaderVersion: nil, dir: dir, name: "E2E",
                                                             ramMB: 2048, javaPath: java)) { _ in }
        Provisioner.applyStartingSettings(dir: dir, bedrock: false, port: Provisioner.pickFreePort(taken: [25565]),
                                          seed: nil, gamemode: nil, difficulty: nil, motd: nil, maxPlayers: nil)
        let port = BlueMap.pickPort(otherServers: [])
        try await BlueMap.install(dir, type: .fabric, mcVersion: mc, port: port)
        XCTAssertTrue(BlueMap.isInstalled(dir, type: .fabric), "not installed")

        let record = ServerRecord(name: "E2E", path: dir.path, serverType: created.serverType, launchTarget: created.launchTarget,
                                  mcVersion: created.mcVersion, javaPath: created.javaPath, ramMB: 2048)
        let rt = ServerRuntime(serverID: record.id)
        try rt.start(record: record)
        defer { try? rt.stop() }

        var done = false
        for _ in 0..<600 where !done {
            try await Task.sleep(for: .milliseconds(500))
            done = rt.lines.contains { $0.text.contains("Done (") }
            if !rt.isRunning { break }
        }
        print("E2E console tail:\n" + rt.lines.suffix(40).map(\.text).joined(separator: "\n"))
        XCTAssertTrue(done, "server didn't finish starting")
        let t0 = Date()

        var up = false
        for _ in 0..<120 where !up {
            try await Task.sleep(for: .seconds(1))
            up = await BlueMap.isUp(port: port)
        }
        XCTAssertTrue(up, "BlueMap web server never answered on \(port)")
        print("E2E map up after \(Int(Date().timeIntervalSince(t0)))s")
        let (html, _) = try await URLSession.shared.data(from: BlueMap.localURL(port: port))
        let page = String(decoding: html, as: UTF8.self)
        XCTAssertTrue(page.localizedCaseInsensitiveContains("bluemap"), "page: \(page.prefix(300))")

        try await rt.sendChat("hello from OMNIServers \"quoted\"", as: "Host", record: record)
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(rt.lines.suffix(10).contains { $0.text.contains("Unknown or incomplete command") || $0.text.contains("<--[HERE]") })
        XCTAssertEqual(rt.chat.last?.kind, .mine)

        try rt.stop()
        for _ in 0..<60 where rt.isRunning { try await Task.sleep(for: .milliseconds(500)) }
        print("E2E map files:", (try? FileManager.default.contentsOfDirectory(atPath: dir.appending(path: "bluemap").path)) ?? [])
        try? FileManager.default.removeItem(at: dir)
    }
}
