import SwiftUI

/// Memory allocation — port of Tauri's `RamSlider.tsx` plus a dynamic
/// recommendation: the number follows "how many people will play" and
/// the server kind until you drag the slider yourself; "Use
/// recommended" snaps back. The safe limit is a tick on the track.
struct RamPicker: View {
    @Binding var ramMB: Double
    let kind: RamAdvisor.Kind
    /// nil hides the players stepper (e.g. existing servers).
    var players: Binding<Int>? = nil
    /// Start following the recommendation (new servers) or not (existing).
    var followsInitially = true
    var otherAllocatedMB = 0
    var disabled = false

    @State private var system = SystemMemory.current()
    @State private var following: Bool?

    private var playerCount: Int { players?.wrappedValue ?? 4 }
    private var recommended: Int { RamAdvisor.recommend(kind: kind, players: playerCount, safeMaxMB: system.safeMaxMB) }
    private var maxMB: Int { max(system.totalMB, Int(ramMB), 4096) }
    private var overSafe: Bool { Int(ramMB) > system.safeMaxMB }
    private var isFollowing: Bool { following ?? followsInitially }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Memory for this server", systemImage: "memorychip")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CPColor.inkFaint)
                    Text("More memory lets you run more mods and players — it doesn't make the game faster on its own.")
                        .font(.system(size: 11)).foregroundStyle(CPColor.inkFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(gbNumber(Int(ramMB)))
                    .font(CPFont.display(26)).monospacedDigit()
                    .foregroundStyle(overSafe ? CPColor.warn : CPColor.ink)
                Text("GB").font(.system(size: 12)).foregroundStyle(CPColor.inkFaint)
            }

            if let players {
                HStack {
                    Text("How many people will play?").font(.system(size: 12)).foregroundStyle(CPColor.inkDim)
                    Spacer()
                    Stepper(value: players, in: 1...200) {
                        Text("\(players.wrappedValue)").font(.system(size: 12, design: .monospaced))
                    }
                    .fixedSize()
                }
            }

            CPSlider(value: Binding(get: { ramMB }, set: { ramMB = $0; following = false }),
                     range: Double(RamAdvisor.minMB)...Double(maxMB), step: 512,
                     markers: [Double(system.safeMaxMB)])
                .disabled(disabled)
                .opacity(disabled ? 0.5 : 1)
                .help("The tick is \(SystemRAM.format(mb: system.safeMaxMB)) — the most this Mac can spare without starving macOS.")

            HStack(spacing: 6) {
                Text(SystemRAM.format(mb: RamAdvisor.minMB))
                Spacer()
                if overSafe {
                    Label("Over the \(SystemRAM.format(mb: system.safeMaxMB)) safe limit", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(CPColor.warn)
                } else {
                    Text(systemLine)
                }
                Spacer()
                Text(SystemRAM.format(mb: maxMB))
            }
            .font(.system(size: 10.5)).monospacedDigit()
            .foregroundStyle(CPColor.inkFaint)

            if kind != .bedrock {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(CPColor.accent)
                    Text("Recommended: **\(SystemRAM.format(mb: recommended))** for \(kind.label)\(players != nil ? " with \(playerCount) player\(playerCount == 1 ? "" : "s")" : "")")
                        .font(.system(size: 12)).foregroundStyle(CPColor.inkDim)
                    Spacer()
                    if Int(ramMB) != recommended && !disabled {
                        Button("Use recommended") { following = true; ramMB = Double(recommended) }
                            .cpButton(.ghost, size: .sm)
                    }
                }
            }

            ForEach(RamAdvisor.warnings(chosenMB: Int(ramMB), kind: kind, players: playerCount, system: system, otherAllocatedMB: otherAllocatedMB)) { w in
                CPBanner(tone: w.level == .serious ? .warn : .neutral, message: w.message)
            }
        }
        .task {
            system = await SystemMemory.detailed()
            if isFollowing { ramMB = Double(recommended) }
        }
        .onChange(of: recommended) { _, new in if isFollowing { ramMB = Double(new) } }
    }

    private var systemLine: String {
        var parts = ["\(SystemRAM.format(mb: system.totalMB))\(system.memoryType.map { " \($0)" } ?? "")"]
        parts.append(system.chip.replacingOccurrences(of: "Apple ", with: ""))
        parts.append("\(SystemRAM.format(mb: system.availableMB)) free now")
        return parts.joined(separator: " · ")
    }

    private func gbNumber(_ mb: Int) -> String {
        mb % 1024 == 0 ? "\(mb / 1024)" : String(format: "%.1f", Double(mb) / 1024)
    }
}

extension View {
    /// "Are you sure?" before installing when the memory advice has
    /// warnings (too little RAM for the server, over the safe limit, or a
    /// weak Mac). Non-empty `warnings` presents it.
    func ramWarningConfirmation(_ warnings: Binding<[RamAdvisor.Warning]>, proceed: @escaping () -> Void) -> some View {
        alert("This Mac might struggle with this server", isPresented: Binding(
            get: { !warnings.wrappedValue.isEmpty }, set: { if !$0 { warnings.wrappedValue = [] } })) {
            Button("Install anyway") { warnings.wrappedValue = []; proceed() }
            Button("Go back", role: .cancel) {}
        } message: {
            Text(warnings.wrappedValue.map { "• " + $0.message }.joined(separator: "\n\n"))
        }
    }
}
