# OMNIServers for Windows 2.8.0 — status

Built with Avalonia (C#/.NET 10), reusing the Mac app's design and logic. Milestones 1–5 are implemented and covered by automated tests; the 2.8.0 Windows packages are built locally. **Not yet run on a real Windows PC or under CrossOver** — see "Untested here". Release files have not been published.

## Done
| Area | Notes |
|---|---|
| Servers | Create (Vanilla, Paper, Fabric, NeoForge, Forge), add existing folder (auto-detect), Quick start (Skyblock, Bedwars, EssentialsX, SMP), Modrinth modpacks (.mrpack), change version, remove/delete-to-trash |
| Java | Detects installed runtimes; installs verified Eclipse Temurin (SHA-256) 17/21/25 into `%LOCALAPPDATA%\CraftPanel\jre`; auto-picks a matching Java at create and start |
| Run | Start / stop (graceful, then force) / restart / kill, live console (follow, filter, history, colours), log file view, EULA banner, crash detection, re-adopts servers that kept running after OMNIServers closed |
| Players & chat | Chat tab (live chat, joins, advancements, send as `<Host>`), online list, kick/ban/op/gamemode, whitelist/ops/bans, play-time history from logs |
| Notifications | In-app pop-ups, corner pop-up when OMNIServers is in the background, tray icon with per-server menu |
| Memory | RAM advisor: reads this PC's memory, type and CPU; recommendation by game mode and player count; safe-limit tick; "install anyway" warning; Java starts small (-Xms 1 GB) and grows |
| Backups | Zip backups (world paused first), verify, restore with rollback, retention (keep N; smart retention), backup after stop |
| Automation | Restart after crash (bounded), daily restart with 1-minute chat warning, start with OMNIServers |
| Network | LAN address, UPnP port forward, public IP lookup on request, saved permanent address, Windows Firewall rule (UAC) |
| 2.8.0 support & school network | Redacted problem-report zip, portable/locked-down data fallback, extra health checks, school/guest Wi-Fi IT request, invite copy and local connection test |
| 2.8.0 world sharing | Import folder/zip/drag-drop/single-player save, export, safe paths, version warning; take-turns shared-folder lease interoperable with the Swift app |
| 2.8.0 accessibility & guidance | Automatic Light mode and low-spec preset; page-aware searchable Help library and first-launch tour |
| Time Machine | World snapshots: the current world save only (level folder, Paper nether/end, Bedrock world), hard-linked so unchanged files cost no disk; Snapshot now, automatic schedule while running, tiered retention; a restore swaps just the world (old one kept aside, rolls back on failure) while mods and configs stay. Older whole-server snapshots still list and restore. Same folder layout as the Mac app |
| Free tunnel | One-click `bore.pub` address, no account: downloads the bore client once (SHA-256 pinned), shows the address, copy, stop. Friends are told the tunnel address first |
| Cross-play | One-click Geyser + Floodgate for Paper/Spigot/Fabric/NeoForge (checksum-verified from GeyserMC; Floodgate for Fabric/NeoForge from Modrinth), Bedrock address, UDP port forward and firewall rule, clean removal |
| NBT editor | `level.dat`, player data and `.nbt` files as an editable tree (numbers, text, short arrays; bad input is flagged, never applied); gzip kept as read; previous file kept as `.craftpanel-bak`; Java "modified UTF-8" so emoji survive; opens from Files and from a world's "Edit level.dat" |
| Map | One-click BlueMap (Mojang texture consent), opens in the browser, LAN link |
| Add-ons | Modrinth search/install (with dependencies, SHA-1), updates, remove; datapacks; resource packs; Mods tab enable/disable |
| Worlds, Files | Worlds list / switch / new / trash; file browser with text editor (confined to the server folder, deletes go to trash) |
| Settings | Themes (Dark, Light, Midnight, Sunset — all free), defaults, Java manager, app lock (Argon2id), health check, expert raw `server.properties` |
| Packaging | Self-contained single-file `CraftPanel.exe` for x64 and ARM64 (`scripts/build-windows.sh`) |

## Not done yet (in the Mac app, not here)
Remote API (phone app / Discord bot),
CurseForge, Bedrock resource packs, shared-folder lease, anti-cheat helper, performance alerts, auto-update, an installer,
code signing (so SmartScreen will warn), an embedded map view (the map opens in your browser instead).

## Untested here
Real Windows behaviour: NTFS hard links (`CreateHardLinkW`; the Unix `link` path is what ran in tests), downloading and running `bore.exe`, Windows Firewall/UAC, Credential Manager, Windows Java zip extraction (only the tar.gz path ran
for real, plus a zip fixture), the tray icon, and rendering under CrossOver/Wine. Wine-specific hedges are in place
(software rendering, TLS 1.2, redirection-surface composition) but unproven. Errors are written to
`%APPDATA%\CraftPanel\logs\crash.log`.

## Dependencies (NuGet)
Avalonia, Avalonia.Desktop, Avalonia.Themes.Fluent (app); xunit.v3, Avalonia.Headless.XUnit, Avalonia.Skia,
Microsoft.NET.Test.Sdk, xunit.runner.visualstudio (tests only). Fonts/icons: Space Grotesk (OFL), Lucide (ISC).
Build downloads the .NET Windows runtime packs from NuGet.
