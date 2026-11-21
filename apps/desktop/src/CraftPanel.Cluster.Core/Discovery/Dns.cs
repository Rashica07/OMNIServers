using System.Buffers.Binary;
using System.Net;
using System.Text;

namespace CraftPanel.Cluster.Discovery;

/// <summary>
/// The small slice of DNS that multicast DNS service discovery (RFC 6762 / 6763) needs: PTR, SRV, TXT and A records, with
/// name compression on read. Built by hand so the cluster feature adds no dependency. Everything that comes off the network
/// goes through <see cref="DnsMessage.TryParse"/>, which never throws: a malformed packet is just "not for us".
/// </summary>
internal enum DnsType : ushort { A = 1, Ptr = 12, Txt = 16, Aaaa = 28, Srv = 33 }

internal sealed record DnsQuestion(string Name, ushort Type, ushort Class = 1);

internal abstract record DnsRecord(string Name, uint Ttl)
{
    /// <summary>The cache-flush bit mDNS sets on records that are unique to a host.</summary>
    public bool CacheFlush { get; init; }
}
internal sealed record PtrRecord(string Name, string Target, uint Ttl) : DnsRecord(Name, Ttl);
internal sealed record SrvRecord(string Name, ushort Port, string Target, uint Ttl) : DnsRecord(Name, Ttl);
internal sealed record TxtRecord(string Name, IReadOnlyDictionary<string, string> Values, uint Ttl) : DnsRecord(Name, Ttl);
internal sealed record ARecord(string Name, IPAddress Address, uint Ttl) : DnsRecord(Name, Ttl);

internal sealed class DnsMessage
{
    public bool IsResponse { get; init; }
    public List<DnsQuestion> Questions { get; } = [];
    /// <summary>Answer, authority and additional records, all together: for service discovery the distinction doesn't matter.</summary>
    public List<DnsRecord> Records { get; } = [];

    public const int MaxPacket = 9000;
    const int MaxRecords = 64;
    const int MaxNameJumps = 16;

    // ---- write ---------------------------------------------------------------------------------

    public byte[] Write()
    {
        using var ms = new MemoryStream();
        Span<byte> h = stackalloc byte[12];
        h.Clear();
        BinaryPrimitives.WriteUInt16BigEndian(h[2..], (ushort)(IsResponse ? 0x8400 : 0));   // QR (+ AA for a response)
        BinaryPrimitives.WriteUInt16BigEndian(h[4..], (ushort)Questions.Count);
        BinaryPrimitives.WriteUInt16BigEndian(h[6..], (ushort)(IsResponse ? Records.Count : 0));
        BinaryPrimitives.WriteUInt16BigEndian(h[10..], (ushort)(IsResponse ? 0 : Records.Count));
        ms.Write(h);
        foreach (var q in Questions) { WriteName(ms, q.Name); WriteU16(ms, q.Type); WriteU16(ms, q.Class); }
        foreach (var r in Records) WriteRecord(ms, r);
        return ms.ToArray();
    }

    static void WriteU16(Stream s, ushort v) { Span<byte> b = stackalloc byte[2]; BinaryPrimitives.WriteUInt16BigEndian(b, v); s.Write(b); }
    static void WriteU32(Stream s, uint v) { Span<byte> b = stackalloc byte[4]; BinaryPrimitives.WriteUInt32BigEndian(b, v); s.Write(b); }

    internal static void WriteName(Stream s, string name)
    {
        var total = 1;
        foreach (var label in name.TrimEnd('.').Split('.', StringSplitOptions.RemoveEmptyEntries))
        {
            var b = Encoding.UTF8.GetBytes(label);
            if (b.Length is 0 or > 63) throw new ArgumentException($"bad DNS label '{label}'");
            total += 1 + b.Length;
            if (total > 255) throw new ArgumentException("DNS name too long");
            s.WriteByte((byte)b.Length);
            s.Write(b);
        }
        s.WriteByte(0);
    }

    static void WriteRecord(Stream s, DnsRecord r)
    {
        WriteName(s, r.Name);
        using var data = new MemoryStream();
        ushort type;
        switch (r)
        {
            case PtrRecord p: type = (ushort)DnsType.Ptr; WriteName(data, p.Target); break;
            case SrvRecord v: type = (ushort)DnsType.Srv; WriteU16(data, 0); WriteU16(data, 0); WriteU16(data, v.Port); WriteName(data, v.Target); break;
            case TxtRecord t:
                type = (ushort)DnsType.Txt;
                foreach (var (k, val) in t.Values)
                {
                    var b = Encoding.UTF8.GetBytes($"{k}={val}");
                    if (b.Length > 255) b = b[..255];
                    data.WriteByte((byte)b.Length); data.Write(b);
                }
                if (t.Values.Count == 0) data.WriteByte(0);
                break;
            case ARecord a when a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork:
                type = (ushort)DnsType.A; data.Write(a.Address.GetAddressBytes()); break;
            default: throw new ArgumentException("unsupported record");
        }
        WriteU16(s, type);
        WriteU16(s, (ushort)(r.CacheFlush ? 0x8001 : 1));
        WriteU32(s, r.Ttl);
        WriteU16(s, (ushort)data.Length);
        data.WriteTo(s);
    }

    // ---- read ----------------------------------------------------------------------------------

    /// <summary>Parses a packet. Returns false for anything malformed, truncated, oversized or not mDNS-shaped.</summary>
    public static bool TryParse(ReadOnlySpan<byte> p, out DnsMessage message)
    {
        message = null!;
        try
        {
            if (p.Length < 12 || p.Length > MaxPacket) return false;
            var flags = BinaryPrimitives.ReadUInt16BigEndian(p[2..]);
            int qd = BinaryPrimitives.ReadUInt16BigEndian(p[4..]), an = BinaryPrimitives.ReadUInt16BigEndian(p[6..]),
                ns = BinaryPrimitives.ReadUInt16BigEndian(p[8..]), ar = BinaryPrimitives.ReadUInt16BigEndian(p[10..]);
            if (qd > MaxRecords || an + ns + ar > MaxRecords * 3) return false;
            if ((flags & 0x7800) != 0) return false;               // opcode must be 0 (a standard query / response)
            var m = new DnsMessage { IsResponse = (flags & 0x8000) != 0 };
            var pos = 12;
            for (var i = 0; i < qd; i++)
            {
                var name = ReadName(p, ref pos);
                if (name is null || pos + 4 > p.Length) return false;
                m.Questions.Add(new DnsQuestion(name, BinaryPrimitives.ReadUInt16BigEndian(p[pos..]), (ushort)(BinaryPrimitives.ReadUInt16BigEndian(p[(pos + 2)..]) & 0x7fff)));
                pos += 4;
            }
            for (var i = 0; i < an + ns + ar; i++)
            {
                var name = ReadName(p, ref pos);
                if (name is null || pos + 10 > p.Length) return false;
                var type = BinaryPrimitives.ReadUInt16BigEndian(p[pos..]);
                var cls = BinaryPrimitives.ReadUInt16BigEndian(p[(pos + 2)..]);
                var ttl = BinaryPrimitives.ReadUInt32BigEndian(p[(pos + 4)..]);
                int len = BinaryPrimitives.ReadUInt16BigEndian(p[(pos + 8)..]);
                pos += 10;
                if (pos + len > p.Length) return false;
                var rdStart = pos;
                var rec = ReadRecord(p, type, name, ttl, rdStart, len);
                if (rec is not null) m.Records.Add(Flag(rec, cls));
                pos += len;
            }
            message = m;
            return true;
        }
        catch (Exception e) when (e is ArgumentException or IndexOutOfRangeException or ArgumentOutOfRangeException) { return false; }
    }

    static DnsRecord Flag(DnsRecord r, ushort cls) => r with { CacheFlush = (cls & 0x8000) != 0 };

    static DnsRecord? ReadRecord(ReadOnlySpan<byte> p, ushort type, string name, uint ttl, int pos, int len)
    {
        switch ((DnsType)type)
        {
            case DnsType.Ptr: { var q = pos; var t = ReadName(p, ref q); return t is null ? null : new PtrRecord(name, t, ttl); }
            case DnsType.Srv:
            {
                if (len < 7) return null;
                var port = BinaryPrimitives.ReadUInt16BigEndian(p[(pos + 4)..]);
                var q = pos + 6; var t = ReadName(p, ref q);
                return t is null ? null : new SrvRecord(name, port, t, ttl);
            }
            case DnsType.Txt:
            {
                var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                var end = pos + len;
                for (var q = pos; q < end;)
                {
                    int l = p[q++];
                    if (q + l > end) return null;
                    var s = Encoding.UTF8.GetString(p.Slice(q, l)); q += l;
                    var eq = s.IndexOf('=');
                    if (eq > 0 && d.Count < 32) d[s[..eq]] = s[(eq + 1)..];
                }
                return new TxtRecord(name, d, ttl);
            }
            case DnsType.A: return len == 4 ? new ARecord(name, new IPAddress(p.Slice(pos, 4)), ttl) : null;
            default: return null;   // AAAA and anything else: skipped, not an error
        }
    }

    /// <summary>Reads a possibly compressed name. Pointers may only go backwards and are followed a bounded number of times.</summary>
    static string? ReadName(ReadOnlySpan<byte> p, ref int pos)
    {
        var sb = new StringBuilder();
        var cur = pos;
        var jumped = false;
        var jumps = 0;
        while (true)
        {
            if (cur >= p.Length) return null;
            int l = p[cur];
            if (l == 0) { cur++; break; }
            if ((l & 0xC0) == 0xC0)
            {
                if (cur + 1 >= p.Length) return null;
                var target = ((l & 0x3F) << 8) | p[cur + 1];
                if (!jumped) pos = cur + 2;
                jumped = true;
                if (++jumps > MaxNameJumps || target >= cur) return null;     // loops and forward pointers are never legitimate
                cur = target;
                continue;
            }
            if ((l & 0xC0) != 0 || cur + 1 + l > p.Length) return null;
            if (sb.Length + l + 1 > 255) return null;
            if (sb.Length > 0) sb.Append('.');
            sb.Append(Encoding.UTF8.GetString(p.Slice(cur + 1, l)));
            cur += 1 + l;
        }
        if (!jumped) pos = cur;
        return sb.ToString();
    }
}
