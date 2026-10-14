import AppIntents
import UniformTypeIdentifiers

/// The Shortcuts action: give it a URL, get back the video file.
struct DownloadVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Video"
    static let description = IntentDescription(
        "Downloads the video at a URL using yt-dlp and passes the file to the next action. Works with video pages (YouTube, Vimeo, X, TikTok, Instagram and hundreds more) as well as direct media links.",
        categoryName: "Video",
        resultValueName: "Video File"
    )
    static let openAppWhenRun = false

    @Parameter(
        title: "URL",
        description: "A link to a video page or a direct link to a media file."
    )
    var url: URL

    @Parameter(
        title: "Quality",
        description: "Highest quality takes the best streams available; 1080p, 720p and 480p cap the resolution and use less space.",
        default: .highest
    )
    var quality: VideoQuality

    @Parameter(
        title: "Force MP4",
        description: "Deliver an H.264 MP4 that QuickTime and Photos can play, converting with ffmpeg when the source isn't one already.",
        default: true
    )
    var forceMP4: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Download video at \(\.$url)") {
            \.$quality
            \.$forceMP4
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<IntentFile> {
        let video = try await VideoDownloader.download(url, quality: quality, forceMP4: forceMP4)
        let type = UTType(filenameExtension: video.fileURL.pathExtension) ?? .movie
        let file = IntentFile(fileURL: video.fileURL, filename: video.fileURL.lastPathComponent, type: type)
        return .result(value: file)
    }
}

/// Resolution cap for the download. yt-dlp picks the best streams whose
/// frame height fits; "Highest quality" leaves it uncapped.
nonisolated enum VideoQuality: String, AppEnum {
    case highest
    case p1080
    case p720
    case p480

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quality")
    static let caseDisplayRepresentations: [VideoQuality: DisplayRepresentation] = [
        .highest: "Highest quality",
        .p1080: "1080p",
        .p720: "720p",
        .p480: "480p",
    ]

    /// Maximum frame height in pixels, or nil for no cap.
    var maxHeight: Int? {
        switch self {
        case .highest: return nil
        case .p1080: return 1080
        case .p720: return 720
        case .p480: return 480
        }
    }
}

struct ShortVidShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: DownloadVideoIntent(),
            phrases: ["Download video with \(.applicationName)"],
            shortTitle: "Download Video",
            systemImageName: "arrow.down.circle"
        )
    }
}
