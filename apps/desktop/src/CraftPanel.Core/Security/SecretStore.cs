using System.Runtime.InteropServices;
using System.Text;

namespace CraftPanel.Core.Security;

/// <summary>
/// Stores a small secret (the license key): Windows Credential Manager on Windows; elsewhere (and if the Credential API is
/// unavailable, e.g. under Wine) a file readable only by the current user.
/// </summary>
public static class SecretStore
{
    const string Prefix = "CraftPanel/";

    public static string? Get(string name)
    {
        if (OperatingSystem.IsWindows() && WinGet(name) is { } v) return v;
        var f = FilePath(name);
        try { return File.Exists(f) ? File.ReadAllText(f) : null; } catch { return null; }
    }

    public static void Set(string name, string? value)
    {
        if (OperatingSystem.IsWindows()) { if (value is null) WinDelete(name); else WinSet(name, value); }
        var f = FilePath(name);
        try
        {
            if (value is null) { if (File.Exists(f)) File.Delete(f); return; }
            if (OperatingSystem.IsWindows() && WinGet(name) == value) return;   // Credential Manager has it; no file copy
            Directory.CreateDirectory(Path.GetDirectoryName(f)!);
            File.WriteAllText(f, value);
            if (!OperatingSystem.IsWindows()) File.SetUnixFileMode(f, UnixFileMode.UserRead | UnixFileMode.UserWrite);
        }
        catch { }
    }

    static string FilePath(string name) => Path.Combine(AppPaths.DataDir, "secrets", name.Replace('/', '_') + ".secret");

    // ---- Windows Credential Manager ------------------------------------------------------

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct CREDENTIAL
    {
        public uint Flags, Type;
        public string TargetName, Comment;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist, AttributeCount;
        public IntPtr Attributes;
        public string TargetAlias, UserName;
    }

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredWriteW(ref CREDENTIAL c, uint flags);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredReadW(string target, uint type, uint flags, out IntPtr cred);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool CredDeleteW(string target, uint type, uint flags);
    [DllImport("advapi32.dll")] static extern void CredFree(IntPtr buffer);

    static void WinSet(string name, string value)
    {
        try
        {
            var bytes = Encoding.Unicode.GetBytes(value);
            var blob = Marshal.AllocHGlobal(bytes.Length);
            try
            {
                Marshal.Copy(bytes, 0, blob, bytes.Length);
                var c = new CREDENTIAL { Type = 1, TargetName = Prefix + name, CredentialBlobSize = (uint)bytes.Length, CredentialBlob = blob, Persist = 2, UserName = Environment.UserName };
                CredWriteW(ref c, 0);
            }
            finally { Marshal.FreeHGlobal(blob); }
        }
        catch { }
    }

    static string? WinGet(string name)
    {
        try
        {
            if (!CredReadW(Prefix + name, 1, 0, out var p)) return null;
            try
            {
                var c = Marshal.PtrToStructure<CREDENTIAL>(p);
                return c.CredentialBlobSize == 0 ? "" : Marshal.PtrToStringUni(c.CredentialBlob, (int)c.CredentialBlobSize / 2);
            }
            finally { CredFree(p); }
        }
        catch { return null; }
    }

    static void WinDelete(string name) { try { CredDeleteW(Prefix + name, 1, 0); } catch { } }
}
