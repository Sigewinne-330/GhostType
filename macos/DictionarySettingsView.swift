import SwiftUI

struct DictionaryItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var originalText: String
    var correctedText: String
}

private struct DictionaryDocument: Codable {
    var items: [DictionaryItem]
}

@MainActor
final class DictionaryStore: ObservableObject {
    @Published private(set) var items: [DictionaryItem] = []

    nonisolated static var defaultFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return appSupport
            .appendingPathComponent("GhostType", isDirectory: true)
            .appendingPathComponent("dictionary.json")
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        load()
    }

    func load() {
        do {
            try ensureDirectory()
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try migrateLegacyIfNeeded()
                if !FileManager.default.fileExists(atPath: fileURL.path) {
                    try persist(items: [])
                }
            }

            let data = try Data(contentsOf: fileURL)
            let document = try decoder.decode(DictionaryDocument.self, from: data)
            items = sanitize(document.items)
        } catch {
            items = []
        }
    }

    func upsert(_ item: DictionaryItem) {
        var next = items
        if let index = next.firstIndex(where: { $0.id == item.id }) {
            next[index] = item
        } else {
            next.append(item)
        }
        commit(next)
    }

    func delete(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        commit(items.filter { !ids.contains($0.id) })
    }

    private func commit(_ next: [DictionaryItem]) {
        let sanitized = sanitize(next)
        do {
            try persist(items: sanitized)
            items = sanitized
        } catch {
            items = sanitized
        }
    }

    private func sanitize(_ source: [DictionaryItem]) -> [DictionaryItem] {
        var seen = Set<UUID>()
        var normalized: [DictionaryItem] = []
        for item in source {
            let original = item.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = item.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty, !corrected.isEmpty else { continue }
            guard !seen.contains(item.id) else { continue }
            seen.insert(item.id)
            normalized.append(DictionaryItem(id: item.id, originalText: original, correctedText: corrected))
        }
        return normalized
    }

    private func persist(items: [DictionaryItem]) throws {
        try ensureDirectory()
        let data = try encoder.encode(DictionaryDocument(items: items))
        try data.write(to: fileURL, options: [.atomic])
    }

    private func ensureDirectory() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func migrateLegacyIfNeeded() throws {
        let legacyURL = fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent("custom_dictionary.json")
        guard FileManager.default.fileExists(atPath: legacyURL.path) else { return }

        let data = try Data(contentsOf: legacyURL)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let terms = raw["terms"] as? [Any] else {
            return
        }

        var migrated: [DictionaryItem] = []
        for term in terms {
            let text = String(describing: term).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            migrated.append(DictionaryItem(originalText: text, correctedText: text))
        }

        try persist(items: migrated)
    }
}

struct DictionarySettingsView: View {
    private let fileURL: URL

    @StateObject private var store: DictionaryStore
    @State private var selection = Set<UUID>()
    @State private var query = ""
    @State private var presentingEditor = false
    @State private var editingItem: DictionaryItem?

    init(fileURL: URL = DictionaryStore.defaultFileURL) {
        self.fileURL = fileURL
        _store = StateObject(wrappedValue: DictionaryStore(fileURL: fileURL))
    }

    private func ui(_ zh: String, _ en: String) -> String {
        AppState.shared.ui(zh, en)
    }

    private var filteredItems: [DictionaryItem] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return store.items }
        return store.items.filter {
            $0.originalText.localizedCaseInsensitiveContains(normalized) ||
            $0.correctedText.localizedCaseInsensitiveContains(normalized)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Label(ui("自定义词典", "Custom Dictionary"), systemImage: "books.vertical")
                    .font(.headline)

                Text(ui("词典文件：\(fileURL.path)", "Dictionary File: \(fileURL.path)"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                TextField(ui("搜索原词或修正词", "Search source or corrected terms"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .cornerRadius(8)
                    .shadow(radius: 2, y: 1)

                Button {
                    openCreateSheet()
                } label: {
                    Label("Add Item", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    removeSelection()
                } label: {
                    Label("Remove Item", systemImage: "minus")
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty)
            }

            List(selection: $selection) {
                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        ui("暂无词条", "No dictionary entries"),
                        systemImage: "text.book.closed",
                        description: Text(ui("点击 Add Item 新建你的第一条专属词典映射。", "Click Add Item to create your first custom mapping."))
                    )
                } else {
                    ForEach(filteredItems) { item in
                        HStack(alignment: .center, spacing: 14) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ui("原词", "Source"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.originalText)
                                    .font(.body.weight(.medium))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(ui("修正为", "Corrected"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(item.correctedText)
                                    .font(.body.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                        .tag(item.id)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {
                                openEditSheet(item)
                            } label: {
                                Label(ui("编辑", "Edit"), systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                    store.delete(ids: [item.id])
                                    selection.remove(item.id)
                                }
                            } label: {
                                Label(ui("删除", "Delete"), systemImage: "trash")
                            }
                        }
                        .onTapGesture(count: 2) {
                            openEditSheet(item)
                        }
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(radius: 2, y: 1)
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .sheet(isPresented: $presentingEditor) {
            DictionaryItemEditorSheet(
                item: editingItem,
                onSave: { item in
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        store.upsert(item)
                    }
                    presentingEditor = false
                },
                onCancel: {
                    presentingEditor = false
                }
            )
        }
        .onAppear {
            store.load()
        }
    }

    private func openCreateSheet() {
        editingItem = DictionaryItem(originalText: "", correctedText: "")
        presentingEditor = true
    }

    private func openEditSheet(_ item: DictionaryItem) {
        editingItem = item
        presentingEditor = true
    }

    private func removeSelection() {
        guard !selection.isEmpty else { return }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            store.delete(ids: selection)
            selection.removeAll()
        }
    }
}

private struct DictionaryItemEditorSheet: View {
    @State private var draft: DictionaryItem

    let onSave: (DictionaryItem) -> Void
    let onCancel: () -> Void

    init(item: DictionaryItem?, onSave: @escaping (DictionaryItem) -> Void, onCancel: @escaping () -> Void) {
        _draft = State(initialValue: item ?? DictionaryItem(originalText: "", correctedText: ""))
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var isValid: Bool {
        !draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !draft.correctedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ui(_ zh: String, _ en: String) -> String {
        AppState.shared.ui(zh, en)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(ui("词典词条", "Dictionary Entry"))
                .font(.title3.weight(.semibold))

            Form {
                TextField(ui("原词（例如：泰普勒斯）", "Source (e.g. GhostType)"), text: $draft.originalText)
                    .textFieldStyle(.roundedBorder)

                TextField(ui("修正为（例如：GhostType）", "Corrected (e.g. GhostType)"), text: $draft.correctedText)
                    .textFieldStyle(.roundedBorder)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(ui("取消", "Cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(ui("保存", "Save")) {
                    onSave(
                        DictionaryItem(
                            id: draft.id,
                            originalText: draft.originalText.trimmingCharacters(in: .whitespacesAndNewlines),
                            correctedText: draft.correctedText.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(.regularMaterial)
    }
}
