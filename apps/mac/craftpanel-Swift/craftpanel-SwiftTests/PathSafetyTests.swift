import XCTest
@testable import craftpanel_Swift

final class PathSafetyTests: XCTestCase {
    func testSafeFileNameRejectsTraversal() {
        for bad in ["../evil.jar", "a/b.jar", "/etc/passwd", "..", ".hidden", "", "x\\y.jar", "nul\0.jar", " lead.jar"] {
            XCTAssertThrowsError(try ServerFileCollector.safeFileName(bad), bad)
        }
        XCTAssertEqual(try ServerFileCollector.safeFileName("sodium-fabric-0.6.0+mc1.21.jar"), "sodium-fabric-0.6.0+mc1.21.jar")
    }

    func testMoveToTrashNeverOverwrites() throws {
        let fm = FileManager.default
        let d = fm.temporaryDirectory.appending(path: "cp-trash-\(UUID().uuidString)")
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: d) }
        let trash = d.appending(path: ".craftpanel-trash")
        for content in ["one", "two"] {
            let f = d.appending(path: "mod.jar")
            try content.write(to: f, atomically: true, encoding: .utf8)
            try ServerFileCollector.moveToTrash(f, trashDir: trash)
        }
        let kept = try fm.contentsOfDirectory(atPath: trash.path)
        XCTAssertEqual(kept.count, 2)
    }

    func testFileBrowserBlocksSiblingPrefixAndSymlinkedNewPaths() throws {
        let fm = FileManager.default
        let parent = fm.temporaryDirectory.appending(path: "cp-fb-\(UUID().uuidString)")
        let root = parent.appending(path: "mc")
        let sibling = parent.appending(path: "mc2")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: parent) }
        // symlink inside the server pointing at a sibling folder
        try fm.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: sibling)
        XCTAssertThrowsError(try ServerFileBrowser.write(root: root, rel: "link/new.txt", content: "x"))
        XCTAssertFalse(fm.fileExists(atPath: sibling.appending(path: "new.txt").path))
        XCTAssertNoThrow(try ServerFileBrowser.write(root: root, rel: "new.txt", content: "x"))
    }
}
