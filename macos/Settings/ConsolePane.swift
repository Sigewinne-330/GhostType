import SwiftUI

struct ConsolePane: View {
    @ObservedObject var prefs: UserPreferences
    @ObservedObject private var appLogger = AppLogger.shared

    var body: some View {
        DetailContainer(
            icon: "terminal",
            title: prefs.ui("运行日志", "Runtime Logs"),
            subtitle: prefs.ui("控制台 / 日志", "Console / Logs")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if appLogger.entries.isEmpty {
                                Text(prefs.ui("等待日志输出...", "Waiting for log output..."))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Color.white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                ForEach(appLogger.entries) { entry in
                                    Text(entry.formatted)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(
                                            entry.type == .error
                                                ? Color.red.opacity(0.92)
                                                : (entry.type == .warning
                                                    ? Color.yellow.opacity(0.92)
                                                    : Color.white.opacity(0.9))
                                        )
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(minHeight: 420)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .onChange(of: appLogger.entries.count) { _, _ in
                        guard let lastID = appLogger.entries.last?.id else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }

                HStack(spacing: 10) {
                    Button(prefs.ui("清空日志", "Clear Logs")) {
                        appLogger.clear()
                    }
                    .buttonStyle(.bordered)

                    Button(prefs.ui("复制全部", "Copy All")) {
                        appLogger.copyAllToPasteboard()
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    Text("\(appLogger.entries.count) lines")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
