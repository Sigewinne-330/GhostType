import AppKit
import SwiftUI

private enum MainModule: String, CaseIterable, Identifiable {
    case general
    case engines
    case prompts
    case history
    case personalization
    case developerSupport
    case console

    var id: String { rawValue }

    @MainActor
    func title(for state: AppState) -> String {
        switch self {
        case .general:
            return state.ui("快捷键与常规", "Hotkeys & General")
        case .engines:
            return state.ui("引擎与模型", "Engines & Models")
        case .prompts:
            return state.ui("提示词与预设", "Prompts & Presets")
        case .history:
            return state.ui("历史记录", "History")
        case .personalization:
            return state.ui("个性化与词典", "Personalization & Dictionary")
        case .developerSupport:
            return state.ui("开发者与支持", "Developer & Support")
        case .console:
            return state.ui("运行日志", "Runtime Logs")
        }
    }

    @MainActor
    func subtitle(for state: AppState) -> String {
        switch self {
        case .general:
            return state.ui("常规设置", "General")
        case .engines:
            return state.ui("引擎配置", "Engines")
        case .prompts:
            return state.ui("提示词配置", "Prompts")
        case .history:
            return state.ui("历史浏览", "History")
        case .personalization:
            return state.ui("个性化", "Personalization")
        case .developerSupport:
            return state.ui("联系与版本", "Contact & Version")
        case .console:
            return state.ui("日志控制台", "Console")
        }
    }

    var symbol: String {
        switch self {
        case .general:
            return "keyboard.badge.ellipsis"
        case .engines:
            return "cpu"
        case .prompts:
            return "text.bubble"
        case .history:
            return "clock.arrow.circlepath"
        case .personalization:
            return "book.closed"
        case .developerSupport:
            return "person.crop.circle.badge.questionmark"
        case .console:
            return "terminal"
        }
    }
}

struct ContentView: View {
    @ObservedObject var state: AppState
    @ObservedObject var historyStore: HistoryStore

    @State private var selection: MainModule? = .general

    var body: some View {
        NavigationSplitView {
            List(MainModule.allCases, selection: $selection) { module in
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(module.title(for: state))
                            .font(.headline)
                        Text(module.subtitle(for: state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: module.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.vertical, 4)
                .tag(module)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .scrollContentBackground(.hidden)
            .background(.ultraThinMaterial)
        } detail: {
            detailView(for: selection ?? .general)
        }
        .background(
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: selection)
        .overlay(alignment: .bottomTrailing) {
            GhostLogoDecoration()
                .padding(.trailing, 26)
                .padding(.bottom, 22)
        }
        .onAppear {
            _ = state.ensurePersonalizationFilesExist()
            historyStore.reload()
        }
    }

    @ViewBuilder
    private func detailView(for module: MainModule) -> some View {
        switch module {
        case .general:
            GeneralSettingsPane(engine: state.engine, prefs: state.prefs, runtime: state.runtime)
        case .engines:
            EnginesSettingsPane(engine: state.engine, prefs: state.prefs)
        case .prompts:
            PromptTemplatesPane(prefs: state.prefs, prompts: state.prompts, context: state.context)
        case .history:
            HistoryPane(prefs: state.prefs, store: historyStore)
        case .personalization:
            PersonalizationPane(
                prefs: state.prefs,
                runtime: state.runtime,
                dictionaryFileURL: state.dictionaryFileURL
            )
        case .developerSupport:
            DeveloperSupportPane(prefs: state.prefs)
        case .console:
            ConsolePane(prefs: state.prefs)
        }
    }
}

private struct GhostLogoDecoration: View {
    var body: some View {
        Image("GhostLogoDecor")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: 110)
            .saturation(0)
            .opacity(0.14)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct DetailContainer<Content: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 38, height: 38)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            content
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
        .padding(20)
    }
}
