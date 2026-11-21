OMNIServers for Windows
======================

Run CraftPanel.exe. Nothing to install: it is one file and needs no .NET, no Java (CraftPanel downloads a
verified Java for you the first time you make or start a server).

Your servers and settings live in:   %APPDATA%\CraftPanel
Servers you create go in:            Documents\CraftPanel Servers

First launch
  * Windows SmartScreen may say "unknown publisher" because this build isn't code-signed.
    Click "More info" > "Run anyway".
  * Windows Firewall may ask about Java opening a port. Allow it (private networks), or use
    the server's Network tab > "Allow through Windows Firewall".

New in 2.8
  * Help menu > Report a problem creates a redacted support zip. It does not include your worlds or Premium key.
  * Worlds tab: import a folder or .zip, drag-and-drop a save, find single-player worlds, and export a world.
  * Light mode and a low-spec server preset reduce work on slower PCs.
  * Help is available on every page, with a first-launch tour and searchable guides.
  * Network tab: take turns hosting the same shared server folder on two PCs, copy an invite, and ask IT to allow the LAN port.
  * Backups tab > Time Machine: snapshots of just your world that cost almost no disk (Premium). Restoring puts only the world back. Schedule them in a server's Settings.
  * Network tab > Free tunnel: a bore.pub address friends can join from anywhere, no account. Bedrock cross-play
    (Geyser + Floodgate) is on the same tab.
  * Files tab: open level.dat (or any .dat / .nbt) to edit it. Worlds tab: "Edit level.dat". Stop the server to save.
  * Time Machine needs an NTFS drive to share files between snapshots; on other drives it still works but copies everything.
  * The tunnel client (bore) is downloaded the first time you press "Start tunnel".

Under CrossOver / Wine
  * Rendering is set to software mode automatically. If a window looks wrong, run with the
    environment variable CRAFTPANEL_RENDER=software (or angle / wgl) to choose explicitly.
  * If something fails to start, look at %APPDATA%\CraftPanel\logs\crash.log

Uninstall: delete CraftPanel.exe. To remove your data too, delete %APPDATA%\CraftPanel.
