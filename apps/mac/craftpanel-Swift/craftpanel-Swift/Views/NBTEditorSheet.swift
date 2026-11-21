import SwiftUI

/// Port of `NbtEditor.tsx`: a generic, expandable NBT tree with inline
/// editing of numbers and strings. Saving keeps the previous file as
/// `<name>.craftpanel-bak` and preserves gzip/uncompressed as read.
/// Disabled while the server runs — it rewrites level.dat on save/stop.
struct NBTEditorSheet: View {
    let url: URL
    let title: String
    let serverRunning: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var rootName = ""
    @State private var root: NBTNode?
    @State private var original: NBTNode?
    @State private var gzip = true
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NBT editor").font(CPFont.display(16))
                    Text(title).font(CPFont.mono(11)).foregroundStyle(CPColor.inkFaint)
                }
                Spacer()
                Button("Close") { dismiss() }.cpButton(.ghost, size: .sm)
                Button(saving ? "Saving…" : "Save") { save() }
                    .cpButton(.primary, size: .sm)
                    .disabled(root == nil || root == original || serverRunning || saving)
            }
            .padding(16)
            if serverRunning {
                CPBanner(tone: .warn, message: "Stop the server to edit — it overwrites this file while running.")
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let error { CPBanner(tone: .bad, message: error).padding(.horizontal, 16).padding(.bottom, 8) }
            Divider().overlay(CPColor.line)
            ScrollView {
                if let root {
                    NBTTreeRow(label: rootName.isEmpty ? "(root)" : rootName, node: Binding(get: { root }, set: { self.root = $0 }), depth: 0)
                        .padding(12)
                } else if error == nil {
                    ProgressView().padding(40)
                }
            }
        }
        .frame(width: 640, height: 560)
        .background(CPColor.surface)
        .task { load() }
    }

    private func load() {
        do {
            let r = try NBT.read(url)
            rootName = r.name; root = r.root; original = r.root; gzip = r.gzip
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        guard let root else { return }
        saving = true
        defer { saving = false }
        do {
            try NBT.write(url, name: rootName, root: root, gzip: gzip)
            original = root
        } catch { self.error = error.localizedDescription }
    }
}

private struct NBTTreeRow: View {
    let label: String
    @Binding var node: NBTNode
    let depth: Int
    @State private var expanded = false

    var body: some View {
        switch node {
        case .compound(let kv):
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(kv.indices, id: \.self) { i in
                    NBTTreeRow(label: kv[i].0, node: Binding(
                        get: { if case .compound(let c) = node, i < c.count { return c[i].1 }; return .byte(0) },
                        set: { new in if case .compound(var c) = node, i < c.count { c[i].1 = new; node = .compound(c) } }
                    ), depth: depth + 1)
                }
            } label: { header("\(kv.count) entries") }
            .onAppear { if depth < 2 { expanded = true } }
        case .list(let et, let items):
            DisclosureGroup(isExpanded: $expanded) {
                ForEach(items.indices, id: \.self) { i in
                    NBTTreeRow(label: "[\(i)]", node: Binding(
                        get: { if case .list(_, let l) = node, i < l.count { return l[i] }; return .byte(0) },
                        set: { new in if case .list(let t, var l) = node, i < l.count { l[i] = new; node = .list(elementType: t, l) } }
                    ), depth: depth + 1)
                }
            } label: { header("\(items.count) items") }
            .id(et)
        default:
            HStack(spacing: 8) {
                Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(CPColor.ink)
                Text(node.typeName).font(.system(size: 10)).foregroundStyle(CPColor.inkGhost)
                Spacer()
                ScalarField(node: $node)
            }
            .padding(.vertical, 2)
        }
    }

    private func header(_ detail: String) -> some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 12, weight: .semibold)).foregroundStyle(CPColor.ink)
            Text("\(node.typeName) · \(detail)").font(.system(size: 10)).foregroundStyle(CPColor.inkGhost)
        }
    }
}

/// Edits a primitive in place; invalid input for the tag's type is ignored.
/// Longs are edited as text, so 64-bit seeds are never rounded.
private struct ScalarField: View {
    @Binding var node: NBTNode
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(CPFont.mono(11))
            .frame(width: 260)
            .onAppear { text = Self.format(node) }
            .onSubmit { commit() }
            .onChange(of: text) { _, _ in commit() }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespaces)
        func list<T>(_ f: (String) -> T?) -> [T]? {
            let parts = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let vals = parts.compactMap(f)
            return vals.count == parts.count ? vals : nil
        }
        switch node {
        case .byte: if let v = Int8(t) { node = .byte(v) }
        case .short: if let v = Int16(t) { node = .short(v) }
        case .int: if let v = Int32(t) { node = .int(v) }
        case .long: if let v = Int64(t) { node = .long(v) }
        case .float: if let v = Float(t) { node = .float(v) }
        case .double: if let v = Double(t) { node = .double(v) }
        case .string: node = .string(text)
        case .byteArray: if let v = list({ Int8($0) }) { node = .byteArray(v) }
        case .intArray: if let v = list({ Int32($0) }) { node = .intArray(v) }
        case .longArray: if let v = list({ Int64($0) }) { node = .longArray(v) }
        case .list, .compound: break
        }
    }

    static func format(_ n: NBTNode) -> String {
        switch n {
        case .byte(let v): "\(v)"
        case .short(let v): "\(v)"
        case .int(let v): "\(v)"
        case .long(let v): "\(v)"
        case .float(let v): "\(v)"
        case .double(let v): "\(v)"
        case .string(let s): s
        case .byteArray(let a): a.map(String.init).joined(separator: ", ")
        case .intArray(let a): a.map(String.init).joined(separator: ", ")
        case .longArray(let a): a.map(String.init).joined(separator: ", ")
        case .list, .compound: ""
        }
    }
}
