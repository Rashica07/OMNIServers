using System.Runtime.InteropServices;

namespace CraftPanel.Core;

/// <summary>
/// NTFS (and Unix) hard links — .NET has no API for them. Used by world snapshots so unchanged files cost no disk.
/// Returns false instead of throwing when the file system can't (FAT/exFAT, some network shares); the caller copies instead.
/// </summary>
public static class HardLink
{
    [DllImport("kernel32.dll", EntryPoint = "CreateHardLinkW", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateHardLinkW(string newFileName, string existingFileName, IntPtr securityAttributes);

    [DllImport("libc", EntryPoint = "link", SetLastError = true)]
    static extern int UnixLink(string existing, string newName);

    public static bool TryCreate(string existing, string newName)
    {
        try
        {
            if (OperatingSystem.IsWindows()) return CreateHardLinkW(newName, existing, IntPtr.Zero);
            return UnixLink(existing, newName) == 0;
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { return false; }
    }
}
