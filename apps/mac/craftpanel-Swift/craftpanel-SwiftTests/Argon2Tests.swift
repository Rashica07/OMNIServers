import XCTest
@testable import craftpanel_Swift

final class Argon2Tests: XCTestCase {
    func testBlake2bKnownAnswer() {
        // RFC 7693 Appendix A: BLAKE2b-512("abc")
        let h = Blake2b.hash(Array("abc".utf8), outLength: 64).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(h, "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d17d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
    }

    /// RFC 9106 §5.3 Argon2id test vector.
    func testArgon2idRFCVector() {
        let tag = Argon2.hash(password: [UInt8](repeating: 1, count: 32), salt: [UInt8](repeating: 2, count: 16),
                              secret: [UInt8](repeating: 3, count: 8), ad: [UInt8](repeating: 4, count: 12),
                              memoryKiB: 32, iterations: 3, parallelism: 4, tagLength: 32)
        XCTAssertEqual(tag.map { String(format: "%02x", $0) }.joined(),
                       "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659")
    }

    func testEncodeVerifyRoundTrip() {
        let phc = Argon2.encode(password: "1234", memoryKiB: 64, iterations: 1)
        XCTAssertTrue(phc.hasPrefix("$argon2id$v=19$m=64,t=1,p=1$"))
        XCTAssertTrue(Argon2.verify(password: "1234", phc: phc))
        XCTAssertFalse(Argon2.verify(password: "1235", phc: phc))
        XCTAssertFalse(Argon2.verify(password: "1234", phc: "$argon2i$v=19$m=64,t=1,p=1$AAAA$AAAA"))
    }
}
