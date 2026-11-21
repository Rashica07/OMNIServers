# OMNIServers for Windows (and Linux)

A free, open source Minecraft server manager. Set up, run and back up servers on your own computer. No account, no premium tier.

Avalonia app on .NET 10 for Windows and Linux. The Mac app is a separate SwiftUI app.

## Download

Get the latest build from https://omniservers.kiqa-dev.it/downloads.html or [GitHub Releases](https://github.com/Rashica07/OMNIServers/releases): Windows (x64, ARM64) and Linux (x64, ARM64, test build).

## What it does

- Create Java servers (Vanilla, Paper, Fabric, Forge, NeoForge and more) and Bedrock servers.
- Console, performance graphs, players, worlds, backups and snapshots, mods and plugins, scheduler.
- Network tab: free tunnel, join address with Copy and Invite, launch checklist, and port rules with presets (Minecraft, FiveM, CS2, Terraria, ARK or your own).
- No account, no premium tier.

## Build

```bash
dotnet run --project src/CraftPanel.App
dotnet test
scripts/build-windows.sh   # tests, then win-x64 and win-arm64 zips
scripts/build-linux.sh     # linux-x64 and linux-arm64 tar.gz
```

## Community

Join the Discord: https://discord.gg/SQwCjE38Jt

## Licence

OMNIServers is free software under the GNU General Public License v3.0. See [LICENSE](LICENSE). Every feature is free; there is no premium tier. Contributions are welcome and are accepted under the same licence.

OMNIServers is not affiliated with Mojang or Microsoft. Minecraft is a trademark of Mojang Synergies AB.
