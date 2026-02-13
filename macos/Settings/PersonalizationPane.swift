import SwiftUI

struct PersonalizationPane: View {
    @ObservedObject var prefs: UserPreferences
    @ObservedObject var runtime: RuntimeState
    let dictionaryFileURL: URL

    @State private var statusText: String = ""

    var body: some View {
        DetailContainer(
            icon: "book.closed",
            title: prefs.ui("个性化与词典", "Personalization & Dictionary"),
            subtitle: prefs.ui("结构化管理专属词条与风格学习", "Manage custom terms and style learning")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                DictionarySettingsView(fileURL: dictionaryFileURL)
                    .frame(minHeight: 360)

                GroupBox(prefs.ui("写作风格学习", "Writing Style Learning")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(prefs.ui("可在此清空模型自动学习到的风格规则，不影响词典词条。", "You can clear learned style rules here. Dictionary entries will not be affected."))
                            .foregroundStyle(.secondary)

                        Button(role: .destructive) {
                            BackendManager.shared.clearStyleProfile { result in
                                switch result {
                                case .success:
                                    statusText = "Style profile cleared."
                                case .failure(let error):
                                    statusText = "Failed to clear style profile."
                                    runtime.lastError = "Style clear failed: \(error.localizedDescription)"
                                }
                            }
                        } label: {
                            Label("Clear Style Learning Data", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if !statusText.isEmpty {
                    Text(statusText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
