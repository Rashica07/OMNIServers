using System.Text.Json.Nodes;
using CraftPanel.Core;
using Xunit;

namespace CraftPanel.Tests;

public class BedrockProvisionTests
{
    const string Json = """
    {"result":{"links":[
      {"downloadType":"serverBedrockWindows","downloadUrl":"https://www.minecraft.net/bedrockdedicatedserver/bin-win/bedrock-server-1.26.61.1.zip"},
      {"downloadType":"serverBedrockLinux","downloadUrl":"https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-1.26.61.1.zip"},
      {"downloadType":"serverBedrockPreviewWindows","downloadUrl":"https://www.minecraft.net/bedrockdedicatedserver/bin-win-preview/bedrock-server-1.26.70.22.zip"},
      {"downloadType":"serverBedrockPreviewLinux","downloadUrl":"https://www.minecraft.net/bedrockdedicatedserver/bin-linux-preview/bedrock-server-1.26.70.22.zip"},
      {"downloadType":"serverJar","downloadUrl":"https://piston-data.mojang.com/v1/objects/abc/server.jar"}]}}
    """;

    [Fact] public void PicksTheRightOsAndPutsStableFirst()
    {
        var win = Provisioner.ParseBedrockLinks(JsonNode.Parse(Json)!, windows: true);
        Assert.Equal(2, win.Count);
        Assert.Equal(("1.26.61.1", false), (win[0].Version, win[0].Preview));
        Assert.Contains("bin-win/", win[0].Url); Assert.Equal("1.26.70.22", win[1].Version); Assert.True(win[1].Preview);
        var lin = Provisioner.ParseBedrockLinks(JsonNode.Parse(Json)!, windows: false);
        Assert.All(lin, l => Assert.Contains("linux", l.Url));
    }

    [Fact] public void EmptyOrOddJsonGivesNothing() =>
        Assert.Empty(Provisioner.ParseBedrockLinks(JsonNode.Parse("""{"result":{}}""")!, true));

    [Fact] public void BedrockPortStartsAt19132AndSkipsTaken()
    {
        var p = Provisioner.PickFreeBedrockPort(new HashSet<int> { 19132 });
        Assert.NotNull(p); Assert.True(p >= 19133);
    }

    [Fact] public void LoaderMapsToBedrockServerType() => Assert.Equal(ServerType.Bedrock, Loader.Bedrock.ServerType());
}
