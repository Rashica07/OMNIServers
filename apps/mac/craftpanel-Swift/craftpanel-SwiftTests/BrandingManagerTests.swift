import XCTest
import AppKit
@testable import craftpanel_Swift

/// Direct port of `branding.rs`'s own tests.
final class BrandingManagerTests: XCTestCase {
    private var tempDirs: [URL] = []

    override func tearDown() {
        for d in tempDirs { try? FileManager.default.removeItem(at: d) }
        tempDirs = []
        super.tearDown()
    }

    private func tempDir(_ tag: String) -> URL {
        let d = FileManager.default.temporaryDirectory.appending(path: "cp-brand-\(tag)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        tempDirs.append(d)
        return d
    }

    func testResizesAnyImageTo64SquarePNG() throws {
        let d = tempDir("ok")
        // a 200×120 source
        let src = d.appending(path: "src.png")
        let image = NSImage(size: NSSize(width: 200, height: 120))
        image.lockFocus()
        NSColor(calibratedRed: 10 / 255, green: 20 / 255, blue: 30 / 255, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 200, height: 120).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            XCTFail("couldn't build test fixture"); return
        }
        try png.write(to: src)

        try BrandingManager.setIcon(serverDir: d, source: src)
        XCTAssertTrue(BrandingManager.hasIcon(serverDir: d))

        let out = NSImage(contentsOf: d.appending(path: BrandingManager.iconFile))
        XCTAssertEqual(out?.representations.first?.pixelsWide, 64)
        XCTAssertEqual(out?.representations.first?.pixelsHigh, 64)

        try BrandingManager.clearIcon(serverDir: d)
        XCTAssertFalse(BrandingManager.hasIcon(serverDir: d))
    }

    func testRejectsANonImage() {
        let d = tempDir("bad")
        let bad = d.appending(path: "notimg.png")
        try! Data("nope".utf8).write(to: bad)
        XCTAssertThrowsError(try BrandingManager.setIcon(serverDir: d, source: bad))
    }
}
