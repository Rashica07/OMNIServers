import Foundation

/// Aikar's flags preset and the resolved-launch-command preview for the
/// JVM args editor. Direct port of `commands.rs`'s `aikar_flags` and
/// `process::describe_launch`.
nonisolated enum JvmArgs {
    /// Aikar's flags (the heap flags come from the RAM slider, so
    /// they're omitted here — matches the Rust source's own comment).
    /// Without -XX:+AlwaysPreTouch: that touches every heap page up
    /// front, which on a desktop Mac just steals memory from macOS.
    static func aikarFlags(ramMB: UInt32) -> String {
        let big = ramMB >= 12_288
        let newPct = big ? 40 : 30
        let maxNew = big ? 50 : 40
        let region = big ? "16M" : "8M"
        let reserve = big ? 15 : 20
        let ihop = big ? 20 : 15
        return "-XX:+UseG1GC -XX:+ParallelRefProcEnabled -XX:MaxGCPauseMillis=200 "
            + "-XX:+UnlockExperimentalVMOptions -XX:+DisableExplicitGC "
            + "-XX:G1NewSizePercent=\(newPct) -XX:G1MaxNewSizePercent=\(maxNew) -XX:G1HeapRegionSize=\(region) "
            + "-XX:G1ReservePercent=\(reserve) -XX:G1HeapWastePercent=5 -XX:G1MixedGCCountTarget=4 "
            + "-XX:InitiatingHeapOccupancyPercent=\(ihop) -XX:G1MixedGCLiveThresholdPercent=90 "
            + "-XX:G1RSetUpdatingPauseTimePercent=5 -XX:SurvivorRatio=32 -XX:+PerfDisableSharedMem "
            + "-XX:MaxTenuringThreshold=1 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true"
    }

    /// The exact `java …` line this server would launch with — for the
    /// "show launch command" preview. Bedrock servers just run their own
    /// binary with no JVM involved at all.
    static func describeLaunch(record: ServerRecord) -> String {
        if record.serverType.isBedrock {
            return "\(BedrockAdapter.binaryName) (in \(record.path))"
        }
        let config = ServerConfig(
            path: URL(fileURLWithPath: record.path), launchTarget: record.launchTarget,
            javaPath: record.javaPath, ramMB: record.ramMB, serverType: record.serverType,
            jvmArgs: CrossplayManager.launchJvmArgs(serverDir: URL(fileURLWithPath: record.path), serverType: record.serverType, userArgs: record.jvmArgs)
        )
        let proc = MinecraftAdapter().startCommand(config: config)
        let program = proc.executableURL?.path ?? record.javaPath
        let args = (proc.arguments ?? []).joined(separator: " ")
        return "\(program) \(args)"
    }
}
