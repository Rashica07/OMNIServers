import SwiftUI

/// View + delete for a Bedrock server's `resource_packs/` folder — see
/// `BedrockResourcePackManager`'s own doc comment for why this is a
/// genuinely new feature, not a Bedrock-flavored version of the Java
/// URL-slot resource pack card. Built against `CPKit` from the start —
/// no native-`List`/`Form` detour for new work.
struct BedrockResourcePacksView: View {
    let server: ServerRecord

    @State private var packs: [BedrockResourcePackManager.Pack] = []
    @State private var errorText: String?
    @State private var pendingDelete: BedrockResourcePackManager.Pack?

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if let errorText {
                    CPBanner(tone: .bad, message: errorText)
                }
                if packs.isEmpty {
                    CPEmptyState(
                        icon: "shippingbox",
                        title: "No resource packs found",
                        message: "Drop pack folders (each with its own manifest.json) into resource_packs/ next to this server, then come back here to view or remove them."
                    )
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                        ForEach(packs) { pack in
                            PackCard(pack: pack, onDelete: { pendingDelete = pack })
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(CPColor.bg)
        .navigationTitle("Resource Packs")
        .task(id: server.id) { reload() }
        .alert("Remove \(pendingDelete?.name ?? "")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Remove", role: .destructive) {
                if let pack = pendingDelete { delete(pack) }
            }
        } message: {
            Text("Moves the pack's folder to OMNIServers's trash — nothing is deleted permanently.")
        }
    }

    private func reload() {
        packs = BedrockResourcePackManager.list(serverDir: root)
    }

    private func delete(_ pack: BedrockResourcePackManager.Pack) {
        pendingDelete = nil
        do {
            try BedrockResourcePackManager.delete(serverDir: root, pack: pack)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct PackCard: View {
    let pack: BedrockResourcePackManager.Pack
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.name)
                        .font(CPFont.display(13, weight: .semibold))
                        .foregroundStyle(CPColor.ink)
                        .lineLimit(1)
                    if !pack.versionLabel.isEmpty {
                        Text(pack.versionLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(CPColor.inkFaint)
                    }
                }
                Spacer(minLength: 0)
            }
            if let description = pack.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(CPColor.inkFaint)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
            Button("Remove", action: onDelete)
                .cpButton(.danger, size: .sm, block: true)
        }
        .padding(12)
        .frame(height: 150, alignment: .top)
        .background(CPColor.surface)
        .overlay(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous).strokeBorder(CPColor.line, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.lg, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        if let iconURL = pack.iconURL, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous)
                    .fill(CPColor.accentMuted)
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(CPColor.accentSoft)
            }
            .frame(width: 36, height: 36)
        }
    }
}
