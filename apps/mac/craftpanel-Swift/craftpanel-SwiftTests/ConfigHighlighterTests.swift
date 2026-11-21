import XCTest
@testable import craftpanel_Swift

/// Direct port of `highlightConfig.ts`'s own behavior — no `#[cfg(test)]`
/// counterpart exists on the Rust side (this logic lives entirely in the
/// web frontend), so these tests are written against the TS source
/// itself: same inputs, same expected token classes.
final class ConfigHighlighterTests: XCTestCase {
    private func classes(_ line: String, _ lang: ConfigLang) -> [TokenClass?] {
        ConfigHighlighter.highlightLine(line, lang: lang).map(\.cls)
    }

    private func texts(_ line: String, _ lang: ConfigLang) -> [String] {
        ConfigHighlighter.highlightLine(line, lang: lang).map(\.text)
    }

    // MARK: - langForFile

    func testLangForFileMapsExtensions() {
        XCTAssertEqual(ConfigLang.forFile("server.properties"), .properties)
        XCTAssertEqual(ConfigLang.forFile("config.yml"), .yaml)
        XCTAssertEqual(ConfigLang.forFile("config.yaml"), .yaml)
        XCTAssertEqual(ConfigLang.forFile("pack.mcmeta"), .json)
        XCTAssertEqual(ConfigLang.forFile("data.json"), .json)
        XCTAssertEqual(ConfigLang.forFile("Cargo.toml"), .toml)
        XCTAssertEqual(ConfigLang.forFile("README.md"), .plain)
        XCTAssertEqual(ConfigLang.forFile("noext"), .plain)
    }

    // MARK: - properties

    func testPropertiesKeyValue() {
        let tokens = ConfigHighlighter.highlightLine("motd=A Minecraft Server", lang: .properties)
        XCTAssertEqual(tokens.map(\.text), ["motd", "=", "A Minecraft Server"])
        XCTAssertEqual(tokens[0].cls, .key)
        XCTAssertNil(tokens[1].cls)
        XCTAssertNil(tokens[2].cls)
    }

    func testPropertiesComment() {
        XCTAssertEqual(classes("# a comment", .properties), [.comment])
        XCTAssertEqual(classes("!also a comment", .properties), [.comment])
    }

    func testPropertiesNoDelimiterIsPlain() {
        let tokens = ConfigHighlighter.highlightLine("just text", lang: .properties)
        XCTAssertEqual(tokens.map(\.text), ["just text"])
        XCTAssertNil(tokens[0].cls)
    }

    // MARK: - yaml

    func testYamlKeyAndScalarKinds() {
        XCTAssertEqual(classes("enabled: true", .yaml), [.key, nil, .keyword])
        XCTAssertEqual(classes("port: 25565", .yaml), [.key, nil, .number])
        XCTAssertEqual(classes("name: \"My Server\"", .yaml), [.key, nil, .string])
        XCTAssertEqual(classes("motd: hello there", .yaml), [.key, nil, nil])
    }

    func testYamlListItemAndComment() {
        let tokens = ConfigHighlighter.highlightLine("- op1", lang: .yaml)
        XCTAssertEqual(tokens.map(\.text), ["- ", "op1"])
        XCTAssertEqual(classes("# yaml comment", .yaml), [.comment])
    }

    func testYamlIndentedKeyPreservesLeadingWhitespace() {
        let tokens = ConfigHighlighter.highlightLine("  nested: 1", lang: .yaml)
        XCTAssertEqual(tokens[0].text, "  ")
        XCTAssertNil(tokens[0].cls)
        XCTAssertEqual(tokens[1].text, "nested")
        XCTAssertEqual(tokens[1].cls, .key)
    }

    func testYamlTrailingCommentAfterScalar() {
        let tokens = ConfigHighlighter.highlightLine("port: 25565 # default", lang: .yaml)
        XCTAssertEqual(tokens.last?.text, "# default")
        XCTAssertEqual(tokens.last?.cls, .comment)
    }

    // MARK: - toml

    func testTomlSection() {
        XCTAssertEqual(classes("[server]", .toml), [.section])
    }

    func testTomlKeyValue() {
        XCTAssertEqual(classes("port = 25565", .toml), [.key, nil, .number])
        XCTAssertEqual(classes("name = \"box\"", .toml), [.key, nil, .string])
    }

    // MARK: - json

    func testJsonKeyVsStringValue() {
        let tokens = ConfigHighlighter.highlightLine("  \"name\": \"value\",", lang: .json)
        let keyTok = tokens.first { $0.text == "\"name\"" }
        let valTok = tokens.first { $0.text == "\"value\"" }
        XCTAssertEqual(keyTok?.cls, .key)
        XCTAssertEqual(valTok?.cls, .string)
    }

    func testJsonBooleanAndNull() {
        XCTAssertTrue(ConfigHighlighter.highlightLine("\"a\": true,", lang: .json).contains { $0.text == "true" && $0.cls == .keyword })
        XCTAssertTrue(ConfigHighlighter.highlightLine("\"a\": null", lang: .json).contains { $0.text == "null" && $0.cls == .keyword })
    }

    func testJsonNumber() {
        XCTAssertTrue(ConfigHighlighter.highlightLine("\"port\": 25565,", lang: .json).contains { $0.text == "25565" && $0.cls == .number })
    }

    // MARK: - plain / never throws

    func testPlainLangPassesThrough() {
        let tokens = ConfigHighlighter.highlightLine("anything at all", lang: .plain)
        XCTAssertEqual(tokens.map(\.text), ["anything at all"])
        XCTAssertNil(tokens[0].cls)
    }

    func testMalformedInputNeverCrashes() {
        // Unterminated quotes, stray brackets, empty lines — the
        // tokenizer must degrade gracefully, never trap, exactly like
        // the TS version's try/catch-wrapped `highlightLine`.
        XCTAssertNoThrow(ConfigHighlighter.highlightLine("", lang: .yaml))
        XCTAssertNoThrow(ConfigHighlighter.highlightLine("\"unterminated", lang: .json))
        XCTAssertNoThrow(ConfigHighlighter.highlightLine("[[[", lang: .toml))
        XCTAssertNoThrow(ConfigHighlighter.highlightLine(":::", lang: .properties))
    }
}
