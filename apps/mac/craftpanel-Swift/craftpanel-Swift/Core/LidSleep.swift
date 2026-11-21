import Foundation

/// "Keep running with the lid closed". macOS only allows this through `pmset disablesleep`, which needs an
/// administrator password, so turning it on or off shows the system password prompt. The real state is read back
/// from `pmset -g` instead of being remembered, so the switch never lies after a reboot or a manual change.
nonisolated enum LidSleep {
    static func command(disable: Bool) -> String { "/usr/bin/pmset -a disablesleep \(disable ? 1 : 0)" }

    /// `pmset -g` prints a line like "SleepDisabled\t\t1" while it is on.
    static func parseDisabled(_ pmsetG: String) -> Bool {
        for line in pmsetG.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return false
    }

    static func isDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseDisabled(String(decoding: data, as: UTF8.self))
    }

    /// Runs the change with the standard macOS password prompt. Returns whether the setting now matches.
    static func set(disable: Bool) async -> Bool {
        let script = "do shell script \"\(command(disable: disable))\" with administrator privileges"
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardOutput = Pipe(); p.standardError = Pipe()
            try? p.run(); p.waitUntilExit()
        }.value
        return isDisabled() == disable
    }
}
