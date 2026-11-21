using System.Runtime.InteropServices;
using System.Text.Json.Nodes;

namespace CraftPanel.Core;

/// <summary>This PC's memory facts.</summary>
public sealed record SystemMemory(int TotalMB, int AvailableMB, string? MemoryType, string Chip, int Cores)
{
    /// <summary>The most this PC can spare without starving Windows: 75% of total, at least 2 GB left over.</summary>
    public int SafeMaxMB => Math.Max(1024, Math.Min(TotalMB * 3 / 4, TotalMB - 2048));

    /// <summary>Under 8 GB total or under 4 cores, a server plus everyday apps is tight.</summary>
    public bool IsWeak => TotalMB < 8 * 1024 || Cores < 4;

    public static SystemMemory Current() => new(ReadTotalMB(), ReadAvailableMB(), null, ReadChip(), Environment.ProcessorCount);

    /// <summary>Adds the memory type (a PowerShell / system_profiler query, so off the UI thread).</summary>
    public static async Task<SystemMemory> DetailedAsync() => Current() with { MemoryType = await Task.Run(ReadMemoryType) };

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX s);

    static (ulong total, ulong avail)? Win()
    {
        if (!OperatingSystem.IsWindows()) return null;
        var s = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        return GlobalMemoryStatusEx(ref s) ? (s.ullTotalPhys, s.ullAvailPhys) : null;
    }

    static int ReadTotalMB() => Win() is { } w ? (int)(w.total / 1_048_576) : (int)(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 1_048_576);

    static int ReadAvailableMB()
    {
        if (Win() is { } w) return (int)(w.avail / 1_048_576);
        try
        {
            if (File.Exists("/proc/meminfo"))
                foreach (var l in File.ReadLines("/proc/meminfo"))
                    if (l.StartsWith("MemAvailable:")) return int.Parse(l.Split(' ', StringSplitOptions.RemoveEmptyEntries)[1]) / 1024;
        }
        catch { }
        return ReadTotalMB() * 4 / 10;
    }

    static string ReadChip()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                using var k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(@"HARDWARE\DESCRIPTION\System\CentralProcessor\0");
                if (k?.GetValue("ProcessorNameString") is string n && n.Trim().Length > 0) return string.Join(' ', n.Split(' ', StringSplitOptions.RemoveEmptyEntries));
            }
            else if (OperatingSystem.IsMacOS() && Proc.Run("/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"], timeout: TimeSpan.FromSeconds(3)) is { Success: true } r)
                return r.StdOut.Trim();
        }
        catch { }
        return RuntimeInformation.ProcessArchitecture.ToString();
    }

    static string? ReadMemoryType()
    {
        try
        {
            if (OperatingSystem.IsWindows())
            {
                var r = Proc.Run("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command",
                    "Get-CimInstance Win32_PhysicalMemory | Select-Object SMBIOSMemoryType,ConfiguredClockSpeed | ConvertTo-Json -Compress"], timeout: TimeSpan.FromSeconds(8));
                return r is { Success: true } ? ParseWindowsMemory(r.StdOut) : null;
            }
            if (OperatingSystem.IsMacOS() && Proc.Run("/usr/sbin/system_profiler", ["SPMemoryDataType", "-json"], timeout: TimeSpan.FromSeconds(6)) is { Success: true } m)
                return ParseMacMemory(m.StdOut);
        }
        catch { }
        return null;
    }

    /// <summary>SMBIOS memory-type codes → names (26 DDR4, 34 DDR5, …).</summary>
    public static string? SmbiosName(int code) => code switch
    {
        20 => "DDR", 21 => "DDR2", 24 => "DDR3", 26 => "DDR4", 29 => "LPDDR3", 30 => "LPDDR4", 34 => "DDR5", 35 => "LPDDR5", _ => null,
    };

    public static string? ParseWindowsMemory(string json)
    {
        var node = JsonNode.Parse(json);
        var first = node is JsonArray a ? a.FirstOrDefault() : node;
        if (first?["SMBIOSMemoryType"]?.GetValue<int>() is not { } code || SmbiosName(code) is not { } name) return null;
        return first["ConfiguredClockSpeed"]?.GetValue<int>() is > 0 and var mhz ? $"{name}-{mhz}" : name;
    }

    public static string? ParseMacMemory(string json) =>
        JsonNode.Parse(json)?["SPMemoryDataType"]?.AsArray().FirstOrDefault()?["dimm_type"]?.GetValue<string>() is { Length: > 0 } t && t != "empty" ? t : null;
}

public enum RamKind { VanillaLike, Minigame, Modded, Modpack, Bedrock }

public sealed record RamWarning(bool Serious, string Message);

public static class RamAdvisor
{
    public const int MinMB = 1024;

    public static RamKind KindFor(ServerType t) => t.IsBedrock() ? RamKind.Bedrock : t.IsForgeFamily() ? RamKind.Modded : RamKind.VanillaLike;

    public static string Label(this RamKind k) => k switch
    {
        RamKind.VanillaLike => "a vanilla-style server", RamKind.Minigame => "this game mode", RamKind.Modded => "a modded server",
        RamKind.Modpack => "a modpack", _ => "Bedrock",
    };

    /// <summary>Recommended heap, rounded up to 512 MB, never above the safe limit.</summary>
    public static int Recommend(RamKind kind, int players, int safeMaxMB)
    {
        var p = Math.Max(1, players);
        var (b, per) = kind switch
        {
            RamKind.VanillaLike => (2048, 128), RamKind.Minigame => (2048, 96), RamKind.Modded => (4096, 192), RamKind.Modpack => (4096, 256), _ => (1024, 0),
        };
        var rounded = (b + per * p + 511) / 512 * 512;
        return Math.Max(MinMB, Math.Min(rounded, Math.Max(MinMB, safeMaxMB)));
    }

    public static int Ideal(RamKind kind, int players) => Recommend(kind, players, int.MaxValue);

    public static string Gb(int mb) => mb % 1024 == 0 ? $"{mb / 1024} GB" : $"{mb / 1024.0:0.0} GB";

    /// <summary>Everything worth warning about before creating/starting with <paramref name="chosenMB"/>.</summary>
    public static List<RamWarning> Warnings(int chosenMB, RamKind kind, int players, SystemMemory sys, int otherAllocatedMB = 0)
    {
        var o = new List<RamWarning>();
        if (kind == RamKind.Bedrock) return o;
        var ideal = Ideal(kind, players);
        var s = players == 1 ? "" : "s";
        if (chosenMB > sys.SafeMaxMB)
            o.Add(new(true, $"{Gb(chosenMB)} is over this PC's {Gb(sys.SafeMaxMB)} safe limit — Windows may start swapping and everything slows down."));
        else if (otherAllocatedMB > 0 && chosenMB + otherAllocatedMB > sys.SafeMaxMB)
            o.Add(new(true, $"Together with the servers already running ({Gb(otherAllocatedMB)}), this goes over the {Gb(sys.SafeMaxMB)} safe limit."));
        if (ideal > sys.SafeMaxMB)
        {
            var l = kind.Label();
            o.Add(new(false, $"{char.ToUpper(l[0])}{l[1..]} with {players} player{s} ideally wants {Gb(ideal)}; this PC can only spare {Gb(sys.SafeMaxMB)}. Expect lag with a full server."));
        }
        if (chosenMB < ideal * 3 / 4)
            o.Add(new(false, $"{Gb(chosenMB)} is low for {kind.Label()} with {players} player{s} (recommended {Gb(Math.Min(ideal, sys.SafeMaxMB))}). It may lag or crash with “OutOfMemoryError”."));
        if (sys.IsWeak)
            o.Add(new(false, $"This PC has {Gb(sys.TotalMB)} of memory and {sys.Cores} cores — running a server alongside everyday apps may be sluggish. Keep player counts small and close heavy apps."));
        return o;
    }
}
