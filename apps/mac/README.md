# OMNIServers for Mac

A free, open source Minecraft server manager. Set up, run and back up servers on your own computer. No account, no premium tier.

Native SwiftUI app for macOS 15 or later. Also available for Windows and Linux (test build).

## Download

Latest build: https://omniservers.kiqa-dev.it/downloads.html or [GitHub Releases](https://github.com/Rashica07/OMNIServers/releases). The app is not notarized yet, so right-click Open the first time.

## What it does

- Create Java servers (Vanilla, Paper, Fabric, Forge, NeoForge and more); Bedrock cross-play through Geyser.
- Overview with live CPU, memory, uptime and players; Performance, console, worlds, backups and snapshots, mods and plugins.
- Network tab: free tunnel, join address with Copy and Invite, launch checklist, and port rules with presets.
- No account, no premium tier.

## Build

```bash
cd craftpanel-Swift
xcodebuild -project craftpanel-Swift.xcodeproj -scheme craftpanel-Swift -destination 'platform=macOS' build
```

Run the tests with `-only-testing:craftpanel-SwiftTests test`. Disk images come from `scripts/make-dmgs.sh`.

## Community

Join the Discord: https://discord.gg/SQwCjE38Jt

## Licence

OMNIServers is free software under the GNU General Public License v3.0. See [LICENSE](LICENSE). Every feature is free; there is no premium tier. Contributions are welcome and are accepted under the same licence.

OMNIServers is not affiliated with Mojang or Microsoft. Minecraft is a trademark of Mojang Synergies AB.
