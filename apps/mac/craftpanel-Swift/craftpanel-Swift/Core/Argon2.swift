import Foundation
import Security

/// Pure-Swift Argon2id (RFC 9106, version 0x13) plus PHC-string encode/verify.
///
/// Why hand-rolled: Apple's frameworks have no Argon2 and the project takes
/// no new dependencies without sign-off. Used for the app-lock PIN
/// (same `$argon2id$v=19$m=19456,t=2,p=1$…` hash the Rust app shipped) and
/// the app-lock PIN. Verified against the RFC 9106 §5.3 test vector in
/// `Argon2Tests`.
nonisolated enum Argon2 {
    // MARK: - Public API

    static func hash(password: [UInt8], salt: [UInt8], secret: [UInt8] = [], ad: [UInt8] = [],
                     memoryKiB: Int, iterations: Int, parallelism: Int, tagLength: Int = 32) -> [UInt8] {
        let p = max(1, parallelism)
        var h0in = [UInt8]()
        for v in [UInt32(p), UInt32(tagLength), UInt32(memoryKiB), UInt32(iterations), 0x13, 2] { h0in += le32(v) }
        h0in += le32(UInt32(password.count)) + password
        h0in += le32(UInt32(salt.count)) + salt
        h0in += le32(UInt32(secret.count)) + secret
        h0in += le32(UInt32(ad.count)) + ad
        let h0 = Blake2b.hash(h0in, outLength: 64)

        let mPrime = max(8 * p, 4 * p * (memoryKiB / (4 * p)))
        let q = mPrime / p
        let segLen = q / 4
        var mem = [UInt64](repeating: 0, count: mPrime * 128)

        func store(_ bytes: [UInt8], at block: Int) {
            bytes.withUnsafeBytes { raw in
                for i in 0..<128 { mem[block * 128 + i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian }
            }
        }
        for lane in 0..<p {
            store(hPrime(h0 + le32(0) + le32(UInt32(lane)), 1024), at: lane * q)
            store(hPrime(h0 + le32(1) + le32(UInt32(lane)), 1024), at: lane * q + 1)
        }

        var tmp = [UInt64](repeating: 0, count: 128)
        var r = [UInt64](repeating: 0, count: 128)
        var zero = [UInt64](repeating: 0, count: 128)
        var input = [UInt64](repeating: 0, count: 128)
        var address = [UInt64](repeating: 0, count: 128)

        for pass in 0..<iterations {
            for slice in 0..<4 {
                for lane in 0..<p {
                    let dataIndependent = pass == 0 && slice < 2
                    if dataIndependent {
                        for i in 0..<128 { input[i] = 0; zero[i] = 0 }
                        input[0] = UInt64(pass); input[1] = UInt64(lane); input[2] = UInt64(slice)
                        input[3] = UInt64(mPrime); input[4] = UInt64(iterations); input[5] = 2
                    }
                    var start = 0
                    if pass == 0 && slice == 0 {
                        start = 2
                        if dataIndependent { nextAddresses(&address, &input, &zero, &tmp, &r) }
                    }
                    var curr = lane * q + slice * segLen + start
                    var prev = curr % q == 0 ? curr + q - 1 : curr - 1
                    for i in start..<segLen {
                        if curr % q == 1 { prev = curr - 1 }
                        let rand: UInt64
                        if dataIndependent {
                            if i % 128 == 0 { nextAddresses(&address, &input, &zero, &tmp, &r) }
                            rand = address[i % 128]
                        } else {
                            rand = mem[prev * 128]
                        }
                        var refLane = Int((rand >> 32) % UInt64(p))
                        if pass == 0 && slice == 0 { refLane = lane }
                        let sameLane = refLane == lane
                        let area: Int
                        if pass == 0 {
                            if slice == 0 { area = i - 1 }
                            else if sameLane { area = slice * segLen + i - 1 }
                            else { area = slice * segLen + (i == 0 ? -1 : 0) }
                        } else {
                            area = sameLane ? q - segLen + i - 1 : q - segLen + (i == 0 ? -1 : 0)
                        }
                        var rel = UInt64(rand & 0xffff_ffff)
                        rel = (rel &* rel) >> 32
                        let relPos = area - 1 - Int((UInt64(area) &* rel) >> 32)
                        let startPos = pass == 0 ? 0 : (slice == 3 ? 0 : (slice + 1) * segLen)
                        let refIndex = (startPos + relPos) % q
                        fillBlock(&mem, prev: prev, ref: refLane * q + refIndex, next: curr,
                                  withXor: pass != 0, &tmp, &r)
                        curr += 1
                        prev += 1
                    }
                }
            }
        }

        var c = [UInt64](repeating: 0, count: 128)
        for lane in 0..<p { for i in 0..<128 { c[i] ^= mem[(lane * q + q - 1) * 128 + i] } }
        var cBytes = [UInt8](); cBytes.reserveCapacity(1024)
        for v in c { cBytes += withUnsafeBytes(of: v.littleEndian, Array.init) }
        return hPrime(cBytes, tagLength)
    }

    /// PHC string, e.g. `$argon2id$v=19$m=19456,t=2,p=1$<salt>$<hash>`.
    static func encode(password: String, memoryKiB: Int = 19456, iterations: Int = 2, parallelism: Int = 1) -> String {
        var salt = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt)
        let tag = hash(password: Array(password.utf8), salt: salt, memoryKiB: memoryKiB, iterations: iterations, parallelism: parallelism)
        return "$argon2id$v=19$m=\(memoryKiB),t=\(iterations),p=\(parallelism)$\(b64(salt))$\(b64(tag))"
    }

    static func verify(password: String, phc: String) -> Bool {
        let parts = phc.split(separator: "$", omittingEmptySubsequences: true)
        guard parts.count == 5, parts[0] == "argon2id", parts[1] == "v=19" else { return false }
        var m = 0, t = 0, p = 0
        for kv in parts[2].split(separator: ",") {
            let pair = kv.split(separator: "=")
            guard pair.count == 2, let v = Int(pair[1]) else { return false }
            switch pair[0] { case "m": m = v; case "t": t = v; case "p": p = v; default: return false }
        }
        guard m >= 8, m <= 1 << 21, t >= 1, t <= 16, p >= 1, p <= 16,
              let salt = unb64(String(parts[3])), let want = unb64(String(parts[4])), !want.isEmpty else { return false }
        let got = hash(password: Array(password.utf8), salt: salt, memoryKiB: m, iterations: t, parallelism: p, tagLength: want.count)
        var diff: UInt8 = 0
        for (a, b) in zip(got, want) { diff |= a ^ b } // constant time
        return diff == 0 && got.count == want.count
    }

    // MARK: - Internals

    private static func le32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian, Array.init) }

    /// H' — variable-length hash (RFC 9106 §3.3).
    private static func hPrime(_ x: [UInt8], _ t: Int) -> [UInt8] {
        let input = le32(UInt32(t)) + x
        if t <= 64 { return Blake2b.hash(input, outLength: t) }
        let r = (t + 31) / 32 - 2
        var v = Blake2b.hash(input, outLength: 64)
        var out = Array(v[0..<32])
        for _ in 1..<r {
            v = Blake2b.hash(v, outLength: 64)
            out += v[0..<32]
        }
        out += Blake2b.hash(v, outLength: t - 32 * r)
        return out
    }

    private static func nextAddresses(_ address: inout [UInt64], _ input: inout [UInt64], _ zero: inout [UInt64],
                                      _ tmp: inout [UInt64], _ r: inout [UInt64]) {
        input[6] &+= 1
        compress(zero, input, into: &address, withXor: false, &tmp, &r)
        let a = address
        compress(zero, a, into: &address, withXor: false, &tmp, &r)
    }

    private static func fillBlock(_ mem: inout [UInt64], prev: Int, ref: Int, next: Int, withXor: Bool,
                                  _ tmp: inout [UInt64], _ r: inout [UInt64]) {
        for i in 0..<128 { r[i] = mem[ref * 128 + i] ^ mem[prev * 128 + i] }
        for i in 0..<128 { tmp[i] = withXor ? r[i] ^ mem[next * 128 + i] : r[i] }
        permute(&r)
        for i in 0..<128 { mem[next * 128 + i] = tmp[i] ^ r[i] }
    }

    private static func compress(_ x: [UInt64], _ y: [UInt64], into out: inout [UInt64], withXor: Bool,
                                 _ tmp: inout [UInt64], _ r: inout [UInt64]) {
        for i in 0..<128 { r[i] = x[i] ^ y[i] }
        for i in 0..<128 { tmp[i] = withXor ? r[i] ^ out[i] : r[i] }
        permute(&r)
        for i in 0..<128 { out[i] = tmp[i] ^ r[i] }
    }

    /// Apply P to the 8 rows, then the 8 columns, of the 1 KiB block.
    private static func permute(_ v: inout [UInt64]) {
        for i in 0..<8 {
            let b = 16 * i
            round(&v, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7,
                  b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15)
        }
        for i in 0..<8 {
            let b = 2 * i
            round(&v, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49,
                  b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113)
        }
    }

    @inline(__always)
    private static func round(_ v: inout [UInt64], _ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int, _ i4: Int, _ i5: Int,
                              _ i6: Int, _ i7: Int, _ i8: Int, _ i9: Int, _ i10: Int, _ i11: Int, _ i12: Int,
                              _ i13: Int, _ i14: Int, _ i15: Int) {
        gb(&v, i0, i4, i8, i12); gb(&v, i1, i5, i9, i13); gb(&v, i2, i6, i10, i14); gb(&v, i3, i7, i11, i15)
        gb(&v, i0, i5, i10, i15); gb(&v, i1, i6, i11, i12); gb(&v, i2, i7, i8, i13); gb(&v, i3, i4, i9, i14)
    }

    @inline(__always)
    private static func bla(_ a: UInt64, _ b: UInt64) -> UInt64 {
        a &+ b &+ 2 &* (a & 0xffff_ffff) &* (b & 0xffff_ffff)
    }

    @inline(__always)
    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }

    @inline(__always)
    private static func gb(_ v: inout [UInt64], _ a: Int, _ b: Int, _ c: Int, _ d: Int) {
        v[a] = bla(v[a], v[b]); v[d] = rotr(v[d] ^ v[a], 32)
        v[c] = bla(v[c], v[d]); v[b] = rotr(v[b] ^ v[c], 24)
        v[a] = bla(v[a], v[b]); v[d] = rotr(v[d] ^ v[a], 16)
        v[c] = bla(v[c], v[d]); v[b] = rotr(v[b] ^ v[c], 63)
    }

    static func b64(_ d: [UInt8]) -> String {
        Data(d).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }

    static func unb64(_ s: String) -> [UInt8]? {
        var t = s
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t).map(Array.init)
    }
}

/// BLAKE2b (RFC 7693), unkeyed, variable output length — Argon2's hash.
nonisolated enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(_ input: [UInt8], outLength: Int) -> [UInt8] {
        precondition(outLength >= 1 && outLength <= 64)
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outLength)
        var t: UInt64 = 0
        var offset = 0
        let n = input.count
        repeat {
            let remaining = n - offset
            let last = remaining <= 128
            let take = min(128, remaining)
            var block = [UInt8](repeating: 0, count: 128)
            if take > 0 { block.replaceSubrange(0..<take, with: input[offset..<(offset + take)]) }
            t &+= UInt64(take)
            compress(&h, block, t, last)
            offset += take
        } while offset < n
        var out = [UInt8]()
        for v in h { out += withUnsafeBytes(of: v.littleEndian, Array.init) }
        return Array(out[0..<outLength])
    }

    private static func compress(_ h: inout [UInt64], _ block: [UInt8], _ t: UInt64, _ last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        block.withUnsafeBytes { raw in
            for i in 0..<16 { m[i] = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self).littleEndian }
        }
        var v = h + iv
        v[12] ^= t
        if last { v[14] = ~v[14] }
        func g(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x; v[d] = rotr(v[d] ^ v[a], 32)
            v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 24)
            v[a] = v[a] &+ v[b] &+ y; v[d] = rotr(v[d] ^ v[a], 16)
            v[c] = v[c] &+ v[d];      v[b] = rotr(v[b] ^ v[c], 63)
        }
        for r in 0..<12 {
            let s = sigma[r % 10]
            g(0, 4, 8, 12, m[s[0]], m[s[1]]); g(1, 5, 9, 13, m[s[2]], m[s[3]])
            g(2, 6, 10, 14, m[s[4]], m[s[5]]); g(3, 7, 11, 15, m[s[6]], m[s[7]])
            g(0, 5, 10, 15, m[s[8]], m[s[9]]); g(1, 6, 11, 12, m[s[10]], m[s[11]])
            g(2, 7, 8, 13, m[s[12]], m[s[13]]); g(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }

    private static func rotr(_ x: UInt64, _ n: UInt64) -> UInt64 { (x >> n) | (x << (64 - n)) }
}
