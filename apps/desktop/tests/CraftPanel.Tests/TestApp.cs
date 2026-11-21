using Avalonia;
using Avalonia.Headless;
using CraftPanel.App;
using CraftPanel.Tests;

[assembly: AvaloniaTestApplication(typeof(TestAppBuilder))]
// Several tests point the app's data folder somewhere temporary (a global); run them one at a time.
[assembly: Xunit.CollectionBehavior(DisableTestParallelization = true)]

namespace CraftPanel.Tests;

public static class TestAppBuilder
{
    public static AppBuilder BuildAvaloniaApp()
    {
        // Never touch the real user data folder from tests.
        CraftPanel.Core.AppPaths.DataOverride ??= Path.Combine(Path.GetTempPath(), "cp-tests-data-" + Environment.ProcessId);
        return AppBuilder.Configure<CraftPanel.App.App>().UseSkia().UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false });
    }
}
