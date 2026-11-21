using System.Buffers.Binary;
using System.Numerics;
using System.Security.Cryptography;
using System.Text;

namespace CraftPanel.Core.Security;

/// <summary>Argon2id (RFC 9106) in plain C#, plus the PHC string format. No dependency; checked against the RFC's test vector.</summary>
public static class Argon2
{
    public static byte[] Hash(byte[] password, byte[] salt, int memoryKiB, int iterations, int parallelism, int tagLength = 32, byte[]? secret = null, byte[]? ad = null)
    {
        secret ??= []; ad ??= [];
        var p = Math.Max(1, parallelism);
        var h0in = new List<byte>();
        foreach (var v in new uint[] { (uint)p, (uint)tagLength, (uint)memoryKiB, (uint)iterations, 0x13, 2 }) h0in.AddRange(Le32(v));
        h0in.AddRange(Le32((uint)password.Length)); h0in.AddRange(password);
        h0in.AddRange(Le32((uint)salt.Length)); h0in.AddRange(salt);
        h0in.AddRange(Le32((uint)secret.Length)); h0in.AddRange(secret);
        h0in.AddRange(Le32((uint)ad.Length)); h0in.AddRange(ad);
        var h0 = Blake2b.Hash(h0in.ToArray(), 64);

        var mPrime = Math.Max(8 * p, 4 * p * (memoryKiB / (4 * p)));
        var q = mPrime / p;
        var segLen = q / 4;
        var mem = new ulong[mPrime * 128];

        void Store(byte[] bytes, int block) { for (var i = 0; i < 128; i++) mem[block * 128 + i] = BinaryPrimitives.ReadUInt64LittleEndian(bytes.AsSpan(i * 8)); }
        for (var lane = 0; lane < p; lane++)
        {
            Store(HPrime(Concat(h0, Le32(0), Le32((uint)lane)), 1024), lane * q);
            Store(HPrime(Concat(h0, Le32(1), Le32((uint)lane)), 1024), lane * q + 1);
        }

        var tmp = new ulong[128]; var r = new ulong[128]; var zero = new ulong[128]; var input = new ulong[128]; var address = new ulong[128];

        for (var pass = 0; pass < iterations; pass++)
            for (var slice = 0; slice < 4; slice++)
                for (var lane = 0; lane < p; lane++)
                {
                    var dataIndependent = pass == 0 && slice < 2;
                    if (dataIndependent)
                    {
                        Array.Clear(input); Array.Clear(zero);
                        input[0] = (ulong)pass; input[1] = (ulong)lane; input[2] = (ulong)slice; input[3] = (ulong)mPrime; input[4] = (ulong)iterations; input[5] = 2;
                    }
                    var start = 0;
                    if (pass == 0 && slice == 0)
                    {
                        start = 2;
                        if (dataIndependent) NextAddresses(address, input, zero, tmp, r);
                    }
                    var curr = lane * q + slice * segLen + start;
                    var prev = curr % q == 0 ? curr + q - 1 : curr - 1;
                    for (var i = start; i < segLen; i++)
                    {
                        if (curr % q == 1) prev = curr - 1;
                        ulong rand;
                        if (dataIndependent)
                        {
                            if (i % 128 == 0) NextAddresses(address, input, zero, tmp, r);
                            rand = address[i % 128];
                        }
                        else rand = mem[prev * 128];
                        var refLane = (int)((rand >> 32) % (ulong)p);
                        if (pass == 0 && slice == 0) refLane = lane;
                        var sameLane = refLane == lane;
                        int area;
                        if (pass == 0)
                        {
                            if (slice == 0) area = i - 1;
                            else if (sameLane) area = slice * segLen + i - 1;
                            else area = slice * segLen + (i == 0 ? -1 : 0);
                        }
                        else area = sameLane ? q - segLen + i - 1 : q - segLen + (i == 0 ? -1 : 0);
                        var rel = rand & 0xffff_ffff;
                        rel = (rel * rel) >> 32;
                        var relPos = area - 1 - (int)(((ulong)area * rel) >> 32);
                        var startPos = pass == 0 ? 0 : (slice == 3 ? 0 : (slice + 1) * segLen);
                        var refIndex = (startPos + relPos) % q;
                        FillBlock(mem, prev, refLane * q + refIndex, curr, pass != 0, tmp, r);
                        curr++; prev++;
                    }
                }

        var c = new ulong[128];
        for (var lane = 0; lane < p; lane++) for (var i = 0; i < 128; i++) c[i] ^= mem[(lane * q + q - 1) * 128 + i];
        var cBytes = new byte[1024];
        for (var i = 0; i < 128; i++) BinaryPrimitives.WriteUInt64LittleEndian(cBytes.AsSpan(i * 8), c[i]);
        return HPrime(cBytes, tagLength);
    }

    public static string Encode(string password, int memoryKiB = 19456, int iterations = 2, int parallelism = 1)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        var tag = Hash(Encoding.UTF8.GetBytes(password), salt, memoryKiB, iterations, parallelism);
        return $"$argon2id$v=19$m={memoryKiB},t={iterations},p={parallelism}${B64(salt)}${B64(tag)}";
    }

    public static bool Verify(string password, string phc)
    {
        var parts = phc.Split('$', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 5 || parts[0] != "argon2id" || parts[1] != "v=19") return false;
        int m = 0, t = 0, p = 0;
        foreach (var kv in parts[2].Split(','))
        {
            var pair = kv.Split('=');
            if (pair.Length != 2 || !int.TryParse(pair[1], out var v)) return false;
            switch (pair[0]) { case "m": m = v; break; case "t": t = v; break; case "p": p = v; break; default: return false; }
        }
        if (m < 8 || m > 1 << 21 || t < 1 || t > 16 || p < 1 || p > 16) return false;
        var salt = Unb64(parts[3]); var want = Unb64(parts[4]);
        if (salt is null || want is null || want.Length == 0) return false;
        var got = Hash(Encoding.UTF8.GetBytes(password), salt, m, t, p, want.Length);
        return CryptographicOperations.FixedTimeEquals(got, want);
    }

    // ---- internals -----------------------------------------------------------------------

    static byte[] Le32(uint v) { var b = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(b, v); return b; }
    static byte[] Concat(params byte[][] parts) => parts.SelectMany(x => x).ToArray();

    static byte[] HPrime(byte[] x, int t)
    {
        var input = Concat(Le32((uint)t), x);
        if (t <= 64) return Blake2b.Hash(input, t);
        var r = (t + 31) / 32 - 2;
        var v = Blake2b.Hash(input, 64);
        var outp = new List<byte>(v.Take(32));
        for (var i = 1; i < r; i++) { v = Blake2b.Hash(v, 64); outp.AddRange(v.Take(32)); }
        outp.AddRange(Blake2b.Hash(v, t - 32 * r));
        return outp.ToArray();
    }

    static void NextAddresses(ulong[] address, ulong[] input, ulong[] zero, ulong[] tmp, ulong[] r)
    {
        input[6]++;
        Compress(zero, input, address, false, tmp, r);
        var a = (ulong[])address.Clone();
        Compress(zero, a, address, false, tmp, r);
    }

    static void FillBlock(ulong[] mem, int prev, int reference, int next, bool withXor, ulong[] tmp, ulong[] r)
    {
        for (var i = 0; i < 128; i++) r[i] = mem[reference * 128 + i] ^ mem[prev * 128 + i];
        for (var i = 0; i < 128; i++) tmp[i] = withXor ? r[i] ^ mem[next * 128 + i] : r[i];
        Permute(r);
        for (var i = 0; i < 128; i++) mem[next * 128 + i] = tmp[i] ^ r[i];
    }

    static void Compress(ulong[] x, ulong[] y, ulong[] outp, bool withXor, ulong[] tmp, ulong[] r)
    {
        for (var i = 0; i < 128; i++) r[i] = x[i] ^ y[i];
        for (var i = 0; i < 128; i++) tmp[i] = withXor ? r[i] ^ outp[i] : r[i];
        Permute(r);
        for (var i = 0; i < 128; i++) outp[i] = tmp[i] ^ r[i];
    }

    static void Permute(ulong[] v)
    {
        for (var i = 0; i < 8; i++) { var b = 16 * i; Round(v, b, b + 1, b + 2, b + 3, b + 4, b + 5, b + 6, b + 7, b + 8, b + 9, b + 10, b + 11, b + 12, b + 13, b + 14, b + 15); }
        for (var i = 0; i < 8; i++) { var b = 2 * i; Round(v, b, b + 1, b + 16, b + 17, b + 32, b + 33, b + 48, b + 49, b + 64, b + 65, b + 80, b + 81, b + 96, b + 97, b + 112, b + 113); }
    }

    static void Round(ulong[] v, int i0, int i1, int i2, int i3, int i4, int i5, int i6, int i7, int i8, int i9, int i10, int i11, int i12, int i13, int i14, int i15)
    {
        Gb(v, i0, i4, i8, i12); Gb(v, i1, i5, i9, i13); Gb(v, i2, i6, i10, i14); Gb(v, i3, i7, i11, i15);
        Gb(v, i0, i5, i10, i15); Gb(v, i1, i6, i11, i12); Gb(v, i2, i7, i8, i13); Gb(v, i3, i4, i9, i14);
    }

    static ulong Bla(ulong a, ulong b) => unchecked(a + b + 2 * (a & 0xffff_ffff) * (b & 0xffff_ffff));

    static void Gb(ulong[] v, int a, int b, int c, int d)
    {
        v[a] = Bla(v[a], v[b]); v[d] = BitOperations.RotateRight(v[d] ^ v[a], 32);
        v[c] = Bla(v[c], v[d]); v[b] = BitOperations.RotateRight(v[b] ^ v[c], 24);
        v[a] = Bla(v[a], v[b]); v[d] = BitOperations.RotateRight(v[d] ^ v[a], 16);
        v[c] = Bla(v[c], v[d]); v[b] = BitOperations.RotateRight(v[b] ^ v[c], 63);
    }

    static string B64(byte[] d) => Convert.ToBase64String(d).TrimEnd('=');
    static byte[]? Unb64(string s)
    {
        try { return Convert.FromBase64String(s.PadRight((s.Length + 3) / 4 * 4, '=')); } catch { return null; }
    }
}

public static class Blake2b
{
    static readonly ulong[] IV =
    [
        0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1,
        0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179,
    ];

    static readonly byte[][] Sigma =
    [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15], [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4], [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13], [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11], [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5], [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ];

    public static byte[] Hash(byte[] input, int outLength)
    {
        if (outLength is < 1 or > 64) throw new ArgumentOutOfRangeException(nameof(outLength));
        var h = (ulong[])IV.Clone();
        h[0] ^= 0x0101_0000UL ^ (ulong)outLength;
        ulong t = 0;
        var offset = 0;
        var n = input.Length;
        do
        {
            var remaining = n - offset;
            var last = remaining <= 128;
            var take = Math.Min(128, remaining);
            var block = new byte[128];
            if (take > 0) Array.Copy(input, offset, block, 0, take);
            t += (ulong)take;
            Compress(h, block, t, last);
            offset += take;
        } while (offset < n);
        var outp = new byte[64];
        for (var i = 0; i < 8; i++) BinaryPrimitives.WriteUInt64LittleEndian(outp.AsSpan(i * 8), h[i]);
        return outp[..outLength];
    }

    static void Compress(ulong[] h, byte[] block, ulong t, bool last)
    {
        var m = new ulong[16];
        for (var i = 0; i < 16; i++) m[i] = BinaryPrimitives.ReadUInt64LittleEndian(block.AsSpan(i * 8));
        var v = new ulong[16];
        Array.Copy(h, v, 8); Array.Copy(IV, 0, v, 8, 8);
        v[12] ^= t;
        if (last) v[14] = ~v[14];
        void G(int a, int b, int c, int d, ulong x, ulong y)
        {
            unchecked
            {
                v[a] = v[a] + v[b] + x; v[d] = BitOperations.RotateRight(v[d] ^ v[a], 32);
                v[c] = v[c] + v[d]; v[b] = BitOperations.RotateRight(v[b] ^ v[c], 24);
                v[a] = v[a] + v[b] + y; v[d] = BitOperations.RotateRight(v[d] ^ v[a], 16);
                v[c] = v[c] + v[d]; v[b] = BitOperations.RotateRight(v[b] ^ v[c], 63);
            }
        }
        for (var r = 0; r < 12; r++)
        {
            var s = Sigma[r % 10];
            G(0, 4, 8, 12, m[s[0]], m[s[1]]); G(1, 5, 9, 13, m[s[2]], m[s[3]]); G(2, 6, 10, 14, m[s[4]], m[s[5]]); G(3, 7, 11, 15, m[s[6]], m[s[7]]);
            G(0, 5, 10, 15, m[s[8]], m[s[9]]); G(1, 6, 11, 12, m[s[10]], m[s[11]]); G(2, 7, 8, 13, m[s[12]], m[s[13]]); G(3, 4, 9, 14, m[s[14]], m[s[15]]);
        }
        for (var i = 0; i < 8; i++) h[i] ^= v[i] ^ v[i + 8];
    }
}
