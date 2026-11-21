import XCTest
@testable import craftpanel_Swift

/// Direct port of `process.rs`'s JVM-launch-command tests
/// (`builds_jar_command_with_equal_heap`, `forge_with_args_file_uses_at_syntax`).
final class JvmArgsTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-jvm-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testBuildsJarCommandWithSmallInitialHeap() {
        let d = tempDir("jar")
        let config = ServerConfig(path: d, launchTarget: "paper.jar", javaPath: "java", ramMB: 3072, serverType: .paper, jvmArgs: nil)
        let proc = MinecraftAdapter().startCommand(config: config)
        let args = (proc.arguments ?? []).joined(separator: " ")
        XCTAssertTrue(args.contains("-Xms1024M"))
        XCTAssertTrue(args.contains("-Xmx3072M"))
        XCTAssertTrue(args.hasSuffix("-jar paper.jar nogui"))
        XCTAssertEqual(MinecraftAdapter.initialHeapMB(768), 768)
    }

    func testForgeWithArgsFileUsesAtSyntax() throws {
        let d = tempDir("forge-args")
        let libs = d.appendingPathComponent("libraries/net/minecraftforge/forge/1.20.4-49.0.3")
        try FileManager.default.createDirectory(at: libs, withIntermediateDirectories: true)
        try Data("-jar\nforge.jar".utf8).write(to: libs.appendingPathComponent("unix_args.txt"))

        let config = ServerConfig(path: d, launchTarget: "run.sh", javaPath: "java", ramMB: 3072, serverType: .forge, jvmArgs: nil)
        MinecraftAdapter.ensureUserJVMArgs(config: config)
        let proc = MinecraftAdapter().startCommand(config: config)
        let args = (proc.arguments ?? []).joined(separator: " ")
        XCTAssertTrue(args.contains("@user_jvm_args.txt"))
        XCTAssertTrue(args.contains("@libraries/net/minecraftforge/forge/1.20.4-49.0.3/unix_args.txt"))

        let jvm = try String(contentsOf: d.appendingPathComponent("user_jvm_args.txt"), encoding: .utf8)
        XCTAssertTrue(jvm.contains("-Xmx3072M"))
    }

    func testJvmArgTokensFiltersNonFlagWords() {
        XCTAssertEqual(MinecraftAdapter.jvmArgTokens("-XX:+UseG1GC nogui -Xss1M"), ["-XX:+UseG1GC", "-Xss1M"])
        XCTAssertEqual(MinecraftAdapter.jvmArgTokens(nil), [])
        XCTAssertEqual(MinecraftAdapter.jvmArgTokens(""), [])
    }

    func testAikarFlagsScalesWithRAM() {
        XCTAssertTrue(JvmArgs.aikarFlags(ramMB: 4096).contains("G1NewSizePercent=30"))
        XCTAssertTrue(JvmArgs.aikarFlags(ramMB: 16384).contains("G1NewSizePercent=40"))
    }
}
