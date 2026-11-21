using CraftPanel.Core;
using CraftPanel.Core.Java;

namespace CraftPanel.App.Services;

/// <summary>Before a start: is there a Java new enough for this server? If not, offer to install a verified Temurin runtime.</summary>
public static class JavaCheck
{
    public sealed record Problem(string Message, uint Need, uint? Feature);

    public static async Task<Problem?> CheckAsync(ServerRecord r)
    {
        if (r.ServerType.IsBedrock()) return null;
        var need = r.McVersion is { } mc ? JavaProbe.RequiredJava(mc) : 17u;
        var path = JavaProbe.AutoResolve(r.JavaPath, r.McVersion) ?? r.JavaPath;
        var info = await JavaProbe.ProbeAsync(path);
        var feature = JavaInstaller.OfferableFeature(need);
        if (info is null) return new($"Java wasn't found. This server needs Java {need}+.", need, feature);
        if (info.Major < need) return new($"This server needs Java {need}+, but the selected runtime is Java {info.Major}.", need, feature);
        return null;
    }

    /// <summary>Returns true when the problem was fixed (Java installed and the server pointed at it).</summary>
    public static async Task<bool> OfferFixAsync(ServerRecord r, Problem p)
    {
        if (p.Feature is not { } f)
        {
            await Dialogs.Current.ShowMessageAsync("Java is missing", p.Message + "\n\nInstall a matching JDK (for example Eclipse Temurin) and pick it in the server's Settings.");
            return false;
        }
        if (!await Dialogs.Current.ConfirmAsync("Install Java?", $"{p.Message}\n\nCraftPanel can download Eclipse Temurin {f} (checksum-verified, about 50 MB) and use it for this server.", $"Install Java {f}"))
            return false;
        var lastStage = "";
        var progress = new Progress<ProvisionProgress>(pp =>
        {
            if (pp.Stage != lastStage) { lastStage = pp.Stage; ToastService.Shared.Show(pp.Message, "", "cloud-download", "info", null, 3); }
        });
        try
        {
            var info = await JavaInstaller.InstallAsync(f, progress);
            r.JavaPath = info.Path;
            AppServices.Store.Update(r);
            ToastService.Shared.Show($"Java {f} installed", "", "check-circle", "ok");
            return true;
        }
        catch (Exception e)
        {
            ToastService.Shared.Error("Couldn't install Java: " + e.Message);
            return false;
        }
    }
}
