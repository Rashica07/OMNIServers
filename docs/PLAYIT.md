# Playit.gg in OMNIServers (macOS, v1)

Optional, per server (Network tab -> "Playit.gg address"). Off by default. Local and LAN hosting never need it.

## Agent lifecycle

| Event | Playit agent |
|---|---|
| OMNIServers opens | OFF (no process) |
| A server that opted in starts (`starting`) | START (first one only) |
| Agent reports tunnels | CONNECTED, address shown in the card |
| Second server opts in and starts | same agent, no second process |
| One of two servers stops | agent stays (reference count 2 -> 1) |
| Last server stops or crashes | SIGTERM, SIGKILL after 5 s, socket removed |
| Agent dies while a server still runs | relaunch with backoff 1,2,4..30 s (reset after a 60 s healthy run) |
| OMNIServers quits | agent stopped (with "keep servers running on quit", the tunnel pauses until you reopen the app; re-adopted servers re-acquire it) |

Implementation: `Core/PlayitAgent.swift` (`PlayitLeases` reference count, `PlayitAgent` supervisor, `PlayitCoordinator` hooked into `ServerRuntime.setStatus`, so every status path - start, stop, crash, re-adopt - is covered).

## How it talks to the agent (verified against agent v2.0.2)

- Runs `playitd` as a child process with `--secret-path`, `--socket-path`, `--log-path`. Never installs the system/LaunchAgent service the official installers add (that would run all the time).
- IPC: JSON lines over a unix socket, `ipc_version` 3 (`subscribe` -> `lifecycle` events carrying `tunnels[].display_address`). Checked against a real `playitd`.
- macOS limits unix socket paths to ~104 bytes, so the socket is `/tmp/omni-<uid>/playit.sock` in a 0700 folder.
- Sign-in: `playit claim generate` -> `claim url` (opened in the browser) -> `claim exchange --wait`. No terminal for the user. The secret goes to the Keychain and to the agent over IPC; it is never put on a command line.
- Tunnel creation: `POST api.playit.gg/v1/tunnels/create`, secret only in the `Authorization` header. Java = `minecraft-java`, Bedrock = `minecraft-bedrock` (own tunnel each; not assumed identical).

## Security

- Binary: pinned to v2.0.2, SHA-256 checked (`d3da262f...e2`) before unpacking; a mismatch deletes the download unrun. Updates are never installed automatically: a new version needs a new pinned hash in a new OMNIServers release.
- `PlayitRedactor` strips agent keys / bearer tokens / long hex from any text before it can be logged.
- Agent logs go to its own file under `~/Library/Application Support/CraftPanel/playit/run/` (folder 0700).
- Licence: agent is BSD-2-Clause; its LICENSE is inside the downloaded archive and we redistribute nothing ourselves (the app downloads it from the official release).

## Tested

- 16 unit tests with a fake agent (start once, shared by two servers, stays until the last, stops, crash recovery, no restart when nothing needs it, shutdown, sign-in needed, secret handed over, tunnel created once, address shown, IPC parsing of real captured messages, redaction, checksum, request body, socket path length).
- 1 live test (`PLAYIT_LIVE=1`, opt-in): downloads the pinned agent, starts the REAL `playitd` through the real manager, sees it ask for sign-in, confirms exactly one process and the socket, releases, confirms no process and no socket remain. Passed.

## Not tested (needs a Playit account / other OSes)

- Sign-in end to end (`claim exchange`) and the secret reaching the agent.
- Tunnel creation response, and a real public address appearing for a Java and a Bedrock server.
- Whether a Bedrock server shows the address correctly (UDP).
- Windows and Linux: no code yet. Windows ships `playitd-windows-x86_64-signed.exe`, Linux `playit-linux-amd64` etc. (all with published SHA-256). Named pipe `\\.\pipe\...` on Windows instead of a unix socket.
- Several servers on different ports through one agent against the real service.
