import XCTest
@testable import craftpanel_Swift

final class NBTTests: XCTestCase {
    private let sample: NBTNode = .compound([
        ("Data", .compound([
            ("LevelName", .string("My World ☃")),
            ("RandomSeed", .long(-8_765_432_109_876_543_210)),
            ("GameType", .int(1)), ("hardcore", .byte(0)), ("SpawnY", .short(64)),
            ("BorderSize", .double(5.9999968e7)), ("Temp", .float(0.8)),
            ("Tags", .list(elementType: 8, [.string("a"), .string("b")])),
            ("Empty", .list(elementType: 0, [])),
            ("Bytes", .byteArray([1, -2, 3])), ("Ints", .intArray([1, -2])), ("Longs", .longArray([Int64.min, Int64.max])),
        ])),
    ])

    func testEncodeDecodeRoundTrip() throws {
        let data = NBT.encode(name: "", root: sample)
        let (name, back) = try NBT.decode(data)
        XCTAssertEqual(name, "")
        XCTAssertEqual(back, sample)
    }

    func testGzipFileRoundTripKeepsBackupAndCompression() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "cp-nbt-\(UUID().uuidString).dat")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: url.appendingPathExtension("craftpanel-bak")) }
        try NBT.write(url, name: "", root: sample, gzip: true)
        // gzip output must be readable by the system gunzip too
        let sys = try Subprocess.run("/usr/bin/gunzip", ["-c", url.path], timeout: 10)
        XCTAssertEqual(sys.status, 0)
        XCTAssertEqual(sys.stdout, NBT.encode(name: "", root: sample))
        let r = try NBT.read(url)
        XCTAssertTrue(r.gzip)
        XCTAssertEqual(r.root, sample)
        try NBT.write(url, name: "", root: .compound([]), gzip: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathExtension("craftpanel-bak").path))
    }

    func testRejectsTruncatedAndHostileLengths() {
        var d = NBT.encode(name: "", root: sample)
        d.removeLast(5)
        XCTAssertThrowsError(try NBT.decode(d))
        // byte array claiming 2^31-1 elements
        let evil = Data([10, 0, 0, 7, 0, 1, 0x78, 0x7f, 0xff, 0xff, 0xff])
        XCTAssertThrowsError(try NBT.decode(evil))
    }

    func testCRC32KnownValue() {
        XCTAssertEqual(CRC32.checksum(Array("123456789".utf8)), 0xCBF4_3926)
    }
}
