import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// In-app file browser for a server folder: navigate, view/edit text
/// files, rename, delete (to trash), create folders, import files.
/// Entirely missing from the native app until now -- the Tauri app has
/// its own "Files" tab (`FilesPanel.tsx`) this had no counterpart for at
/// all.
struct FilesView: View {
    let server: ServerRecord

    @State private var currentRel = ""
    @State private var listing: FileListing?
    @State private var errorText: String?
    @State private var editing: FileEntry?
    @State private var editText = ""
    @State private var editIsBinary = false
    @State private var editTruncated = false
    @State private var newFolderName = ""
    @State private var showingNewFolder = false
    @State private var isImporting = false
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var nbtEntry: FileEntry?
    @Environment(ProcessManager.self) private var processes

    private var root: URL { URL(fileURLWithPath: server.path) }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            HStack(spacing: 8) {
                Spacer()
                Button { showingNewFolder = true } label: { Label("New folder", systemImage: "folder.badge.plus") }
                    .cpButton(.secondary, size: .sm)
                Button { isImporting = true } label: { Label("Import", systemImage: "square.and.arrow.down") }
                    .cpButton(.secondary, size: .sm)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            if let errorText {
                CPBanner(tone: .bad, message: errorText)
                    .padding(8)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if let parent = listing?.parent {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.left")
                            Text("..")
                        }
                        .foregroundStyle(CPColor.inkFaint)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { navigate(to: parent) }
                    }
                    ForEach(listing?.entries ?? []) { entry in
                        FileRow(entry: entry)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if entry.isDir {
                                    navigate(to: entry.rel)
                                } else {
                                    open(entry)
                                }
                            }
                            .contextMenu {
                                if !entry.isDir {
                                    Button("Save a Copy…") { exportEntry(entry) }
                                }
                                Button("Rename…") { renaming = entry; renameText = entry.rel }
                                Button("Delete", role: .destructive) { delete(entry) }
                            }
                    }
                }
                .padding(8)
            }
            .background(CPColor.bg)
        }
        .navigationTitle("Files")
        .task(id: "\(server.id)-\(currentRel)") { reload() }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Cancel", role: .cancel) { newFolderName = "" }
            Button("Create") { createFolder() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") { if let entry = renaming { rename(entry) } }
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importFiles(urls) }
        }
        .sheet(item: $nbtEntry) { entry in
            if let url = try? ServerFileBrowser.confinedURL(root: root, rel: entry.rel) {
                NBTEditorSheet(url: url, title: entry.rel, serverRunning: processes.isRunning(server.id))
            }
        }
        .sheet(item: $editing) { entry in
            FileEditorSheet(
                entry: entry, text: $editText, isBinary: editIsBinary, truncated: editTruncated,
                onSave: { newText in save(entry, newText) }
            )
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "house.fill", size: 24, tint: currentRel.isEmpty ? CPColor.accent : CPColor.inkFaint) {
                navigate(to: "")
            }

            ForEach(Array(pathComponents.enumerated()), id: \.offset) { idx, comp in
                Text("/").foregroundStyle(CPColor.inkGhost)
                Button(comp) {
                    navigate(to: pathComponents[0...idx].joined(separator: "/"))
                }
                .buttonStyle(.plain)
                .foregroundStyle(idx == pathComponents.count - 1 ? CPColor.accent : CPColor.inkFaint)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            Spacer()
        }
        .font(.system(.caption, design: .monospaced))
        .padding(10)
        .background(CPColor.surface)
    }

    private var pathComponents: [String] {
        currentRel.isEmpty ? [] : currentRel.split(separator: "/").map(String.init)
    }

    private func navigate(to rel: String) {
        currentRel = rel
    }

    private func reload() {
        do {
            listing = try ServerFileBrowser.list(root: root, rel: currentRel)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func open(_ entry: FileEntry) {
        let lower = entry.name.lowercased()
        if lower.hasSuffix(".dat") || lower.hasSuffix(".dat_old") || lower.hasSuffix(".nbt") {
            nbtEntry = entry
            return
        }
        do {
            let view = try ServerFileBrowser.read(root: root, rel: entry.rel)
            editText = view.text
            editIsBinary = view.binary
            editTruncated = view.truncated
            editing = entry
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func save(_ entry: FileEntry, _ text: String) {
        do {
            try ServerFileBrowser.write(root: root, rel: entry.rel, content: text)
            editing = nil
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ entry: FileEntry) {
        do {
            try ServerFileBrowser.delete(root: root, rel: entry.rel)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func createFolder() {
        defer { newFolderName = "" }
        guard !newFolderName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let rel = currentRel.isEmpty ? newFolderName : "\(currentRel)/\(newFolderName)"
        do {
            try ServerFileBrowser.mkdir(root: root, rel: rel)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func rename(_ entry: FileEntry) {
        defer { renaming = nil; renameText = "" }
        let to = renameText.trimmingCharacters(in: .whitespaces)
        guard !to.isEmpty, to != entry.rel else { return }
        do {
            try ServerFileBrowser.rename(root: root, from: entry.rel, to: to)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// "Save a copy somewhere else" — an `NSSavePanel`, the native
    /// counterpart of Tauri's own save-dialog plugin for `fs_export`.
    private func exportEntry(_ entry: FileEntry) {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = entry.name
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        do {
            try ServerFileBrowser.export(root: root, rel: entry.rel, dest: dest)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func importFiles(_ urls: [URL]) {
        do {
            _ = try ServerFileBrowser.importFiles(root: root, dirRel: currentRel, sources: urls)
            reload()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

private struct FileRow: View {
    let entry: FileEntry
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.isDir ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDir ? CPColor.accent : CPColor.inkFaint)
                .frame(width: 16)
            Text(entry.name)
                .foregroundStyle(CPColor.ink)
            Spacer()
            if !entry.isDir {
                Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file))
                    .font(.caption)
                    .foregroundStyle(CPColor.inkFaint)
            }
            Text(Date(timeIntervalSince1970: TimeInterval(entry.modified)).formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(CPColor.inkFaint)
                .frame(width: 140, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(hovering ? CPColor.surface2 : .clear)
        .clipShape(RoundedRectangle(cornerRadius: CPRadius.sm, style: .continuous))
        .onHover { hovering = $0 }
    }
}

private struct FileEditorSheet: View {
    let entry: FileEntry
    @Binding var text: String
    let isBinary: Bool
    let truncated: Bool
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isBinary {
                    CPEmptyState(icon: "doc.badge.gearshape", title: "Binary File", message: "This file isn't text and can't be edited here.")
                } else {
                    VStack(spacing: 0) {
                        if truncated {
                            CPBanner(tone: .warn, message: "This file is large — only the first 2 MB is shown.")
                                .padding(8)
                        }
                        SyntaxTextView(text: $text, lang: ConfigLang.forFile(entry.rel))
                    }
                }
            }
            .navigationTitle(entry.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                if !isBinary {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { onSave(text); dismiss() }
                    }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}
