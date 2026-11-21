import XCTest
@testable import craftpanel_Swift

/// Direct port of `provision.rs`'s own `#[cfg(test)]` module, mirrored
/// where a Swift equivalent makes sense.
final class ProvisionerTests: XCTestCase {
    func testLoaderMapsToServerType() {
        XCTAssertEqual(Loader.paper.serverType, .paper)
        XCTAssertEqual(Loader.neoforge.serverType, .neoforge)
        XCTAssertEqual(Loader.forge.serverType, .forge)
        XCTAssertEqual(Loader.fabric.serverType, .fabric)
        XCTAssertEqual(Loader.vanilla.serverType, .vanilla)
    }

    /// The Tauri original returned "21.1" for NeoForge "21.1.172" (its `>= 20` branch made the
    /// "1." prefix unreachable), which broke Modrinth/Java lookups; NeoForge 21.1.x is Minecraft 1.21.1.
    func testDeriveMcVersion() {
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .forge, versionID: "1.20.1-47.2.0"), "1.20.1")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .vanilla, versionID: "1.21.1"), "1.21.1")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "26.2.5"), "26.2")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "21.1.172"), "1.21.1")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "21.0.5"), "1.21")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "20.4.237"), "1.20.4")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "26.3.0.34-beta"), "26.3")
        XCTAssertEqual(Provisioner.deriveMcVersion(loader: .neoforge, versionID: "0.25w14craftmine.3-beta"), "0.25w14craftmine.3-beta")
    }

    // MARK: - Live network, skip cleanly if unreachable

    func testListsVanillaVersions() async throws {
        do {
            let v = try await Provisioner.listVersions(.vanilla)
            XCTAssertTrue(v.contains { $0.kind == "release" })
        } catch {
            throw XCTSkip("Mojang unreachable: \(error)")
        }
    }

    func testListsEveryLoader() async throws {
        for loader in Loader.allCases {
            do {
                let v = try await Provisioner.listVersions(loader)
                XCTAssertFalse(v.isEmpty, "\(loader) returned no versions")
            } catch {
                throw XCTSkip("\(loader) version source unreachable: \(error)")
            }
        }
    }
}
