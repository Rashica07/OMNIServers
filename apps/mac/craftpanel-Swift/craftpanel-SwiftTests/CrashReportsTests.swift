import XCTest
@testable import craftpanel_Swift

/// Direct port of `crashreports.rs`'s own `#[cfg(test)] mod tests`.
final class CrashReportsTests: XCTestCase {
    private let sample = """
    ---- Minecraft Crash Report ----
    // Who set us up the TNT?

    Time: 2026-08-30 01:23:45
    Description: Exception in server tick loop

    java.lang.NullPointerException: Cannot invoke "..." because "x" is null
    \tat net.minecraft.server.MinecraftServer.tickServer(MinecraftServer.java:100)
    \tat com.example.coolmod.TickHandler.onTick(TickHandler.java:42) ~[coolmod-1.2.3.jar:?]
    \tat net.minecraft.server.MinecraftServer.tickChildren(MinecraftServer.java:80)

    """

    func testExtractsFieldsAndCulpritJar() {
        let r = CrashReports.parse(file: "crash.txt", mtime: 0, text: sample)
        XCTAssertEqual(r.time, "2026-08-30 01:23:45")
        XCTAssertEqual(r.description, "Exception in server tick loop")
        XCTAssertTrue(r.headline?.hasPrefix("java.lang.NullPointerException") ?? false)
        XCTAssertEqual(r.suspect, "coolmod-1.2.3.jar")
    }

    func testFallsBackToPackageRoot() {
        let s = sample.replacingOccurrences(of: " ~[coolmod-1.2.3.jar:?]", with: "")
        let r = CrashReports.parse(file: "c.txt", mtime: 0, text: s)
        XCTAssertEqual(r.suspect, "com.example")
    }

    func testNamesAMissingForgeDependency() {
        let s = """
        ---- Minecraft Crash Report ----

        Description: Loading crashed!

        net.minecraftforge.fml.LoadingFailedException: Loading errors encountered:
        Missing or unsupported mandatory dependencies:
        \tMod ID: 'terrablender', Requested by: 'biomesoplenty', Expected range: '[3.0,)', Actual version: '[MISSING]'

        """
        let r = CrashReports.parse(file: "crash.txt", mtime: 0, text: s)
        let dep = try! XCTUnwrap(r.missingDependency)
        XCTAssertEqual(dep.modID, "terrablender")
        XCTAssertEqual(dep.requestedBy, "biomesoplenty")
    }

    func testNoMissingDependencyLineIsNil() {
        let r = CrashReports.parse(file: "crash.txt", mtime: 0, text: sample)
        XCTAssertNil(r.missingDependency)
    }

    func testNoReportsDirIsEmpty() {
        XCTAssertTrue(CrashReports.list(serverDir: URL(fileURLWithPath: "/no/such/server")).isEmpty)
    }
}
