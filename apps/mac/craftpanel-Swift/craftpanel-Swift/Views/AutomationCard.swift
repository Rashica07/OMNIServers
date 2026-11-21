import SwiftUI

/// "Keep it running by itself" — crash auto-restart, scheduled daily
/// start/restart, timed commands, and the backup/snapshot triggers.
/// Direct port of `AutomationSection.tsx`, backed by `Schedule`/
/// `ScheduleStore`; the actual engine lives in `Scheduler`.
struct AutomationCard: View {
    let server: ServerRecord

    @State private var sch = Schedule()
    @State private var saved = Schedule()
    @State private var busy = false
    @State private var errorText: String?
    @State private var note: String?

    private var dirty: Bool { sch != saved }

    var body: some View {
        SettingsCard(title: "Keep it running by itself", symbol: "clock.arrow.2.circlepath",
                     description: "Auto-restart after a crash, a nightly reboot, and scheduled commands.") {
            crashRow
            timeRow("Start every day at", value: $sch.scheduledStart,
                    note: sch.scheduledStart != nil
                        ? "Only fires if it's stopped. Turn on \"Stay awake on power\" in OMNIServers Settings so the Mac doesn't sleep through it."
                        : nil)
            timeRow("Restart every day at", value: $sch.dailyRestart,
                    note: sch.dailyRestart != nil ? "Players get a /say warning ~1 min before." : nil)

            CardToggleRow(label: "Back up every time the server stops", isOn: $sch.backupOnStop,
                          note: "Counts toward the keep-limit.")

            intervalBackupRow
            snapshotSection

            onStartSection
            timedCommandsSection

            HStack(spacing: 8) {
                Button(busy ? "Saving…" : (dirty ? "Save automation" : "Saved")) {
                    Task { await save() }
                }
                .cpButton(.primary)
                .disabled(busy || !dirty)
                if let note { Text(note).font(.caption2).foregroundStyle(CPColor.inkFaint) }
            }
            if let errorText {
                Label(errorText, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(CPColor.warn)
            }
        }
        .task(id: server.id) { reload() }
    }

    private var crashRow: some View {
        CardToggleRow(label: "Restart automatically if it crashes", isOn: $sch.restartOnCrash) {
            Stepper(value: Binding(
                get: { Int(sch.maxCrashRestarts == 0 ? 3 : sch.maxCrashRestarts) },
                set: { sch.maxCrashRestarts = UInt32(max(1, min(20, $0))) }
            ), in: 1...20) {
                Text("give up after \(sch.maxCrashRestarts == 0 ? 3 : sch.maxCrashRestarts) crashes in 15 min")
                    .font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
        }
    }

    private func timeRow(_ label: String, value: Binding<String?>, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Toggle(isOn: Binding(
                    get: { value.wrappedValue != nil },
                    set: { value.wrappedValue = $0 ? "00:00" : nil }
                )) {
                    Text(label)
                }
                .toggleStyle(.checkbox)
                Spacer()
                if value.wrappedValue != nil {
                    DatePicker("", selection: Binding(
                        get: { Self.date(from: value.wrappedValue) },
                        set: { value.wrappedValue = Self.hhmm(from: $0) }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .frame(width: 90)
                }
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(CPColor.inkFaint)
            }
        }
    }

    private var intervalBackupRow: some View {
        CardToggleRow(label: "Also back up automatically every", isOn: Binding(
            get: { sch.intervalBackupHours != nil },
            set: { sch.intervalBackupHours = $0 ? 6 : nil }
        )) {
            if sch.intervalBackupHours != nil {
                Stepper(value: Binding(
                    get: { Int(sch.intervalBackupHours ?? 6) },
                    set: { sch.intervalBackupHours = UInt32(max(1, min(168, $0))) }
                ), in: 1...168) {
                    Text("\(sch.intervalBackupHours ?? 6)h, while running")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                }
            }
        }
    }

    private var snapshotSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(CPColor.lineSoft).frame(height: 1).padding(.vertical, 2)
            CardToggleRow(label: "Take Time Machine snapshots every", isOn: Binding(
                get: { sch.snapshotIntervalMins != nil },
                set: { sch.snapshotIntervalMins = $0 ? 15 : nil }
            )) {
                if sch.snapshotIntervalMins != nil {
                    Stepper(value: Binding(
                        get: { Int(sch.snapshotIntervalMins ?? 15) },
                        set: { sch.snapshotIntervalMins = UInt32(max(5, min(1440, $0))) }
                    ), in: 5...1440) {
                        Text("\(sch.snapshotIntervalMins ?? 15) min, while running")
                            .font(.caption2).foregroundStyle(CPColor.inkFaint)
                    }
                }
            }
            if sch.snapshotIntervalMins != nil {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cheap, frequent rollback points — unchanged files are hard-linked, not copied. Browse and restore them from the timeline in the Backups tab.")
                        .font(.caption2).foregroundStyle(CPColor.inkFaint)
                    HStack(spacing: 16) {
                        Stepper(value: Binding(
                            get: { Int(sch.snapshotKeepRecentHours == 0 ? 24 : sch.snapshotKeepRecentHours) },
                            set: { sch.snapshotKeepRecentHours = UInt32(max(1, min(168, $0))) }
                        ), in: 1...168) {
                            Text("Keep all from the last \(sch.snapshotRecentHours)h")
                                .font(.caption2).foregroundStyle(CPColor.inkFaint)
                        }
                        Stepper(value: Binding(
                            get: { Int(sch.snapshotKeepDailyDays == 0 ? 30 : sch.snapshotKeepDailyDays) },
                            set: { sch.snapshotKeepDailyDays = UInt32(max(1, min(365, $0))) }
                        ), in: 1...365) {
                            Text("then 1/day for \(sch.snapshotDailyDays)d")
                                .font(.caption2).foregroundStyle(CPColor.inkFaint)
                        }
                    }
                }
                .padding(.leading, 22)
            }
        }
    }

    private var onStartSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(CPColor.lineSoft).frame(height: 1).padding(.vertical, 2)
            Text("WHEN THE SERVER STARTS").font(.caption2).foregroundStyle(CPColor.inkFaint)
            let cmds = sch.onStartCommands ?? []
            ForEach(cmds.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    TextField("gamerule keepInventory true", text: Binding(
                        get: { (sch.onStartCommands ?? [])[i] },
                        set: { sch.onStartCommands?[i] = $0 }))
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    IconButton(systemName: "xmark", size: 22) { sch.onStartCommands?.remove(at: i) }
                }
            }
            Button("+ Add start command") { sch.onStartCommands = (sch.onStartCommands ?? []) + [""] }
                .buttonStyle(.plain).font(.caption).foregroundStyle(CPColor.accent)
        }
    }

    private var timedCommandsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Rectangle().fill(CPColor.lineSoft).frame(height: 1).padding(.vertical, 2)
            Text("TIMED COMMANDS").font(.caption2).foregroundStyle(CPColor.inkFaint)
            ForEach(sch.timedCommands.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    DatePicker("", selection: Binding(
                        get: { Self.date(from: sch.timedCommands[i].at) },
                        set: { sch.timedCommands[i].at = Self.hhmm(from: $0) }
                    ), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                    .datePickerStyle(.stepperField)
                    .frame(width: 90)
                    TextField("save-all", text: $sch.timedCommands[i].command)
                        .font(.system(.caption, design: .monospaced))
                        .textFieldStyle(.roundedBorder)
                    IconButton(systemName: "xmark", size: 22) {
                        sch.timedCommands.remove(at: i)
                    }
                }
            }
            Button("+ Add command") {
                sch.timedCommands.append(TimedCommand(at: "03:00", command: ""))
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(CPColor.accent)
        }
    }

    private func reload() {
        sch = ScheduleStore.read(server)
        saved = sch
    }

    private func save() async {
        busy = true; errorText = nil; note = nil
        defer { busy = false }
        var clean = sch
        clean.timedCommands = sch.timedCommands.filter { !$0.at.trimmingCharacters(in: .whitespaces).isEmpty && !$0.command.trimmingCharacters(in: .whitespaces).isEmpty }
        clean.onStartCommands = (sch.onStartCommands ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let mins = clean.snapshotIntervalMins, mins > 0 {
            clean.snapshotIntervalMins = max(5, mins)
        }
        do {
            let written = try ScheduleStore.write(server, clean)
            sch = written
            saved = written
            note = "Automation saved."
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func date(from hhmm: String?) -> Date {
        let (h, m) = hhmm.flatMap(ScheduleStore.parseHHMM) ?? (0, 0)
        return Calendar.current.date(bySettingHour: h, minute: m, second: 0, of: Date()) ?? Date()
    }

    private static func hhmm(from date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }
}
