import SwiftUI

@main
struct ShortVidApp: App {
    @State private var updater = YtdlpUpdater()

    var body: some Scene {
        Window("ShortVid", id: "main") {
            ContentView()
                .environment(updater)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateYtdlpMenuItem(updater: updater)
            }
        }
    }
}

/// "Update yt-dlp…" in the application menu. Brings the status window
/// forward so the progress and result are visible.
private struct UpdateYtdlpMenuItem: View {
    @Environment(\.openWindow) private var openWindow
    let updater: YtdlpUpdater

    var body: some View {
        Button("Update yt-dlp…") {
            openWindow(id: "main")
            updater.start()
        }
        .disabled(updater.isRunning)
    }
}
