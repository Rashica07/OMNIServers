import XCTest
@testable import craftpanel_Swift

final class LogAnalyzerTests: XCTestCase {
    func ids(_ s: String) -> [String] { LogAnalyzer.analyze(s).map(\.id) }

    func testCleanLogHasNoFindings() {
        XCTAssertEqual(ids("[12:00:05] [Server thread/INFO]: Done (4.2s)! For help, type \"help\""), [])
    }
    func testEula() { XCTAssertEqual(ids("You need to agree to the EULA in order to run the server."), ["eula"]) }
    func testPortClash() { XCTAssertEqual(ids("**** FAILED TO BIND TO PORT! Address already in use"), ["port"]) }
    func testJavaVersion() { XCTAssertTrue(ids("java.lang.UnsupportedClassVersionError: x").contains("java-version")) }
    func testOutOfMemory() { XCTAssertTrue(ids("java.lang.OutOfMemoryError: Java heap space").contains("oom")) }
    func testMissingDependency() { XCTAssertTrue(ids("Missing or unsupported mandatory dependencies: fabric-api").contains("dependency")) }
    func testDuplicateMod() { XCTAssertTrue(ids("Found duplicate mods: sodium").contains("duplicate-mod")) }
    func testLagIsWarning() {
        let f = LogAnalyzer.analyze("Can't keep up! Is the server overloaded?")
        XCTAssertEqual(f.first?.severity, .warning)
    }
    func testSeveralFindingsAtOnce() {
        XCTAssertEqual(Set(ids("Address already in use\njava.lang.OutOfMemoryError")), ["port", "oom"])
    }
}
