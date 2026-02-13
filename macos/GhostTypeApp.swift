import AppKit
import SwiftUI

@main
struct GhostTypeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared
    @StateObject private var historyStore = HistoryStore.shared

    var body: some Scene {
        WindowGroup("GhostType") {
            ContentView(state: state, historyStore: historyStore)
                .frame(minWidth: 1080, minHeight: 760)
        }

        MenuBarExtra("GhostType", systemImage: "waveform.badge.magnifyingglass") {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                if let mainWindow = NSApp.windows.first(where: { $0.canBecomeMain }) {
                    mainWindow.makeKeyAndOrderFront(nil)
                }
            } label: {
                Label("Open Main Window", systemImage: "macwindow")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
            }
        }
    }
}
