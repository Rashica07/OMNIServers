import Foundation
import Compression

/// Generic NBT read/write (`level.dat`, `playerdata/*.dat`) — port of
/// `nbt.rs` (which used the `fastnbt` crate). Not schema-aware: a faithful
/// tree the file browser can show and edit. Big-endian Java NBT, gzip or
/// uncompressed; the file is written back in the same form it was read.
/// Strings are treated as UTF-8 (Java's "modified UTF-8" only differs for
/// NUL and 4-byte characters, which Minecraft's own data doesn't use).
nonisolated indirect enum NBTNode: Equatable, Sendable {
    case byte(Int8), short(Int16), int(Int32), long(Int64), float(Float), double(Double)
    case byteArray([Int8]), string(String)
    case list(elementType: UInt8, [NBTNode])
    case compound([(String, NBTNode)])
    case intArray([Int32]), longArray([Int64])

    static func == (a: NBTNode, b: NBTNode) -> Bool {
        switch (a, b) {
        case let (.byte(x), .byte(y)): x == y
        case let (.short(x), .short(y)): x == y
        case let (.int(x), .int(y)): x == y
        case let (.long(x), .long(y)): x == y
        case let (.float(x), .float(y)): x.bitPattern == y.bitPattern
        case let (.double(x), .double(y)): x.bitPattern == y.bitPattern
        case let (.byteArray(x), .byteArray(y)): x == y
        case let (.string(x), .string(y)): x == y
        case let (.list(t1, x), .list(t2, y)): t1 == t2 && x == y
        case let (.compound(x), .compound(y)): x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.intArray(x), .intArray(y)): x == y
        case let (.longArray(x), .longArray(y)): x == y
        default: false
        }
    }

    var typeID: UInt8 {
        switch self {
        case .byte: 1
        case .short: 2
        case .int: 3
        case .long: 4
        case .float: 5
        case .double: 6
        case .byteArray: 7
        case .string: 8
        case .list: 9
        case .compound: 10
        case .intArray: 11
        case .longArray: 12
        }
    }

    var typeName: String {
        ["", "Byte", "Short", "Int", "Long", "Float", "Double", "Byte[]", "String", "List", "Compound", "Int[]", "Long[]"][Int(typeID)]
    }
}

nonisolated enum NBT {
    enum NBTError: LocalizedError {
        case malformed(String)
        var errorDescription: String? { if case .malformed(let m) = self { "Not a valid NBT file: \(m)" } else { nil } }
    }

    // MARK: File I/O

    /// Returns the root (name, node) and whether the file was gzipped.
    static func read(_ url: URL) throws -> (name: String, root: NBTNode, gzip: Bool) {
        let raw = try Data(contentsOf: url)
        let gz = raw.count > 2 && raw[raw.startIndex] == 0x1f && raw[raw.startIndex + 1] == 0x8b
        guard let data = gz ? Gzip.decompress(raw) : raw else { throw NBTError.malformed("bad gzip data") }
        let (name, root) = try decode(data)
        return (name, root, gz)
    }

    /// Atomic write; the previous file is kept as `<name>.craftpanel-bak`.
    static func write(_ url: URL, name: String, root: NBTNode, gzip: Bool) throws {
        var data = encode(name: name, root: root)
        if gzip { data = try GzipWriter.compress(data) }
        let fm = FileManager.default
        let bak = url.appendingPathExtension("craftpanel-bak")
        if fm.fileExists(atPath: url.path) {
            try? fm.removeItem(at: bak) // our own previous backup copy only
            try fm.copyItem(at: url, to: bak)
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Decode

    static func decode(_ data: Data) throws -> (String, NBTNode) {
        var r = Reader(bytes: [UInt8](data))
        let type = try r.u8()
        guard type == 10 else { throw NBTError.malformed("root isn't a compound") }
        let name = try r.string()
        return (name, try r.payload(type, depth: 0))
    }

    private struct Reader {
        let bytes: [UInt8]
        var i = 0

        mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, i + n <= bytes.count else { throw NBTError.malformed("unexpected end of data") }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
        mutating func u8() throws -> UInt8 { try take(1).first! }
        mutating func be<T: FixedWidthInteger>(_: T.Type) throws -> T {
            try take(MemoryLayout<T>.size).reduce(T(0)) { $0 << 8 | T(truncatingIfNeeded: $1) }
        }
        mutating func string() throws -> String {
            let n = Int(try be(UInt16.self))
            return String(decoding: try take(n), as: UTF8.self)
        }
        mutating func count() throws -> Int {
            let n = Int(try be(Int32.self))
            guard n >= 0, n <= bytes.count - i else { throw NBTError.malformed("bad length \(n)") }
            return n
        }

        mutating func payload(_ t: UInt8, depth: Int) throws -> NBTNode {
            guard depth < 512 else { throw NBTError.malformed("nested too deep") }
            switch t {
            case 1: return .byte(Int8(bitPattern: try u8()))
            case 2: return .short(try be(Int16.self))
            case 3: return .int(try be(Int32.self))
            case 4: return .long(try be(Int64.self))
            case 5: return .float(Float(bitPattern: try be(UInt32.self)))
            case 6: return .double(Double(bitPattern: try be(UInt64.self)))
            case 7: return .byteArray(try take(try count()).map { Int8(bitPattern: $0) })
            case 8: return .string(try string())
            case 9:
                let et = try u8()
                let n = try count()
                var items: [NBTNode] = []
                items.reserveCapacity(min(n, 4096))
                for _ in 0..<n { items.append(try payload(et, depth: depth + 1)) }
                return .list(elementType: et, items)
            case 10:
                var kv: [(String, NBTNode)] = []
                while true {
                    let ct = try u8()
                    if ct == 0 { break }
                    let k = try string()
                    kv.append((k, try payload(ct, depth: depth + 1)))
                }
                return .compound(kv)
            case 11:
                let n = try count()
                return .intArray(try (0..<n).map { _ in try be(Int32.self) })
            case 12:
                let n = try count()
                return .longArray(try (0..<n).map { _ in try be(Int64.self) })
            default: throw NBTError.malformed("unknown tag \(t)")
            }
        }
    }

    // MARK: Encode

    static func encode(name: String, root: NBTNode) -> Data {
        var out = [UInt8]()
        out.append(root.typeID)
        putString(&out, name)
        putPayload(&out, root)
        return Data(out)
    }

    private static func put<T: FixedWidthInteger>(_ out: inout [UInt8], _ v: T) {
        withUnsafeBytes(of: v.bigEndian) { out += $0 }
    }

    private static func putString(_ out: inout [UInt8], _ s: String) {
        let b = Array(s.utf8.prefix(Int(UInt16.max)))
        put(&out, UInt16(b.count)); out += b
    }

    private static func putPayload(_ out: inout [UInt8], _ n: NBTNode) {
        switch n {
        case .byte(let v): out.append(UInt8(bitPattern: v))
        case .short(let v): put(&out, v)
        case .int(let v): put(&out, v)
        case .long(let v): put(&out, v)
        case .float(let v): put(&out, v.bitPattern)
        case .double(let v): put(&out, v.bitPattern)
        case .byteArray(let a): put(&out, Int32(a.count)); out += a.map { UInt8(bitPattern: $0) }
        case .string(let s): putString(&out, s)
        case .list(let et, let items):
            out.append(items.isEmpty ? et : items[0].typeID)
            put(&out, Int32(items.count))
            for i in items { putPayload(&out, i) }
        case .compound(let kv):
            for (k, v) in kv { out.append(v.typeID); putString(&out, k); putPayload(&out, v) }
            out.append(0)
        case .intArray(let a): put(&out, Int32(a.count)); for v in a { put(&out, v) }
        case .longArray(let a): put(&out, Int32(a.count)); for v in a { put(&out, v) }
        }
    }
}

/// gzip writer (RFC 1952) over the Compression framework's raw DEFLATE.
nonisolated enum GzipWriter {
    static func compress(_ data: Data) throws -> Data {
        let src = [UInt8](data)
        let cap = max(64, src.count + src.count / 10 + 1024)
        var dst = [UInt8](repeating: 0, count: cap)
        let n = compression_encode_buffer(&dst, cap, src, src.count, nil, COMPRESSION_ZLIB)
        guard n > 0 || src.isEmpty else { throw NBT.NBTError.malformed("compression failed") }
        var out: [UInt8] = [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0xff]
        out += dst[0..<n]
        withUnsafeBytes(of: CRC32.checksum(src).littleEndian) { out += $0 }
        withUnsafeBytes(of: UInt32(truncatingIfNeeded: src.count).littleEndian) { out += $0 }
        return Data(out)
    }
}

nonisolated enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
