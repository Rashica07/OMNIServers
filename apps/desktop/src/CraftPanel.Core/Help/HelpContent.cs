using static CraftPanel.Core.Help.HelpPages;

namespace CraftPanel.Core.Help;

/// <summary>
/// The text of every how-to and the first-launch tour. Button and tab names here are the real ones from the screens
/// (a test keeps every page covered and every action valid). Plain language: written for someone setting up a server
/// for the first time.
/// </summary>
public static class HelpContent
{
    static HelpStep S(string text, HelpAction? action = null) => new(text, action);
    static HelpAction Go(string label, string section) => new(label, HelpActionKind.Section, section);
    static HelpAction Settings(string label, string tab) => new(label, HelpActionKind.SettingsTab, tab);
    static HelpAction Copy(string label, string text) => new(label, HelpActionKind.Copy, text);
    static HelpTopic T(string id, string title, string summary, string[] pages, string[] keywords, HelpStep[] steps, string[]? notes = null) => new(id, title, summary, pages, keywords, steps, notes);

    public static readonly IReadOnlyList<TourStep> Tour =
    [
        new("Welcome to OMNIServers", "OMNIServers sets up and runs Minecraft servers for you: it downloads the server, starts it, keeps it safe with backups, and shows you how friends can join. This 10-step tour takes about two minutes. You can open it again any time from Help → Full tutorial."),
        new("Make a server", "Press New server (bottom left). Pick Paper if you're unsure — it's fast and works with plugins. Quick start gives you ready-made setups like Skyblock. Already have a server folder? 'Add an existing folder…' finds it.", new("New server…", HelpActionKind.NewServer)),
        new("Start it", "Open your server and press Start. The first time, Minecraft asks you to accept its EULA — press 'Accept and start' in the Console. The Console is the server's live output, and you can type commands at the bottom.", Go("Open the Console", "Console")),
        new("Let friends join", "The Network tab shows the address friends type into Minecraft. On the same Wi-Fi or network they use the 'On your network' address. Friends elsewhere? Press 'Start tunnel' for a free address that works from anywhere.", Go("Open Network", "Network")),
        new("Players: op and whitelist", "On the Players tab you can see who's online, kick or ban people, make someone an operator (admin), and whitelist friends so only they can join.", Go("Open Players", "Players")),
        new("Bring your own world", "Worlds → 'Add a world' takes a folder, a .zip, or one of your single-player worlds. You can also drag a world folder or .zip onto the page. 'Export world' saves your world as a .zip to share.", Go("Open Worlds", "Worlds")),
        new("Backups keep you safe", "Backups → 'Back up now' saves a zip of the whole server. 'Import backup…' adds a backup from a friend. Time Machine snapshots save just the world very cheaply, as often as you like.", Go("Open Backups", "Backups")),
        new("Settings", "Server settings has the memory slider (OMNIServers recommends a size for the number of players), the message of the day, difficulty, whitelist, and automation like 'Restart if it crashes' and 'Back up after every stop'.", Go("Open server settings", "Settings")),
        new("Mods and plugins", "Add-ons searches Modrinth and installs mods, plugins and datapacks with their requirements in one click. Mods lets you turn installed mods on and off.", Go("Open Add-ons", "Addons")),
        new("Something wrong?", "Settings → Diagnostics runs a health check, and 'Report a problem…' saves a file you can send to whoever is helping you — names, IP addresses and passwords are removed from it.", new("Report a problem…", HelpActionKind.ReportProblem)),
        new("You're set", "Press the Help button (or F1) on any page for tips about that page, or search 'How do I…?' for step-by-step guides. Have fun!"),
    ];

    public static readonly IReadOnlyList<HelpTopic> Topics =
    [
        // ---------- getting started ----------
        T("create-server", "Make your first server", "From nothing to a running server in a few minutes.", [Overview, WizardCreate], ["new", "create", "first", "install", "paper", "fabric", "forge", "vanilla", "neoforge"],
        [
            S("Press New server at the bottom left.", new("New server…", HelpActionKind.NewServer)),
            S("Pick the software. Paper is the safe choice (fast, works with plugins). Fabric, Forge and NeoForge are for mods. Vanilla is plain Minecraft."),
            S("Pick the Minecraft version your friends will use (the newest is usually right)."),
            S("Give it a name and check the memory. OMNIServers recommends a size; if your PC is small it will warn you."),
            S("Press the create button and wait. OMNIServers downloads the server and, if needed, a matching Java."),
            S("Open the server and press Start. On the first start press 'Accept and start' for the Minecraft EULA."),
        ], ["Friends must use the same Minecraft version as the server (Paper lets slightly newer or older clients in with extra plugins).", "A server needs a few GB of free disk space."]),

        T("quick-start", "Quick start: Skyblock, Bedwars and more", "Ready-made servers with the right plugins already set up.", [Overview, WizardCreate], ["template", "skyblock", "bedwars", "smp", "essentialsx", "minigame"],
        [
            S("Press the arrow next to New server and choose 'Quick start (Skyblock, Bedwars…)'.", new("Quick start…", HelpActionKind.NewServer)),
            S("Pick a template, then press Next."),
            S("Name the server and finish. OMNIServers installs the plugins the template needs."),
        ]),

        T("add-existing", "Add a server you already have", "Bring a server folder you made before into OMNIServers.", [Overview, WizardCreate], ["existing", "import folder", "detect", "old server"],
        [
            S("Press the arrow next to New server and choose 'Add an existing folder…'.", new("New server…", HelpActionKind.NewServer)),
            S("Pick the folder that has the server .jar (and server.properties) in it."),
            S("OMNIServers works out the type and version for you. Check them and confirm."),
        ], ["Your files stay where they are; OMNIServers just starts managing them."]),

        T("performance", "See how your server is doing", "CPU, memory, uptime and a graph for the last minute to four hours.", [ServerPerformance], ["performance", "cpu", "ram", "memory", "lag", "graph", "uptime", "slow"],
        [
            S("Open the Performance tab. It fills in a few seconds after the server starts."),
            S("The tiles show right now: CPU use, memory used out of what you gave the server, and how long it has been up."),
            S("Pick 1m, 5m, 30m, 1h or 4h above the graph to zoom out. Crimson is CPU, gold is memory."),
            S("Memory staying near full? Give the server more in Settings, or lower the view distance."),
        ]),

        T("start-stop", "Start, stop and restart", "The buttons at the top of every server.", [ServerConsole], ["start", "stop", "restart", "kill", "force"],
        [
            S("Open the server from the list on the left."),
            S("Press Start. The status badge changes from Stopped to Starting to Running."),
            S("Press Stop to save the world and shut down cleanly. The rotate button restarts."),
            S("If it's stuck, open the ⋯ menu → 'Force kill'. Use it only as a last resort — it can lose the last minutes of progress."),
        ], ["Closing OMNIServers asks whether to stop your servers; 'Keep servers running when I quit OMNIServers' in Settings changes that."]),

        T("eula", "The Minecraft EULA", "Minecraft servers won't start until you accept Mojang's licence.", [ServerConsole, ServerSettings], ["eula", "licence", "license", "accept", "won't start"],
        [
            S("Start the server once. It stops straight away and the Console shows a notice about the EULA."),
            S("Read the EULA link, then press 'Accept and start'."),
        ]),

        // ---------- console and players ----------
        T("console-commands", "Type commands in the console", "Run any server command without leaving OMNIServers.", [ServerConsole], ["command", "console", "say", "gamemode", "time", "weather", "tp", "give"],
        [
            S("Start the server and open the Console tab."),
            S("Click the box at the bottom, type a command WITHOUT the slash (for example: time set day), and press Enter or Send."),
            S("Use the Filter box to show only lines that contain a word, like a player's name."),
            S("'Log file' shows the full log of earlier runs."),
        ], ["Handy ones: say Hello (message everyone), gamemode creative YourName, time set day, weather clear, difficulty peaceful, stop."]),

        T("make-op", "Make yourself an operator (admin)", "Operators can use admin commands in the game.", [ServerConsole, ServerPlayers], ["op", "operator", "admin", "permissions", "opped", "deop"],
        [
            S("Start the server."),
            S("Easiest: open the Players tab, type your exact Minecraft name under 'Add a player' and press 'Make operator'.", Go("Open Players", "Players")),
            S("Or in the Console type: op YourName", Copy("Copy: op YourName", "op YourName")),
            S("To remove it later, type: deop YourName"),
        ], ["The name must be exactly your Minecraft name (capitals don't matter).", "Operators are listed on the Players tab under 'Operators'."]),

        T("whitelist", "Only let friends join (whitelist)", "Turn the whitelist on and add people.", [ServerPlayers, ServerSettings], ["whitelist", "allow list", "private", "friends only", "allowlist"],
        [
            S("Open the server's Settings tab, turn on 'Whitelist' under 'World & gameplay', and press Save.", Go("Open Settings", "Settings")),
            S("Restart the server so it takes effect."),
            S("Open Players, type a friend's name under 'Add a player' and press 'Whitelist'.", Go("Open Players", "Players")),
        ], ["Names must be spelled exactly as in Minecraft.", "Anyone not on the list is turned away with a message."]),

        T("kick-ban", "Kick or ban someone", "Remove a player now, or for good.", [ServerPlayers], ["kick", "ban", "unban", "grief", "remove player"],
        [
            S("Open Players. Everyone online is listed at the top."),
            S("Press Kick to remove them for now, or Ban to stop them coming back."),
            S("To ban someone who isn't online, type their name under 'Add a player' and press Ban."),
            S("Unban from the 'Banned' list further down."),
        ]),

        T("chat", "Chat with players from OMNIServers", "See the in-game chat and answer it.", [ServerChat], ["chat", "message", "say", "talk"],
        [
            S("Start the server and open the Chat tab. Messages, joins and advancements appear live."),
            S("Type in the box at the bottom and press Enter. Players see it as <Host> … (change the name in Settings → General)."),
        ]),

        // ---------- friends joining ----------
        T("join-lan", "Friends on the same Wi-Fi or network", "No setup beyond the address.", [ServerNetwork], ["lan", "wifi", "same network", "address", "ip", "join", "connect", "local"],
        [
            S("Start the server and open the Network tab.", Go("Open Network", "Network")),
            S("Under 'How friends join', copy the address (the 'ON YOUR NETWORK (LAN)' one)."),
            S("In Minecraft: Multiplayer → Add Server → paste the address → Join."),
            S("On the same PC, use the 'ON THIS PC' address (localhost)."),
        ], ["If friends can't connect, Windows Firewall may be blocking — see 'Windows Firewall and school PCs'.", "Some school and guest Wi-Fi networks stop devices talking to each other; use the free tunnel instead."]),

        T("join-internet", "Friends from anywhere (internet)", "Two ways: a free tunnel, or opening your router.", [ServerNetwork], ["internet", "online", "remote", "port forward", "upnp", "public", "router", "outside"],
        [
            S("Easiest: use the free tunnel — see 'Free tunnel'.", Go("Open Network", "Network")),
            S("Or under 'Play over the internet' press 'Forward the port'. OMNIServers asks your router to open the port (UPnP)."),
            S("Press 'Look it up' to see your public address and give friends that."),
            S("If forwarding fails, your router doesn't allow it; open the port in the router's settings or use the tunnel."),
        ], ["Never post your public address on a public channel — anyone with it can reach your server."]),

        T("tunnel", "Free tunnel (works from anywhere)", "A shareable address with no router setup and no account.", [ServerNetwork], ["tunnel", "bore", "free address", "no port forward", "school", "behind"],
        [
            S("Start the server, open Network and press 'Start tunnel' under 'Free tunnel'.", Go("Open Network", "Network")),
            S("The first time, OMNIServers downloads the small tunnel program."),
            S("Copy the address (it looks like bore.pub:12345) and send it to friends."),
            S("Press Stop when you're done."),
        ], ["The address changes each time you start the tunnel.", "It carries Java players only (not Bedrock).", "If your network blocks it, the tunnel can't start; the error is shown under the button."]),

        T("bedrock", "Let phone and console players join (Bedrock)", "Geyser and Floodgate in one click for Paper, Spigot, Fabric and NeoForge.", [ServerNetwork], ["bedrock", "geyser", "floodgate", "phone", "console", "xbox", "playstation", "switch", "mobile", "crossplay"],
        [
            S("Open Network and press 'Turn on cross-play' under 'Bedrock cross-play'.", Go("Open Network", "Network")),
            S("Restart the server when it says so."),
            S("Bedrock players join with your address and the port shown there (19132 by default)."),
            S("For friends outside your home, press 'Forward the UDP port'."),
        ], ["Vanilla and Forge servers can't run Geyser — use Change version to switch to Paper or Fabric."]),

        T("take-turns", "Share a server between two PCs (take turns)", "Host the same world from either PC, one at a time.", [ServerNetwork], ["share", "two pcs", "take turns", "usb", "network drive", "onedrive", "google drive", "dropbox", "lease", "switch pc", "another computer", "school and home"],
        [
            S("Put the server's folder somewhere both PCs can open: a USB stick, a network drive, or a synced folder (OneDrive, Google Drive, Dropbox). Copy or move it there while the server is stopped."),
            S("On the first PC open the server, go to Network and press 'Share this server' under 'Take turns with another PC'.", Go("Open Network", "Network")),
            S("On the other PC press New server → 'Add an existing folder…' and pick the same folder."),
            S("Start the server on either PC. The other one is told it's busy and who is running it."),
            S("Stop the server when you're done; the other PC can then start it with all your progress."),
        ], ["Only one PC runs the world at a time — that's what keeps it safe.", "If a PC was switched off while running, its claim runs out after about 2 minutes, or press 'Start anyway' when asked.", "With a synced folder, wait for the sync to finish before starting on the other PC.", "Mac and Windows copies of OMNIServers can share the same folder."]),

        T("invite-friends", "Send friends an invite and test your server", "A ready-made message, and a check for when friends can't connect.", [ServerNetwork], ["invite", "message", "send address", "test server", "can't connect", "cant connect", "check port", "friends can't join"],
        [
            S("Start the server and open Network.", Go("Open Network", "Network")),
            S("Press 'Copy invite message' and paste it to your friends — it has the address, the Minecraft version and how it works."),
            S("Friends can't connect? Press 'Test my server'. It says whether the server answers on this PC's network address."),
            S("If it says Windows Firewall is probably blocking, press 'Allow through Windows Firewall' (or ask IT to allow the port)."),
            S("If it answers but friends still can't join, the network may stop devices reaching each other — use the free tunnel."),
        ]),

        T("firewall", "Windows Firewall and school PCs", "When friends can't connect, or you can't open a port.", [ServerNetwork, SettingsDiagnostics], ["firewall", "admin", "school", "blocked", "permission", "it department", "no admin", "locked down"],
        [
            S("Open Network and press 'Allow through Windows Firewall'. Windows asks for an administrator's password.", Go("Open Network", "Network")),
            S("On a school or work PC you may not have that password. Ask whoever manages it to allow the port shown on the Network tab (25565 by default) for 'Private' networks."),
            S("If the server answers on this PC but other students still cannot connect, ask IT to check client isolation. The Network tab can copy a request with the exact TCP or UDP port."),
            S("If you can't change anything, use the free tunnel — it only makes an outgoing connection.", Go("Open Network", "Network")),
            S("Settings → Diagnostics shows what this PC allows and gives the exact wording to ask IT.", Settings("Open Diagnostics", "Diagnostics")),
        ]),

        // ---------- settings ----------
        T("ram", "How much memory should a server get?", "More isn't always better.", [ServerSettings, SettingsGeneral], ["ram", "memory", "gb", "lag", "slow", "allocation", "heap"],
        [
            S("Open the server's Settings tab and look at 'Memory'.", Go("Open Settings", "Settings")),
            S("Set 'How many people will play?' — OMNIServers recommends a size for that and your kind of server."),
            S("Keep the slider under the tick marked as your PC's safe limit; going over it can make Windows itself slow."),
            S("Press Save. Restart the server to use the new size."),
        ], ["Mods and big modpacks need more (4–8 GB). A small Paper server for friends is fine on 2–4 GB.", "The server only uses what it needs; the number is a ceiling."]),

        T("server-properties", "Change the name, difficulty, game mode and more", "The everyday server options.", [ServerSettings], ["motd", "difficulty", "gamemode", "max players", "pvp", "view distance", "port", "flight", "command blocks"],
        [
            S("Open the server's Settings tab.", Go("Open Settings", "Settings")),
            S("'General' sets the name and the message friends see in their server list."),
            S("'World & gameplay' has game mode, difficulty, max players, port, view distance, PvP, whitelist, flight and command blocks."),
            S("Press Save (the bar at the bottom). Most changes apply the next time the server starts."),
        ], ["You can't change the port or memory while the server runs.", "Lower view distance (for example 6–8) makes a slow PC run better."]),

        T("automation", "Automatic restarts and backups", "Let OMNIServers look after the server.", [ServerSettings], ["automatic", "auto restart", "crash", "daily restart", "backup after stop", "start with craftpanel", "schedule"],
        [
            S("Open Settings and scroll to 'Automation'.", Go("Open Settings", "Settings")),
            S("'Restart if it crashes' starts it again after a crash (with a limit so a broken server doesn't loop)."),
            S("'Restart every day' restarts at a time you choose, after warning players for a minute."),
            S("'Back up after every stop' saves a backup each time the server shuts down."),
            S("'Start with OMNIServers' starts this server whenever OMNIServers opens."),
            S("Press Save."),
        ]),

        T("low-spec", "Tips for slow or small PCs", "Make a server and OMNIServers run better on weak hardware.", [ServerSettings, SettingsGeneral, SettingsDiagnostics], ["slow", "lag", "weak", "old pc", "school pc", "low end", "performance", "fps", "laggy", "light mode"],
        [
            S("Use Paper rather than Vanilla — it's much lighter."),
            S("Open the server's Settings and press 'Lighten for a slow PC…'. It shows what it will change (lower view and simulation distance) and you confirm.", Go("Open Settings", "Settings")),
            S("Keep the memory at the recommended size, not higher — too much memory slows a small PC down."),
            S("Settings → General → Performance: 'Automatic' already turns Light mode on for PCs with under 8 GB of memory or under 4 cores, and for remote-desktop sessions. Choose 'Always light' to force it.", Settings("Open General", "General")),
            S("Don't run the live map or add-ons you don't need, and close other programs (browsers use a lot of memory) before starting the server."),
            S("Fewer players and a smaller world border mean less work."),
        ], ["Light mode makes OMNIServers check server stats and the log less often; the game itself isn't affected.", "Changing Light mode applies the next time OMNIServers starts.", "The memory card warns you when your PC is short on memory or has few CPU cores."]),

        // ---------- mods ----------
        T("addons", "Install mods, plugins and datapacks", "Search Modrinth and install with one click.", [ServerAddons], ["mod", "plugin", "datapack", "modrinth", "install", "essentials", "worldedit"],
        [
            S("Open Add-ons (Vanilla servers can't load add-ons — use Change version to switch to Paper or Fabric first).", Go("Open Add-ons", "Addons")),
            S("Type a name under 'Browse' and press Search."),
            S("Press Install on the one you want. Anything it needs is installed too."),
            S("Restart the server. Check 'Installed from Modrinth' → 'Check for updates' now and then."),
        ], ["Mods must match your server software (Fabric mods need a Fabric server).", "Players usually need the same mods on their own game for mod servers."]),

        T("mods-toggle", "Turn mods on and off", "Disable a mod without deleting it.", [ServerMods], ["disable mod", "enable mod", "jar", "mods folder", "crash after mod"],
        [
            S("Open Mods. Every .jar in the mods folder is listed."),
            S("Use the switch beside a mod to turn it off or on. Restart the server."),
            S("'Add .jar…' copies a mod file in; 'Open folder' shows the folder."),
        ], ["If the server crashes after adding a mod, turn that mod off first."]),

        T("change-version", "Update or change the server version", "Move to a newer Minecraft or another server software.", [ServerSettings, ServerConsole, Overview], ["update", "upgrade", "version", "switch to paper", "change version"],
        [
            S("Make a backup first (Backups → Back up now).", Go("Open Backups", "Backups")),
            S("Stop the server, then open the ⋯ menu at the top right → 'Change version…'."),
            S("Pick the software and version, then 'Switch version'. Your world stays."),
        ], ["Worlds can go to newer versions but not back to older ones — keep the backup."]),

        // ---------- worlds ----------
        T("add-world", "Add a world (drag and drop)", "Bring a world from a friend or from single-player.", [ServerWorlds, ServerFiles], ["world", "save", "import world", "drag", "drop", "folder", "zip", "single player", "singleplayer", "saves", "download world"],
        [
            S("Open Worlds.", Go("Open Worlds", "Worlds")),
            S("Drag the world's folder or .zip file onto the OMNIServers window — or press 'Add a world' and choose 'From a folder…', 'From a .zip…', or 'From my single-player worlds…'."),
            S("OMNIServers finds the real world inside (the folder with level.dat) and shows its name, Minecraft version and size. Press 'Add world'."),
            S("Choose 'Use this world' when it asks, or later press 'Use this world' beside it. Start the server."),
        ], ["Your old world stays in its own folder — you can switch back any time.", "If the world is from a newer Minecraft than your server, OMNIServers warns you; update the server first.", "Only one world per drop."]),

        T("export-world", "Export a world to share", "Save your world as one .zip.", [ServerWorlds], ["export", "share world", "send world", "download", "zip world"],
        [
            S("Open Worlds and press 'Export world'.", Go("Open Worlds", "Worlds")),
            S("A .zip is saved to your Desktop and its folder opens."),
            S("Send it to a friend. They use 'Add a world → From a .zip…'."),
        ], ["A running server is paused for a moment so the copy is clean."]),

        T("switch-world", "Switch to another world or start a new one", "A server loads one world at a time.", [ServerWorlds], ["new world", "switch world", "level-name", "reset", "fresh world", "delete world"],
        [
            S("Stop the server and open Worlds."),
            S("Press 'Use this world' beside the world you want, or 'New world…' for a fresh one (it's generated at the next start)."),
            S("To get rid of a world press its bin button; it's moved to a trash folder inside the server, not erased."),
        ]),

        T("edit-level-dat", "Edit level.dat (advanced)", "Change a world's settings like the name or game rules.", [ServerWorlds, ServerFiles, ToolNbt], ["level.dat", "nbt", "edit world", "seed", "gamerule", "spawn"],
        [
            S("Stop the server (it rewrites this file while running).", Go("Open Worlds", "Worlds")),
            S("On Worlds press 'Edit level.dat' (or open the .dat file in Files)."),
            S("Open the tree, change a value in its box (a red box means the value isn't allowed), then press Save."),
        ], ["The old file is kept as level.dat.craftpanel-bak. Be careful: wrong values can stop a world loading."]),

        // ---------- backups ----------
        T("backup-now", "Make a backup", "A zip of your whole server.", [ServerBackups, SettingsBackups], ["backup", "save", "zip", "protect"],
        [
            S("Open Backups.", Go("Open Backups", "Backups")),
            S("Optionally type a label (like 'before the big update') and press 'Back up now'."),
            S("It's saved in the server's craftpanel-backups folder ('Open folder' shows it) and checked for damage."),
        ], ["'Keep the newest' removes older backups automatically; pre-restore and imported backups are never removed."]),

        T("restore-backup", "Restore a backup", "Put the server back the way it was.", [ServerBackups], ["restore", "rollback", "undo", "grief", "recover", "revert"],
        [
            S("Stop the server and open Backups."),
            S("Find the backup in 'Your backups' and press Restore, then confirm."),
            S("OMNIServers backs up the current state first and keeps it aside, then restores. If anything fails it puts everything back."),
        ]),

        T("import-backup", "Use a friend's backup", "Install a backup someone else made onto your server.", [ServerBackups], ["import backup", "friend's backup", "zip and json", "latest backup", "install backup"],
        [
            S("Get their backup .zip (and its .json if they have it) — put them in the same folder."),
            S("Open Backups and press 'Import backup…' under 'Your backups'.", Go("Open Backups", "Backups")),
            S("Pick the .zip (the .json next to it is found automatically). Check the summary and press Import."),
            S("It appears in your list tagged 'imported'. Stop the server and press Restore."),
        ], ["Nothing on your server changes until you press Restore.", "OMNIServers refuses zips that aren't server backups or that try to write outside the server folder."]),

        T("snapshots", "Time Machine snapshots", "Quick, tiny rollback points for just the world.", [ServerBackups, ServerSettings], ["snapshot", "time machine", "world only", "rollback", "hard link"],
        [
            S("Open Backups → Time Machine and press 'Snapshot now'.", Go("Open Backups", "Backups")),
            S("To take them automatically: Settings → Automation → 'Time Machine snapshots'.", Go("Open Settings", "Settings")),
            S("Restore a snapshot with its Restore button; only the world is swapped and the old world is kept aside."),
        ], ["Unchanged files cost no extra disk space, so the first snapshot is the size of the world and later ones are small."]),

        // ---------- files, map ----------
        T("files", "Edit files and configs", "Browse the server folder and edit text files.", [ServerFiles], ["files", "config", "yml", "json", "properties", "edit file", "upload", "add files"],
        [
            S("Open Files and click a folder to go in; the up arrow goes back."),
            S("Click a text file (.properties, .yml, .json, .txt…) to edit it on the right, then press Save."),
            S("'Add files…' copies files in; New folder, Rename and Delete work on the selected item (Delete moves it to a trash folder)."),
            S("Restart the server for config changes to apply."),
        ], ["You can only work inside the server's own folder."]),

        T("map", "Live map of your world", "A map with players moving on it (BlueMap).", [ServerMap], ["map", "bluemap", "dynmap", "3d", "overview map"],
        [
            S("Open Map and read the notice, then tick the Mojang box and press 'Install BlueMap'.", Go("Open Map", "Map")),
            S("Press 'Allow and turn on the map' if it asks, then restart the server."),
            S("Open the map link in your browser (friends on your network can use the shown address)."),
        ], ["The first render of a big world can take several minutes.", "Not for Vanilla or Bedrock servers."]),

        // ---------- app settings ----------
        T("themes", "Change the look (themes)", "Pick Dark, Light, Midnight or Sunset.", [SettingsGeneral], ["theme", "dark", "light", "appearance", "colour", "color"],
        [S("Open Settings → General → Appearance and click a theme.", Settings("Open General", "General"))]),

        T("notifications", "Join and leave notifications", "Be told when players come and go.", [SettingsGeneral, ServerChat], ["notification", "join", "leave", "alert", "popup"],
        [
            S("Open Settings → General → 'Players & chat'.", Settings("Open General", "General")),
            S("Switch 'Tell me when players join or leave' on or off, and optionally notify for every chat message."),
        ]),

        T("java", "Java versions", "OMNIServers installs the right Java by itself.", [SettingsJava, ServerSettings], ["java", "jre", "jdk", "install java", "version"],
        [
            S("Usually nothing to do: OMNIServers installs a matching Java when you create or start a server."),
            S("Settings → Java lists what's on this PC and lets you install or remove versions.", Settings("Open Java", "Java")),
            S("To use a specific Java for one server, set it under that server's Settings → Java ('Browse…')."),
        ]),

        T("app-lock", "Lock OMNIServers with a PIN", "Stop others opening it.", [SettingsAccount], ["pin", "lock", "password", "security", "protect"],
        [
            S("Open Settings → Account → 'App lock' and press 'Set or change PIN'.", Settings("Open Account", "Account")),
            S("OMNIServers asks for the PIN each time it starts. 'Turn off' removes it."),
        ], ["If you forget the PIN you'll need to remove the lock file (lock.json) from OMNIServers's data folder."]),

        T("keep-running", "Keep servers running when you close OMNIServers", "Servers can outlive the window.", [SettingsGeneral], ["quit", "close", "background", "keep running", "exit"],
        [
            S("Settings → General → 'Keep servers running when I quit OMNIServers'.", Settings("Open General", "General")),
            S("With it on, closing OMNIServers leaves your servers running; reopen it and it reconnects to them."),
        ]),

        // ---------- when things go wrong ----------
        T("report-problem", "Report a problem", "Save a file that shows what's wrong, to send to someone.", [SettingsDiagnostics, ToolReport, Overview], ["bug", "report", "crash", "error", "broken", "help me", "not working", "log"],
        [
            S("Press 'Report a problem…' (Settings → Diagnostics).", new("Report a problem…", HelpActionKind.ReportProblem)),
            S("Describe what happened, choose the server involved, and press 'Save report'."),
            S("Send the saved .zip. Your user name, PC name, IP addresses and passwords are removed from it first."),
        ], ["If OMNIServers can't even start, its error window has a 'Save a report to send' button.", "'Report on GitHub' opens a prefilled issue with only a short summary."]),

        T("school-pc", "Using OMNIServers on a school or work PC", "When you can't install things or write to usual folders.", [SettingsDiagnostics, SettingsAbout, Overview], ["school", "work", "usb", "portable", "locked", "no admin", "restricted", "download folder", "smartscreen"],
        [
            S("Run CraftPanel.exe from a folder you own (Downloads or a USB stick) — no installer needed."),
            S("To keep everything on the USB stick, put an empty file named portable.txt next to CraftPanel.exe. Everything is then stored in a 'CraftPanelData' folder beside it."),
            S("If the PC blocks the usual folders, OMNIServers switches to that folder by itself — Settings → Diagnostics says which.", Settings("Open Diagnostics", "Diagnostics")),
            S("Windows SmartScreen may warn about the app: choose 'More info' → 'Run anyway'."),
            S("Opening a firewall port needs an administrator; see 'Windows Firewall and school PCs'."),
            S("Something not working? 'Report a problem…' saves a file to send.", new("Report a problem…", HelpActionKind.ReportProblem)),
        ], ["Servers on a school network may not be reachable by other students; the free tunnel often works around that."]),

        T("health-check", "Health check", "A quick look at what could stop servers working.", [SettingsDiagnostics], ["health", "diagnostics", "check", "problems", "doctor"],
        [
            S("Open Settings → Diagnostics. It checks saving files, PowerShell, Java, disk space, ports, network, and Mojang's download servers.", Settings("Open Diagnostics", "Diagnostics")),
            S("Orange and red lines say what's wrong and what to do. Press 'Run again' after fixing something."),
        ]),

        T("overview-servers", "Your servers at a glance", "The first page: every server and its state.", [Overview], ["overview", "dashboard", "all servers", "home", "list", "status"],
        [
            S("Each server shows whether it's running and how many players are online."),
            S("Click a server (here or in the list on the left) to open it. New server is at the bottom left."),
            S("Press Help (or F1) on any page for tips about that page."),
        ]),

        T("about", "About OMNIServers", "Version and where your files are.", [SettingsAbout], ["about", "version", "credits", "licenses", "data folder"],
        [
            S("Settings → About shows the version of OMNIServers.", Settings("Open About", "About")),
            S("Settings → Diagnostics → 'Saving files' tells you where OMNIServers keeps its data.", Settings("Open Diagnostics", "Diagnostics")),
        ]),
    ];
}
