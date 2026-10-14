import AppIntents
import Foundation
import os

nonisolated enum DownloadError: Error, CustomLocalizedStringResourceConvertible {
    case toolMissing(String)
    case downloadFailed(String)
    case noOutputFile
    case conversionFailed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .toolMissing(let tool):
            return "ShortVid is missing its bundled \(tool). Reinstall the app."
        case .downloadFailed(let reason):
            return "Download failed: \(reason)"
        case .noOutputFile:
            return "yt-dlp finished but did not produce a file."
        case .conversionFailed(let reason):
            return "Converting to MP4 failed: \(reason)"
        }
    }
}

nonisolated struct DownloadedVideo: Sendable {
    let fileURL: URL
    let wasConverted: Bool
}

/// Downloads a video with the bundled yt-dlp and, on request, makes sure the
/// result is an MP4 that QuickTime and Photos can play (H.264/HEVC + AAC).
nonisolated enum VideoDownloader {
    /// Where finished files live. Each download gets its own folder so names
    /// never collide. Folders older than `retention` are swept on each run.
    static let downloadsDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "ShortVid"
        return caches.appending(path: bundleID).appending(path: "Downloads")
    }()

    static let retention: TimeInterval = 24 * 60 * 60

    static func download(_ url: URL, quality: VideoQuality = .highest, forceMP4: Bool) async throws -> DownloadedVideo {
        let ytdlp = await YtdlpResolver.shared.status().active
        for tool in [ytdlp.url, BundledTools.ffmpeg, BundledTools.ffprobe, BundledTools.deno] where !BundledTools.isInstalled(tool) {
            throw DownloadError.toolMissing(tool.lastPathComponent)
        }

        sweepOldDownloads()

        let jobDirectory = downloadsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        let downloaded = try await runYtdlp(ytdlp, url: url, into: jobDirectory, quality: quality, preferMP4: forceMP4)

        guard forceMP4 else {
            return DownloadedVideo(fileURL: downloaded, wasConverted: false)
        }

        let probe = try await MediaProbe.probe(downloaded)
        if probe.isQuickTimeFriendlyMP4 {
            return DownloadedVideo(fileURL: downloaded, wasConverted: false)
        }

        let converted = try await convertToMP4(downloaded, probe: probe)
        try? FileManager.default.removeItem(at: downloaded)
        return DownloadedVideo(fileURL: converted, wasConverted: true)
    }

    // MARK: - yt-dlp

    /// Builds the yt-dlp format selector. With `preferMP4` it tries streams
    /// that already fit in an MP4 without re-encoding before anything else.
    /// A height cap applies to every video alternative, with an uncapped
    /// "best" at the end so a site that only offers larger streams still works.
    static func formatSelector(maxHeight: Int?, preferMP4: Bool, resolutionFirst: Bool = false) -> String? {
        let cap = maxHeight.map { "[height<=\($0)]" } ?? ""
        guard preferMP4 || maxHeight != nil else { return nil }   // yt-dlp's default is already bv*+ba/b
        var alternatives: [String] = []
        if preferMP4, !resolutionFirst {
            alternatives += [
                "bv*[vcodec~='^(avc1|h264|hev1|hvc1)'][ext=mp4]\(cap)+ba[acodec~='^mp4a'][ext=m4a]",
                "bv*[ext=mp4]\(cap)+ba[ext=m4a]",
                "b[ext=mp4]\(cap)",
            ]
        }
        alternatives += ["bv*\(cap)+ba", "b\(cap)"]
        if maxHeight != nil { alternatives.append("b") }
        return alternatives.joined(separator: "/")
    }

    /// yt-dlp's format-sort fields for the resolution-first case (4K): the
    /// largest video up to the cap wins, and H.264 + AAC only break ties, so
    /// an MP4-ready stream is still taken when the site has one at that size.
    static func formatSort(maxHeight: Int, preferMP4: Bool) -> String {
        var fields = ["res:\(maxHeight)"]
        if preferMP4 { fields += ["vcodec:h264", "acodec:aac", "ext:mp4:m4a"] }
        return fields.joined(separator: ",")
    }

    private static func runYtdlp(_ ytdlp: YtdlpInstallation, url: URL, into directory: URL, quality: VideoQuality, preferMP4: Bool) async throws -> URL {
        // ffmpeg and deno always come from the bundle, whichever yt-dlp runs.
        var arguments = [
            "--no-playlist",
            "--no-progress",
            "--no-mtime",
            "--no-simulate",
            "--ffmpeg-location", BundledTools.helpersDirectory.path,
            "--js-runtimes", "deno:\(BundledTools.deno.path)",
            // Title only: each job has its own folder, so no ID is needed to
            // keep names unique, and the name flows into Shortcuts as-is.
            "--output", "%(title).180B.%(ext)s",
            "--paths", "home:\(directory.path)",
            "--paths", "temp:\(directory.path)",
            // Print the final path (after merge/move) as the only stdout line.
            "--print", "after_move:filepath",
        ]
        let resolutionFirst = quality.prefersResolutionOverCodec
        if let format = formatSelector(maxHeight: quality.maxHeight, preferMP4: preferMP4, resolutionFirst: resolutionFirst) {
            arguments += ["--format", format]
        }
        if resolutionFirst, let maxHeight = quality.maxHeight {
            arguments += ["--format-sort", formatSort(maxHeight: maxHeight, preferMP4: preferMP4)]
        }
        arguments.append(url.absoluteString)

        ytdlpLog.info("Downloading with \(ytdlp.source.label, privacy: .public) yt-dlp \(ytdlp.version ?? "?", privacy: .public)")
        let result = try await ToolProcess.run(ytdlp.url, arguments: arguments, currentDirectory: directory)
        guard result.succeeded else {
            throw DownloadError.downloadFailed(summarize(result.stderr))
        }

        // The last non-empty stdout line is the path we asked for.
        let path = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let path, FileManager.default.fileExists(atPath: path) else {
            // Fall back to whatever single file landed in the job folder.
            if let only = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter({ !$0.lastPathComponent.hasPrefix(".") }), only.count == 1 {
                return only[0]
            }
            throw DownloadError.noOutputFile
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: - ffmpeg

    private static func convertToMP4(_ source: URL, probe: MediaProbe) async throws -> URL {
        var destination = source.deletingPathExtension().appendingPathExtension("mp4")
        if destination == source {
            destination = source.deletingPathExtension().appendingPathExtension("h264.mp4")
        }

        let copyVideo = probe.videoCodec.map(MediaProbe.mp4VideoCodecs.contains) ?? false
        let copyAudio = probe.audioCodec.map(MediaProbe.mp4AudioCodecs.contains) ?? true

        func arguments(videoEncoder: [String]) -> [String] {
            var args = ["-hide_banner", "-nostdin", "-y", "-i", source.path, "-map", "0:v:0", "-map", "0:a:0?"]
            args += copyVideo ? ["-c:v", "copy"] : videoEncoder
            args += copyAudio ? ["-c:a", "copy"] : ["-c:a", "aac", "-b:a", "192k"]
            args += ["-movflags", "+faststart", destination.path]
            return args
        }

        // Hardware H.264 first (fast on Apple silicon), libx264 as the fallback.
        let hardware = ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"]
        let software = ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p"]

        var result = try await ToolProcess.run(BundledTools.ffmpeg, arguments: arguments(videoEncoder: hardware))
        if !result.succeeded, !copyVideo {
            try? FileManager.default.removeItem(at: destination)
            result = try await ToolProcess.run(BundledTools.ffmpeg, arguments: arguments(videoEncoder: software))
        }
        guard result.succeeded, FileManager.default.fileExists(atPath: destination.path) else {
            throw DownloadError.conversionFailed(summarize(result.stderr))
        }
        return destination
    }

    // MARK: - Housekeeping

    private static func sweepOldDownloads() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: downloadsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-retention)
        for entry in entries {
            let modified = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
    }

    /// Reduces tool stderr to the last meaningful line for an error message.
    private static func summarize(_ stderr: String) -> String {
        let lines = stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(error.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? "unknown error"
    }
}

/// A trimmed-down ffprobe result.
nonisolated struct MediaProbe: Sendable {
    let containerExtension: String
    let videoCodec: String?
    let audioCodec: String?

    static let mp4VideoCodecs: Set<String> = ["h264", "hevc"]
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "alac"]

    var isQuickTimeFriendlyMP4: Bool {
        guard containerExtension == "mp4" else { return false }
        guard let videoCodec, Self.mp4VideoCodecs.contains(videoCodec) else { return false }
        if let audioCodec, !Self.mp4AudioCodecs.contains(audioCodec) { return false }
        return true
    }

    static func probe(_ file: URL) async throws -> MediaProbe {
        let result = try await ToolProcess.run(BundledTools.ffprobe, arguments: [
            "-v", "error",
            "-print_format", "json",
            "-show_streams",
            file.path,
        ])
        guard result.succeeded, let data = result.stdout.data(using: .utf8) else {
            throw DownloadError.conversionFailed("ffprobe could not read the downloaded file")
        }

        struct Output: Decodable {
            struct Stream: Decodable {
                let codec_type: String?
                let codec_name: String?
            }
            let streams: [Stream]
        }
        let output = try JSONDecoder().decode(Output.self, from: data)
        return MediaProbe(
            containerExtension: file.pathExtension.lowercased(),
            videoCodec: output.streams.first { $0.codec_type == "video" }?.codec_name,
            audioCodec: output.streams.first { $0.codec_type == "audio" }?.codec_name
        )
    }
}
