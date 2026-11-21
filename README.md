# OMNIServers

Free, open source Minecraft server manager. Create, run and back up servers on your own computer, with no account and no premium tier.

> OMNIServers is a work in progress. Features and details may change before release.

| App | For | Built with | Folder |
|---|---|---|---|
| **Mac** | macOS 15 or later | SwiftUI | [`apps/mac`](apps/mac) |
| **Desktop** | Windows and Linux (test build) | .NET 10, Avalonia | [`apps/desktop`](apps/desktop) |
| **Android** | Android phones, remote control | Kotlin, Jetpack Compose | [`apps/android`](apps/android) |
| **Website** | omniservers.kiqa-dev.it | static HTML | [`site`](site) |

## What it does

- Create Java servers (Vanilla, Paper, Fabric, Forge, NeoForge and more), plus Bedrock cross-play through Geyser.
- **OMNIHost** (experimental): a native, Java-free server flavour for lobbies, creative and minigames. Move an existing Java server to it with one click; the original is never touched.
- Live overview (CPU, memory, uptime, players), console, worlds, backups and snapshots, mods and plugins.
- Network tab: free tunnel, join address with copy and invite, port rules.
- **Play** opens the OMNI Launcher straight onto your server.

## Get it

Download builds from the [website](https://omniservers.kiqa-dev.it/downloads.html) or [GitHub Releases](https://github.com/Rashica07/OMNIServers/releases). The apps are not notarized yet: on a Mac, right-click Open the first time.

## Build it yourself

```bash
git clone https://github.com/Rashica07/OMNIServers.git
cd OMNIServers
./setup.sh            # builds and opens the app for your computer
```

On Windows use `.\setup.ps1`. Other targets: `./setup.sh desktop`, `./setup.sh android`, `./setup.sh site`. Add `--check` to only see what is missing. The script installs nothing and never uses sudo; it tells you what to install.

| You need | For |
|---|---|
| Xcode 16 or later | Mac app |
| .NET 10 SDK | Desktop app |
| JDK 17+ and Android SDK | Android app |
| Python 3 | previewing the website |

## Changing it

Working by hand or with an AI assistant? Read [SKILLS.md](SKILLS.md): where everything lives, how to build and test, and the rules that keep the Mac and Desktop apps in step.

## Related projects

- [OMNI Launcher](https://github.com/Rashica07/OMNI-Launcher): the Minecraft client OMNIServers launches into.
- OMNIHost runs on [PumpkinMC](https://github.com/Pumpkin-MC/Pumpkin) (GPL-3.0), downloaded on first use, not bundled.

## Licence

GPL-3.0. See [LICENSE](LICENSE). No telemetry; nothing leaves your computer unless you turn on a tunnel or share a link.
