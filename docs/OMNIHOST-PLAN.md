# OMNIHost on PumpkinMC: plan (2026-11-19)

OMNIHost = the native, fast server flavour of OMNIServers. Decision (2026-11-12): the engine is
**PumpkinMC** (Rust, GPLv3). This plan turns the "in development" card into a server people can
really create, run and join.

## What PumpkinMC is today (read from its GitHub page and releases, not yet run by us)
- Rust Minecraft server, GPLv3; plugin API (`pumpkin-plugin-api`, WIT) is MIT or Apache-2.0.
- Newest release `0.2.2+26.3-26.60` (8 Nov 2026), tag form `<pumpkin>+<java>-<bedrock>`:
  Java **26.3** (same version as the OMNI client) and Bedrock 26.60.
- Release files (single binary each): `pumpkin-ARM64-macOS` (96.7 MB), `pumpkin-X64-Linux`,
  `pumpkin-ARM64-Linux`, `pumpkin-X64-Windows.exe`, `pumpkin-ARM64-Windows.exe`, v3 variants,
  Android, plus `checksums.sha256`.
- Config is TOML. Marked work in progress by the project: Bedrock, mobs, animals, entity AI,
  bosses, villagers, advancements, non-living entities. "Under heavy development."
- Not found on the pages I read: console or RCON details, ports, world compatibility. These
  are the first things the spike must answer.

## Spike results (2026-11-19, real binary `pumpkin-ARM64-macOS`, sha256 verified)
Run in a throwaway folder on a spare port (25599). Measured, not assumed:
- Starts in about 25 ms after loading; idle memory about 39 MB (RSS). Logs "Server is now running."
  and "The server has stopped." Both are usable for status parsing.
- Answers a real Minecraft status ping: version `26.3`, protocol 777, max players and MOTD from config.
- Stops cleanly on `stop` over stdin and on SIGINT (saves the world first). No Java needed.
- Config is `pumpkin.toml` in the working folder (created on first run). Keys we need:
  `networking.java.address`, `.online_mode`, `.max_players`, `.motd`, `default_gamemode`,
  `default_difficulty`, `white_list`, `[networking.bedrock] enabled`, `[telemetry] enabled`,
  `[commands] use_console/use_tty`. World folder `world/` with `level.dat`; data in `data/`,
  logs in `logs/latest.log`, plugins in `plugins/`.
- Console reads stdin when not a TTY, so the app can send commands. Management API
  (`networking.management`) and query exist but are off by default; RCON not seen.
- **Defaults to change when OMNIServers creates a server:** telemetry is ON by default (sends
  heartbeats to market.pumpkinmc.org), so we write `enabled = false`; Bedrock listens on 19132
  by default (off unless the user wants it); `max_players` default 1000; `online_mode` true.
- Binary is 101 MB, not notarized (quarantine flag must be cleared, as the installer plan says).
- Downloads from GitHub work on this network.
Still unverified: a real 26.3 client joining and walking around, loading a vanilla or Fabric
world, memory under players, Bedrock.

## What that means (honest positioning)
- OMNIHost is **not** a drop-in for a modded Fabric survival server. Fabric mods do not run on
  it (Pumpkin plugins are WASM), and survival mobs are unfinished. Good first fits: lobbies,
  creative and build servers, minigames, fast-start small servers.
- Label it **Experimental** in the app until mobs exist. Show what works and what does not.

## Already in the Mac code
`Core/OmniHostAdapter.swift` (detects an `omnihost` binary, Java 25 helper, status parser),
`ServerType.omnihost`, `ServerRuntime` hook, the create-wizard hero card (disabled until a
binary is installed). OMNIServers does not download an engine yet.
Open question: the Java 25 requirement came from the earlier Horizon engine idea; Pumpkin is
native, so it probably goes away. The spike confirms.

## Phases
**0. Spike: DONE for server side (see results); client join still to do**
Download `pumpkin-ARM64-macOS` and `checksums.sha256`, verify, run in a temp folder, and record:
config file names and keys (port, max players, motd, online mode), world folder format,
log lines for "ready", how to stop it (stdin command or SIGINT), whether it has RCON or a
console, memory and start time (use `scripts/bench-idle.sh`). Join it with the OMNI client on
26.3. **Gate:** it starts and a 26.3 client can walk around. If GitHub release downloads are
blocked on this network (the web filter already blocks Mojang's download host), get the binary
from another network.

**1. Engine installer (Mac)**
`PumpkinInstaller`: reads GitHub releases, picks the asset for this OS and CPU, checks sha256
against `checksums.sha256`, stores it under
`~/Library/Application Support/CraftPanel/engines/pumpkin/<tag>/pumpkin` (same parent folder as the Java runtimes), clears the quarantine flag,
keeps the previous version for rollback. Downloaded, not bundled (GPL notice kept, no source
mixing with Horizon, which is MIT). Reuses the checksum and progress pattern of `JavaInstaller`.

**2. Adapter and runtime**
Point `OmniHostAdapter` at the installed Pumpkin binary and its real config name; drop Java 25
if the spike says so; replace `parseStatus` with Pumpkin's actual log lines; correct stop and
crash handling; live metrics. Tests use recorded log samples from the spike.

**3. Create flow and settings**
Remove the "in development" gate once an engine is installed. Create makes the folder,
writes Pumpkin's TOML from the wizard (name, port, players, difficulty, mode, online mode),
accepts EULA if Pumpkin needs it. Settings screen maps the same fields. Experimental badge and
a short "what works" list.

**4. Features that must keep working**
Backups and snapshots (world format permitting), Playit tunnel for the Java port, whitelist
and ops, console tab, performance charts. Anything Pumpkin cannot do is hidden for OMNIHost,
not faked.

**5. Launcher link**
The Play to Launcher popup already carries name, address and Minecraft version, so OMNIHost
servers join like any Java server (26.3). Add the type to the request so the popup can say
"OMNIHost (experimental)". Verify with the OMNI client.

**6. Windows and Linux (Avalonia)**
Same installer logic with `pumpkin-X64-Windows.exe` and `pumpkin-X64-Linux`; test via CrossOver
as for the Windows app.

**7. Updates**
Check for a newer Pumpkin tag, show notes, update with rollback. Pin to a tested tag by default
so a new release cannot break servers silently.

## Risks
- Project is early and moves fast; features may regress between tags (pin and test).
- Version lag: tags follow one Minecraft version at a time.
- This network blocks some downloads and intercepts HTTPS; installers must give a clear error.
- Worlds from vanilla or Fabric servers may not load; the spike checks and the UI must warn.

## Verification per phase
Unit tests for installer (checksum good and bad, asset choice, rollback), adapter (config
write, status parse from recorded logs); then a real run: create, start, join with the OMNI
client, stop, back up, restore. Anything not run on a real client is reported as unverified.

## Decisions needed from Kiq
1. OK to label OMNIHost Experimental and position it as lobby, creative and minigame hosting first?
2. Pin to the tested tag by default, with updates opt-in?
3. Spike first (recommended), then phases 1 to 3 on the Mac before Windows and Linux?

## Build status (2026-11-19, Mac, not committed)
Done and tested: phases 1 to 3.
- `Core/PumpkinEngine.swift`: pinned tag, asset choice, checksum parse, verify-then-install,
  `PumpkinConfig` (writes `pumpkin.toml`: telemetry off, Bedrock off, colour off, port, players,
  gamemode, difficulty, seed, MOTD; reads the port back).
- `OmniHostAdapter` rewritten for Pumpkin: no Java 25, runs the stored binary in the server
  folder, status from Pumpkin's real log lines, falls back to the installed engine if the stored
  path is gone. `ServerRuntime`, `NetworkInfo` (port), `ServerDetector` updated.
- Create wizard: Experimental label and honest warning, "Your world" settings shown, engine
  downloaded on first create with progress, free port picked, `pumpkin.toml` written.
- Tests: adapter, engine installer (checksum good/bad, rollback order), config (escaping, clamp,
  port round trip) plus a live test (`OMNI_LIVE=1`) that downloads the real engine, starts a
  server, sees "running", pings it as 26.3, stops it with `stop`: passed.
- Mac app reinstalled.
Not done: phase 4 checks (backups of Pumpkin worlds, Playit, console tab with a live run in the
UI), phase 5 popup label, phases 6 and 7. Not verified: a real client joining, vanilla/Fabric
world import. Existing failures in the full suite are outside this work: two prune tests in
BackupManager and SnapshotManager (files already modified before this work) and the UI launch
test (this Mac has no UI-testing permission).

## Update 2026-11-19 (later): offline mode, icon, console
- Offline mode did not work because Settings edited `server.properties`, which OMNIHost servers do not
  have. New OMNIHost settings card edits `pumpkin.toml` (online mode, gamemode, difficulty, max players,
  MOTD); Java, memory and server.properties cards are hidden for OMNIHost. Checked against the real
  engine: with `online_mode = false` a login is accepted without Mojang sign-in. Needs the server stopped.
- Universal icon: every OMNIHost server gets the OMNI app icon as `server-icon.png` (64x64) and
  `favicon_path` in `pumpkin.toml`; checked that the engine serves it in the server list. An icon the user
  set is never replaced. Older servers get it on next start.
- Console: engine name replaced by OMNIHost everywhere; banners, donation/Discord lines and start-up
  internals dropped; lines are `[12:00:00] Ready. Join on port 25565`. Players and chat still feed the
  online list. Live run: 4 lines from start to ready.
- Unverified: what the engine logs when a real player joins or chats (no client yet).

## Update 2026-11-19 (evening): move a Java server to OMNIHost
- Popup "Move <server> to OMNIHost" (server list right-click and the server's Settings). It copies the
  world (APFS clone, instant), maps server.properties to pumpkin.toml (port, players, gamemode,
  difficulty, online mode, MOTD, view/simulation distance, whitelist, level name), copies ops, whitelist
  and bans, and keeps the server icon. The Java server is never modified and stays as the backup.
- Checked with a copy of a real Fabric 26.2 server (1.6 GB world, 17 mods): the engine converted the
  world to its own format (about 12 s, one way, 2.2 GB afterwards), started, and stopped cleanly.
  Transfer plus first start took 12.8 s in total. Original server folder unchanged.
- Mods and plugins stay behind (they do not run on OMNIHost); the popup says so. Anything mods added to
  the world (blocks, biomes, items) may be lost or wrong: unverified in-game.
- Needs about 1.5x the world size free. Both servers use the same port, so one at a time.
- Tests: OmniHostTransferTests (mapping, plan, copy, skip lock and mod data, space check, cleanup),
  live test with a real server (`OMNI_LIVE=1`, `OMNI_LIVE_SRC`).

## Update 2026-11-19 (night): the move now carries players, lists, settings and a mod report
- Root causes found with the real engine: (1) offline servers get a different player id on OMNIHost
  (SHA-256 of the name, Java uses an MD5 id), so saved inventories were not found; (2) offline login also
  needs `encryption = false`, not just `online_mode = false`; (3) the engine rejects Java's advancement
  file layout.
- Move now: renames each player's `.dat`, stats and advancements to the new id (offline servers), converts
  advancements to the engine's layout, rewrites ids in whitelist/ops/bans, maps more settings (hardcore,
  nether, spawn protection, force gamemode, op level, PvP, resource pack), and writes
  `OMNIHost-transfer.txt` next to the new server: client-only mods (belong in the launcher), speed-up mods
  (not needed) and gameplay mods (stay on Java). Offline mode now writes `encryption` too (wizard, Settings, move).
- Checked on a copy of the real 1.6 GB Fabric 26.2 server: 5 players carried; a login as an existing player
  is accepted offline and the saved position is loaded; no engine errors. Stats load; advancements load after conversion.
- Not verified: a real client seeing the inventory in game; mod-added items in the world.
- Tests: OmniHostPlayerTransferTests (id vector from the real engine, advancement conversion, list remap,
  offline and online moves, mod classification).
