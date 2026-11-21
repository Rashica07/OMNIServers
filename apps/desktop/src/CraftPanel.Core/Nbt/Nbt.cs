using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace CraftPanel.Core.Nbt;

public enum TagType : byte { End = 0, Byte, Short, Int, Long, Float, Double, ByteArray, String, List, Compound, IntArray, LongArray }

/// <summary>One NBT value. Mutable so an editor can change it in place.</summary>
public abstract class NbtTag
{
    public abstract TagType Type { get; }
    public string TypeName => Type switch
    {
        TagType.ByteArray => "Byte[]", TagType.IntArray => "Int[]", TagType.LongArray => "Long[]", _ => Type.ToString(),
    };
}

public sealed class NbtByte(sbyte v) : NbtTag { public sbyte Value { get; set; } = v; public override TagType Type => TagType.Byte; }
public sealed class NbtShort(short v) : NbtTag { public short Value { get; set; } = v; public override TagType Type => TagType.Short; }
public sealed class NbtInt(int v) : NbtTag { public int Value { get; set; } = v; public override TagType Type => TagType.Int; }
public sealed class NbtLong(long v) : NbtTag { public long Value { get; set; } = v; public override TagType Type => TagType.Long; }
public sealed class NbtFloat(float v) : NbtTag { public float Value { get; set; } = v; public override TagType Type => TagType.Float; }
public sealed class NbtDouble(double v) : NbtTag { public double Value { get; set; } = v; public override TagType Type => TagType.Double; }
public sealed class NbtString(string v) : NbtTag { public string Value { get; set; } = v; public override TagType Type => TagType.String; }
public sealed class NbtByteArray(sbyte[] v) : NbtTag { public sbyte[] Value { get; set; } = v; public override TagType Type => TagType.ByteArray; }
public sealed class NbtIntArray(int[] v) : NbtTag { public int[] Value { get; set; } = v; public override TagType Type => TagType.IntArray; }
public sealed class NbtLongArray(long[] v) : NbtTag { public long[] Value { get; set; } = v; public override TagType Type => TagType.LongArray; }

public sealed class NbtList(TagType elementType, List<NbtTag> items) : NbtTag
{
    /// <summary>Only meaningful while empty; otherwise the first item decides what's written.</summary>
    public TagType ElementType { get; set; } = elementType;
    public List<NbtTag> Items { get; } = items;
    public override TagType Type => TagType.List;
}

/// <summary>Entries keep their file order (Minecraft doesn't care, but a minimal diff after an edit is kind).</summary>
public sealed class NbtCompound(List<KeyValuePair<string, NbtTag>> entries) : NbtTag
{
    public List<KeyValuePair<string, NbtTag>> Entries { get; } = entries;
    public override TagType Type => TagType.Compound;
}

public sealed class NbtFile(string name, NbtCompound root, bool gzip)
{
    public string Name { get; } = name;
    public NbtCompound Root { get; } = root;
    public bool Gzip { get; } = gzip;
}

public sealed class NbtException(string message) : Exception("Not a valid NBT file: " + message);

/// <summary>
/// Generic Java-edition NBT (big-endian; <c>level.dat</c>, <c>playerdata/*.dat</c>, structure <c>.nbt</c>), gzip or plain, written back
/// the way it was read. Strings use Java's "modified UTF-8" (NUL as C0 80, supplementary characters as surrogate pairs), so
/// world names and signs containing emoji survive a load/save unchanged.
/// </summary>
public static class Nbt
{
    const int MaxDepth = 512;
    const long MaxUncompressed = 256L << 20;

    // ---- files ----------------------------------------------------------------------------------

    public static NbtFile Read(string path) => ReadBytes(File.ReadAllBytes(path));

    /// <summary>Reads NBT from memory (gzip or plain), e.g. a <c>level.dat</c> pulled out of a zip.</summary>
    public static NbtFile ReadBytes(byte[] raw)
    {
        var gz = raw.Length > 2 && raw[0] == 0x1f && raw[1] == 0x8b;
        return Decode(gz ? Gunzip(raw) : raw, gz);
    }

    /// <summary>Atomic write; the previous file is kept as <c>&lt;name&gt;.craftpanel-bak</c>.</summary>
    public static void Write(string path, NbtFile file)
    {
        var data = Encode(file.Name, file.Root);
        if (file.Gzip) data = Gzip(data);
        if (File.Exists(path)) File.Copy(path, path + ".craftpanel-bak", overwrite: true);
        var tmp = path + ".tmp-" + Environment.ProcessId;
        File.WriteAllBytes(tmp, data);
        File.Move(tmp, path, overwrite: true);
    }

    static byte[] Gunzip(byte[] raw)
    {
        try
        {
            using var z = new GZipStream(new MemoryStream(raw), CompressionMode.Decompress);
            using var ms = new MemoryStream();
            var buf = new byte[81920];
            int n;
            while ((n = z.Read(buf, 0, buf.Length)) > 0)
            {
                ms.Write(buf, 0, n);
                if (ms.Length > MaxUncompressed) throw new NbtException("decompresses to an unreasonable size");
            }
            return ms.ToArray();
        }
        catch (InvalidDataException) { throw new NbtException("bad gzip data"); }
    }

    static byte[] Gzip(byte[] data)
    {
        using var ms = new MemoryStream();
        using (var z = new GZipStream(ms, CompressionLevel.Optimal, leaveOpen: true)) z.Write(data);
        return ms.ToArray();
    }

    // ---- decode ---------------------------------------------------------------------------------

    public static NbtFile Decode(byte[] bytes, bool gzip = false)
    {
        var r = new Reader(bytes);
        if (r.U8() != (byte)TagType.Compound) throw new NbtException("the root isn't a compound");
        var name = r.Str();
        return new NbtFile(name, (NbtCompound)r.Payload(TagType.Compound, 0), gzip);
    }

    sealed class Reader(byte[] b)
    {
        int _i;

        ReadOnlySpan<byte> Take(int n)
        {
            if (n < 0 || _i + n > b.Length) throw new NbtException("unexpected end of data");
            var s = new ReadOnlySpan<byte>(b, _i, n);
            _i += n;
            return s;
        }

        public byte U8() => Take(1)[0];
        short I16() => BinaryPrimitives.ReadInt16BigEndian(Take(2));
        int I32() => BinaryPrimitives.ReadInt32BigEndian(Take(4));
        long I64() => BinaryPrimitives.ReadInt64BigEndian(Take(8));

        /// <summary>An array/list length, checked against what's left so a lying header can't make us allocate gigabytes.</summary>
        int Count(int elementSize)
        {
            var n = I32();
            if (n < 0 || (long)n * elementSize > b.Length - _i) throw new NbtException($"bad length {n}");
            return n;
        }

        public string Str() => ModifiedUtf8.Decode(Take(BinaryPrimitives.ReadUInt16BigEndian(Take(2))));

        public NbtTag Payload(TagType t, int depth)
        {
            if (depth > MaxDepth) throw new NbtException("nested too deep");
            switch (t)
            {
                case TagType.Byte: return new NbtByte((sbyte)U8());
                case TagType.Short: return new NbtShort(I16());
                case TagType.Int: return new NbtInt(I32());
                case TagType.Long: return new NbtLong(I64());
                case TagType.Float: return new NbtFloat(BitConverter.Int32BitsToSingle(I32()));
                case TagType.Double: return new NbtDouble(BitConverter.Int64BitsToDouble(I64()));
                case TagType.ByteArray:
                {
                    var n = Count(1);
                    var a = new sbyte[n];
                    var s = Take(n);
                    for (var i = 0; i < n; i++) a[i] = (sbyte)s[i];
                    return new NbtByteArray(a);
                }
                case TagType.String: return new NbtString(Str());
                case TagType.List:
                {
                    var et = (TagType)U8();
                    var n = Count(1);
                    if (et is < TagType.End or > TagType.LongArray || (et == TagType.End && n > 0)) throw new NbtException($"bad list type {(byte)et}");
                    var items = new List<NbtTag>(Math.Min(n, 4096));
                    for (var i = 0; i < n; i++) items.Add(Payload(et, depth + 1));
                    return new NbtList(et, items);
                }
                case TagType.Compound:
                {
                    var kv = new List<KeyValuePair<string, NbtTag>>();
                    while (true)
                    {
                        var ct = (TagType)U8();
                        if (ct == TagType.End) break;
                        if (ct > TagType.LongArray) throw new NbtException($"unknown tag {(byte)ct}");
                        var k = Str();
                        kv.Add(new(k, Payload(ct, depth + 1)));
                    }
                    return new NbtCompound(kv);
                }
                case TagType.IntArray:
                {
                    var n = Count(4);
                    var a = new int[n];
                    for (var i = 0; i < n; i++) a[i] = I32();
                    return new NbtIntArray(a);
                }
                case TagType.LongArray:
                {
                    var n = Count(8);
                    var a = new long[n];
                    for (var i = 0; i < n; i++) a[i] = I64();
                    return new NbtLongArray(a);
                }
                default: throw new NbtException($"unknown tag {(byte)t}");
            }
        }
    }

    // ---- encode ---------------------------------------------------------------------------------

    public static byte[] Encode(string name, NbtCompound root)
    {
        using var ms = new MemoryStream();
        ms.WriteByte((byte)TagType.Compound);
        PutStr(ms, name);
        Put(ms, root);
        return ms.ToArray();
    }

    static void PutStr(Stream s, string v)
    {
        var b = ModifiedUtf8.Encode(v);
        if (b.Length > ushort.MaxValue) throw new NbtException("a string is too long to store");
        Span<byte> len = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)b.Length);
        s.Write(len);
        s.Write(b);
    }

    static void I32(Stream s, int v) { Span<byte> x = stackalloc byte[4]; BinaryPrimitives.WriteInt32BigEndian(x, v); s.Write(x); }
    static void I64(Stream s, long v) { Span<byte> x = stackalloc byte[8]; BinaryPrimitives.WriteInt64BigEndian(x, v); s.Write(x); }

    static void Put(Stream s, NbtTag t)
    {
        switch (t)
        {
            case NbtByte v: s.WriteByte((byte)v.Value); break;
            case NbtShort v: { Span<byte> x = stackalloc byte[2]; BinaryPrimitives.WriteInt16BigEndian(x, v.Value); s.Write(x); break; }
            case NbtInt v: I32(s, v.Value); break;
            case NbtLong v: I64(s, v.Value); break;
            case NbtFloat v: I32(s, BitConverter.SingleToInt32Bits(v.Value)); break;
            case NbtDouble v: I64(s, BitConverter.DoubleToInt64Bits(v.Value)); break;
            case NbtString v: PutStr(s, v.Value); break;
            case NbtByteArray v: I32(s, v.Value.Length); foreach (var x in v.Value) s.WriteByte((byte)x); break;
            case NbtIntArray v: I32(s, v.Value.Length); foreach (var x in v.Value) I32(s, x); break;
            case NbtLongArray v: I64Array(s, v.Value); break;
            case NbtList v:
                s.WriteByte((byte)(v.Items.Count == 0 ? v.ElementType : v.Items[0].Type));
                I32(s, v.Items.Count);
                foreach (var i in v.Items) Put(s, i);
                break;
            case NbtCompound v:
                foreach (var (k, val) in v.Entries) { s.WriteByte((byte)val.Type); PutStr(s, k); Put(s, val); }
                s.WriteByte(0);
                break;
            default: throw new NbtException("unknown tag");
        }
    }

    static void I64Array(Stream s, long[] a) { I32(s, a.Length); foreach (var x in a) I64(s, x); }
}

/// <summary>Java's "modified UTF-8" as used by NBT and DataOutput.writeUTF.</summary>
public static class ModifiedUtf8
{
    public static byte[] Encode(string s)
    {
        var o = new List<byte>(s.Length + 8);
        foreach (var c in s)
        {
            if (c != 0 && c < 0x80) o.Add((byte)c);
            else if (c < 0x800) { o.Add((byte)(0xC0 | (c >> 6))); o.Add((byte)(0x80 | (c & 0x3F))); }
            else { o.Add((byte)(0xE0 | (c >> 12))); o.Add((byte)(0x80 | ((c >> 6) & 0x3F))); o.Add((byte)(0x80 | (c & 0x3F))); }
        }
        return [.. o];
    }

    public static string Decode(ReadOnlySpan<byte> b)
    {
        var sb = new StringBuilder(b.Length);
        for (var i = 0; i < b.Length;)
        {
            int c = b[i];
            if (c < 0x80) { sb.Append((char)c); i++; }
            else if ((c & 0xE0) == 0xC0 && i + 1 < b.Length) { sb.Append((char)(((c & 0x1F) << 6) | (b[i + 1] & 0x3F))); i += 2; }
            else if ((c & 0xF0) == 0xE0 && i + 2 < b.Length) { sb.Append((char)(((c & 0x0F) << 12) | ((b[i + 1] & 0x3F) << 6) | (b[i + 2] & 0x3F))); i += 3; }
            else
            {
                // Plain 4-byte UTF-8 (not valid modified UTF-8, but some tools write it): decode it rather than fail.
                if ((c & 0xF8) == 0xF0 && i + 3 < b.Length)
                {
                    var cp = ((c & 0x07) << 18) | ((b[i + 1] & 0x3F) << 12) | ((b[i + 2] & 0x3F) << 6) | (b[i + 3] & 0x3F);
                    sb.Append(char.ConvertFromUtf32(cp)); i += 4;
                }
                else { sb.Append('�'); i++; }
            }
        }
        return sb.ToString();
    }
}
