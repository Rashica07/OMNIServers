import XCTest
@testable import craftpanel_Swift

/// Direct port of `pluginconfig.rs`'s own `#[cfg(test)] mod tests`.
final class PluginConfigTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-plugincfg-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    private let esxSample = """
    # comment
    ops-name-color: '4'
    currency-symbol: '$'
    starting-balance: 0
    max-money: 10000000000000
    spawn-on-join: false
    teleport-safety: true

    """

    private let geyserSample = """
    bedrock:
      # comment about address
      address: 0.0.0.0
      port: 19132
      clone-remote-port: false
    remote:
      address: 127.0.0.1
      port: 25565

    """

    func testReadsTopLevelAndStripsQuotes() {
        XCTAssertEqual(PluginConfig.getTopLevel(esxSample, "currency-symbol"), "$")
        XCTAssertEqual(PluginConfig.getTopLevel(esxSample, "starting-balance"), "0")
        XCTAssertEqual(PluginConfig.getTopLevel(esxSample, "teleport-safety"), "true")
        XCTAssertNil(PluginConfig.getTopLevel(esxSample, "nonexistent"))
    }

    func testReadsNestedAndStopsAtNextSiblingBlock() {
        XCTAssertEqual(PluginConfig.getNested(geyserSample, "bedrock", "port"), "19132")
        XCTAssertEqual(PluginConfig.getNested(geyserSample, "bedrock", "address"), "0.0.0.0")
        // "port" also exists under remote: — must not bleed across blocks
        XCTAssertEqual(PluginConfig.getNested(geyserSample, "remote", "port"), "25565")
        XCTAssertNil(PluginConfig.getNested(geyserSample, "bedrock", "not-here"))
    }

    func testSetTopLevelPreservesEverythingElse() throws {
        let out = try PluginConfig.setValue(esxSample, "currency-symbol", "€", quote: true)
        XCTAssertTrue(out.contains("currency-symbol: '€'"))
        XCTAssertTrue(out.contains("# comment")) // untouched
        XCTAssertTrue(out.contains("ops-name-color: '4'")) // untouched
        XCTAssertEqual(PluginConfig.getTopLevel(out, "starting-balance"), "0") // untouched
    }

    func testSetNestedOnlyTouchesTheRightBlock() throws {
        let out = try PluginConfig.setValue(geyserSample, "bedrock.port", "19133", quote: false)
        XCTAssertEqual(PluginConfig.getNested(out, "bedrock", "port"), "19133")
        XCTAssertEqual(PluginConfig.getNested(out, "remote", "port"), "25565") // untouched
        XCTAssertTrue(out.contains("# comment about address")) // untouched
    }

    func testSetMissingKeyErrorsInsteadOfSilentlyAppending() {
        XCTAssertThrowsError(try PluginConfig.setValue(esxSample, "does-not-exist", "x", quote: false))
    }

    func testSetFieldValidatesIntRangeAndSelectOptions() throws {
        let d = tempDir("validate")
        try FileManager.default.createDirectory(at: d.appending(path: "plugins/Geyser-Spigot"), withIntermediateDirectories: true)
        try geyserSample.write(to: d.appending(path: "plugins/Geyser-Spigot/config.yml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try PluginConfig.setField(serverDir: d, pluginID: "geyser", key: "bedrock.port", value: "70000"), "port above 65535 should fail")
        try PluginConfig.setField(serverDir: d, pluginID: "geyser", key: "bedrock.port", value: "19133")
        let text = try String(contentsOf: d.appending(path: "plugins/Geyser-Spigot/config.yml"), encoding: .utf8)
        XCTAssertEqual(PluginConfig.getNested(text, "bedrock", "port"), "19133")
    }

    func testDetectFindsOnlyWhatsActuallyInstalled() throws {
        let d = tempDir("detect")
        try FileManager.default.createDirectory(at: d.appending(path: "plugins/Essentials"), withIntermediateDirectories: true)
        try esxSample.write(to: d.appending(path: "plugins/Essentials/config.yml"), atomically: true, encoding: .utf8)

        let views = PluginConfig.detect(serverDir: d)
        XCTAssertEqual(views.count, 1, "only EssentialsX is 'installed' in this fixture")
        XCTAssertEqual(views[0].plugin, "essentialsx")
        let currency = try XCTUnwrap(views[0].fields.first { $0.key == "currency-symbol" })
        XCTAssertEqual(currency.value, "$")
    }
}
