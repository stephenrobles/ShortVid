import AppKit
import SwiftUI

struct ContentView: View {
    @Environment(YtdlpUpdater.self) private var updater
    @State private var tester = DownloadTester()
    @State private var ffmpegVersion: String?
    @State private var denoVersion: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ShortVid")
                    .font(.title.bold())
                Text("Adds a **Download Video** action to Shortcuts. Give it a URL and it passes the video file to the next action.")
                    .foregroundStyle(.secondary)
            }

            GroupBox("Bundled tools") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        ytdlpRow
                        toolRow("ffmpeg", version: ffmpegVersion)
                        toolRow("deno", version: denoVersion)
                    }
                    HStack(alignment: .firstTextBaseline) {
                        updateStatusView
                        Spacer()
                        if updater.isRunning {
                            Button("Cancel") { updater.cancel() }
                        } else {
                            Button("Update yt-dlp…") { updater.start() }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Try it") {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Video URL", text: $tester.urlText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { tester.start() }
                    HStack {
                        Picker("Quality", selection: $tester.quality) {
                            Text("Highest quality").tag(VideoQuality.highest)
                            Text("4K").tag(VideoQuality.p2160)
                            Text("1080p").tag(VideoQuality.p1080)
                            Text("720p").tag(VideoQuality.p720)
                            Text("480p").tag(VideoQuality.p480)
                        }
                        .fixedSize()
                        Toggle("Force MP4", isOn: $tester.forceMP4)
                        if tester.forceMP4 {
                            Toggle("Compatible (H.264)", isOn: $tester.compatibleMP4)
                        }
                        Spacer()
                        if tester.isRunning {
                            ProgressView().controlSize(.small)
                            Button("Cancel") { tester.cancel() }
                        } else {
                            Button("Download") { tester.start() }
                                .keyboardShortcut(.defaultAction)
                                .disabled(tester.url == nil)
                        }
                    }
                    statusView
                }
                .padding(4)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            async let ffmpeg = BundledTools.version(of: BundledTools.ffmpeg)
            async let deno = BundledTools.version(of: BundledTools.deno)
            await updater.refreshStatus()
            ffmpegVersion = await ffmpeg
            denoVersion = await deno
        }
    }

    /// yt-dlp row: version, then "bundled" or "updated (bundled copy is …)".
    private var ytdlpRow: some View {
        GridRow {
            Text("yt-dlp").fontWeight(.medium)
            if let status = updater.status {
                if let version = status.active.version {
                    Text(version).monospacedDigit()
                } else {
                    Text("missing").foregroundStyle(.red)
                }
                Group {
                    switch status.active.source {
                    case .bundled:
                        Text("bundled")
                    case .updated:
                        Text("updated · bundled copy is \(status.bundledVersion ?? "missing")")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                Text("…").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updater.state {
        case .idle:
            Text("Downloads the latest release into Application Support.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .running(.downloading(let fraction)):
            ProgressView(value: fraction) {
                Text("Downloading yt-dlp… \(Int(fraction * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 260)
        case .running(.verifying):
            Label("Verifying the download…", systemImage: "checkmark.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .running(.installing):
            Label("Installing…", systemImage: "arrow.down.to.line")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .finished(.updated(let version)):
            Label("Updated to yt-dlp \(version).", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.green)
        case .finished(.alreadyCurrent(let version)):
            Label("yt-dlp \(version) is already the latest release.", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch tester.state {
        case .idle:
            EmptyView()
        case .running:
            Text("Downloading…")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .finished(let video):
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(video.fileURL.lastPathComponent)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([video.fileURL])
                }
            }
            .font(.callout)
            if video.wasConverted {
                Text("Converted to H.264 MP4 with ffmpeg.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if video.wasRemuxed {
                Text("Repackaged as MP4 without re-encoding the video.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
        }
    }

    private func toolRow(_ name: String, version: String?) -> some View {
        GridRow {
            Text(name).fontWeight(.medium)
            if let version {
                Text(version).monospacedDigit()
            } else {
                Text("missing").foregroundStyle(.red)
            }
        }
    }
}

@Observable
final class DownloadTester {
    enum State {
        case idle
        case running
        case finished(DownloadedVideo)
        case failed(String)
    }

    var urlText = ""
    var quality: VideoQuality = .highest
    var forceMP4 = true
    var compatibleMP4 = false
    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    var url: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func start() {
        guard let url, !isRunning else { return }
        state = .running
        let forceMP4 = forceMP4
        let compatibleMP4 = compatibleMP4
        let quality = quality
        task = Task {
            do {
                let video = try await VideoDownloader.download(url, quality: quality, forceMP4: forceMP4, compatibleMP4: compatibleMP4)
                state = .finished(video)
            } catch is CancellationError {
                state = .idle
            } catch let error as DownloadError {
                state = .failed(String(localized: error.localizedStringResource))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }
}

#Preview {
    ContentView()
        .environment(YtdlpUpdater())
}
