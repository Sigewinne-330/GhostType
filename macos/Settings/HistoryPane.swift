import SwiftUI

struct HistoryPane: View {
    @ObservedObject var prefs: UserPreferences
    @ObservedObject var store: HistoryStore

    var body: some View {
        DetailContainer(
            icon: "clock.arrow.circlepath",
            title: prefs.ui("历史记录", "History"),
            subtitle: prefs.ui("按时间范围浏览转录与输出", "Browse transcriptions and outputs by time range")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Range", selection: $store.filter) {
                    ForEach(HistoryFilter.allCases) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Label(prefs.ui("\(store.entries.count) 条记录", "\(store.entries.count) record(s)"), systemImage: "doc.text")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(role: .destructive) {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            store.clearCurrentFilter()
                        }
                    } label: {
                        Label("Clear Filtered", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.entries.isEmpty)
                }

                List {
                    if store.entries.isEmpty {
                        Text(prefs.ui("当前筛选范围内没有记录。", "No records in the current filter range."))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(entry.mode)
                                        .font(.caption.weight(.semibold))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(.thinMaterial, in: Capsule())

                                    Spacer()

                                    Text(dateText(entry.createdAt))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Text(entry.outputText)
                                    .lineLimit(4)
                                    .textSelection(.enabled)

                                Text(prefs.ui("原文: \(entry.rawText)", "Raw: \(entry.rawText)"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 5)
                            .contextMenu {
                                Button(role: .destructive) {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                        store.delete(entryID: entry.id)
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(radius: 2, y: 1)
            }
        }
        .onAppear {
            store.reload()
        }
    }

    private func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
