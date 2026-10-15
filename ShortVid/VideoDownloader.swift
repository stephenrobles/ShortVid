import AppIntents
import Foundation
import VideoToolbox
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
    /// The video stream was re-encoded to H.264.
    let wasConverted: Bool
    /// The streams were moved into an MP4 (and/or the audio re-encoded) without touching the video.
    let wasRemuxed: Bool
}

/// Downloads a video with the bundled yt-dlp and, on request, makes sure the
/// result is an MP4. "Force MP4" keeps the downloaded video stream when this
/// Mac can play it from an MP4 (H.264, HEVC, and AV1 where the chip decodes
/// it), repackaging in seconds; anything else (VP9, or AV1 on older chips) is
/// re-encoded to H.264. The "Compatible MP4" option re-encodes AV1 too, so
/// the file also plays on older Macs and phones.
nonisolated enum VideoDownloader {
    /// Where finished files live. Each download gets its own folder so names
    /// never collide. Folders older than `retention` are swept on each run.
    static let downloadsDirectory: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let bundleID = Bundle.main.bundleIdentifier ?? "ShortVid"
        return caches.appending(path: bundleID).appending(path: "Downloads")
    }()

    static let retention: TimeInterval = 24 * 60 * 60

    static func download(_ url: URL, quality: VideoQuality = .highest, forceMP4: Bool, compatibleMP4: Bool = false) async throws -> DownloadedVideo {
        let compatible = forceMP4 && compatibleMP4
        let ytdlp = await YtdlpResolver.shared.status().active
        for tool in [ytdlp.url, BundledTools.ffmpeg, BundledTools.ffprobe, BundledTools.deno] where !BundledTools.isInstalled(tool) {
            throw DownloadError.toolMissing(tool.lastPathComponent)
        }

        sweepOldDownloads()

        let jobDirectory = downloadsDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)

        let downloaded = try await runYtdlp(ytdlp, url: url, into: jobDirectory, quality: quality, preferMP4: forceMP4, compatible: compatible)

        // Audio only: yt-dlp has already extracted the sound (to M4A with Force MP4).
        guard forceMP4, !quality.isAudioOnly else {
            return DownloadedVideo(fileURL: downloaded, wasConverted: false, wasRemuxed: false)
        }

        let allowedVideo = compatible ? MediaProbe.compatibleVideoCodecs : MediaProbe.playableMP4VideoCodecs
        let probe = try await MediaProbe.probe(downloaded)
        if probe.isMP4(allowingVideo: allowedVideo) {
            return DownloadedVideo(fileURL: downloaded, wasConverted: false, wasRemuxed: false)
        }

        let (output, reencoded) = try await makeMP4(downloaded, probe: probe, allowedVideo: allowedVideo)
        try? FileManager.default.removeItem(at: downloaded)
        return DownloadedVideo(fileURL: output, wasConverted: reencoded, wasRemuxed: !reencoded)
    }

    // MARK: - yt-dlp

    /// yt-dlp `vcodec` patterns for streams that go into an MP4 untouched:
    /// H.264 and HEVC always, AV1 too unless `compatible` or the chip can't decode it.
    static func remuxableCodecPattern(compatible: Bool) -> String {
        var codecs = ["avc1", "h264", "hev1", "hvc1"]
        if !compatible, MediaProbe.playableMP4VideoCodecs.contains("av1") { codecs.append("av01") }
        return "^(" + codecs.joined(separator: "|") + ")"
    }

    /// Builds the yt-dlp format selector. With `preferMP4` it tries streams
    /// that need no re-encoding before anything else: MP4-container video in
    /// a codec this Mac plays (see `remuxableCodecPattern`) with AAC audio,
    /// then any MP4 at all. A height cap applies to every video alternative,
    /// with an uncapped "best" at the end so a site that only offers larger
    /// streams still works.
    static func formatSelector(maxHeight: Int?, preferMP4: Bool, compatible: Bool = false, resolutionFirst: Bool = false) -> String? {
        let cap = maxHeight.map { "[height<=\($0)]" } ?? ""
        guard preferMP4 || maxHeight != nil else { return nil }   // yt-dlp's default is already bv*+ba/b
        var alternatives: [String] = []
        if preferMP4 {
            if resolutionFirst {
                // No codec filter here: resolution wins (see formatSort), and a
                // codec filter would let a smaller remuxable stream beat a larger one.
                alternatives.append("bv*\(cap)+ba[acodec~='^mp4a'][ext=m4a]")
            } else {
                let codec = "[vcodec~='\(remuxableCodecPattern(compatible: compatible))']"
                alternatives += [
                    "bv*\(codec)[ext=mp4]\(cap)+ba[acodec~='^mp4a'][ext=m4a]",
                    "bv*[ext=mp4]\(cap)+ba[acodec~='^mp4a'][ext=m4a]",
                    "bv*[ext=mp4]\(cap)+ba[ext=m4a]",
                    "b[ext=mp4]\(cap)",
                ]
            }
        }
        alternatives += ["bv*\(cap)+ba", "b\(cap)"]
        if maxHeight != nil { alternatives.append("b") }
        return alternatives.joined(separator: "/")
    }

    /// yt-dlp's format-sort fields for the resolution-first case (4K): the
    /// largest video up to the cap wins; a codec that needs no re-encoding
    /// (H.264 with `compatible`, AV1 on a Mac that plays it) breaks ties, and
    /// AAC audio and an MP4 container come next.
    static func formatSort(maxHeight: Int, preferMP4: Bool, compatible: Bool = false) -> String {
        var fields = ["res:\(maxHeight)"]
        if preferMP4 {
            if compatible {
                fields.append("vcodec:h264")
            } else if MediaProbe.playableMP4VideoCodecs.contains("av1") {
                fields.append("vcodec:av01")
            }
            fields += ["acodec:aac", "ext:mp4:m4a"]
        }
        return fields.joined(separator: ",")
    }

    private static func runYtdlp(_ ytdlp: YtdlpInstallation, url: URL, into directory: URL, quality: VideoQuality, preferMP4: Bool, compatible: Bool) async throws -> URL {
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
        if quality.isAudioOnly {
            // Best audio stream (AAC first when an M4A is wanted), or the sound of a
            // muxed file when that is all the site has; -x makes ffmpeg drop the video.
            // "best" keeps the native codec; "m4a" copies AAC and transcodes anything else.
            arguments += ["--format", preferMP4 ? "ba[acodec~='^mp4a']/ba/b" : "ba/b"]
            arguments += ["--extract-audio", "--audio-format", preferMP4 ? "m4a" : "best", "--audio-quality", "0"]
        } else {
            let resolutionFirst = quality.prefersResolutionOverCodec
            if let format = formatSelector(maxHeight: quality.maxHeight, preferMP4: preferMP4, compatible: compatible, resolutionFirst: resolutionFirst) {
                arguments += ["--format", format]
            }
            if resolutionFirst, let maxHeight = quality.maxHeight {
                arguments += ["--format-sort", formatSort(maxHeight: maxHeight, preferMP4: preferMP4, compatible: compatible)]
            }
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

    /// Produces an MP4 from `source`: the video stream is copied when its codec
    /// is in `allowedVideo` and re-encoded to H.264 otherwise; audio is copied
    /// when MP4 can hold it and re-encoded to AAC otherwise. Returns the file
    /// and whether the video was re-encoded.
    private static func makeMP4(_ source: URL, probe: MediaProbe, allowedVideo: Set<String>) async throws -> (URL, Bool) {
        var destination = source.deletingPathExtension().appendingPathExtension("mp4")
        if destination == source {
            destination = source.deletingPathExtension().appendingPathExtension("h264.mp4")
        }

        let copyVideo = probe.videoCodec.map(allowedVideo.contains) ?? false
        let copyAudio = probe.audioCodec.map(MediaProbe.mp4AudioCodecs.contains) ?? true

        // Decode in hardware when VideoToolbox handles the source codec (AV1 on
        // M3 and later, HEVC and H.264 everywhere); otherwise ffmpeg decodes in
        // software, which is what VP9 gets.
        let hardwareDecode = !copyVideo && (probe.videoCodec.map(MediaProbe.hardwareDecodes) ?? false)

        func arguments(videoEncoder: [String]) -> [String] {
            var args = ["-hide_banner", "-nostdin", "-y"]
            if hardwareDecode { args += ["-hwaccel", "videotoolbox"] }
            args += ["-i", source.path, "-map", "0:v:0", "-map", "0:a:0?"]
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
        return (destination, !copyVideo)
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

    /// Video codecs that play everywhere, older devices included.
    static let compatibleVideoCodecs: Set<String> = ["h264", "hevc"]
    /// Video codecs this Mac plays from an MP4: the compatible ones plus AV1
    /// when the chip decodes it (M3 and later). VP9 in MP4 is not playable
    /// by AVFoundation even on Apple silicon, so it is always re-encoded.
    static var playableMP4VideoCodecs: Set<String> {
        var codecs = compatibleVideoCodecs
        if hardwareDecodes("av1") { codecs.insert("av1") }
        return codecs
    }
    static let mp4AudioCodecs: Set<String> = ["aac", "mp3", "alac"]

    /// Whether VideoToolbox decodes the (ffprobe-named) codec in hardware.
    static func hardwareDecodes(_ codec: String) -> Bool {
        let type: CMVideoCodecType
        switch codec {
        case "h264": type = kCMVideoCodecType_H264
        case "hevc": type = kCMVideoCodecType_HEVC
        case "vp9": type = kCMVideoCodecType_VP9
        case "av1": type = kCMVideoCodecType_AV1
        default: return false
        }
        return VTIsHardwareDecodeSupported(type)
    }

    /// Whether the file is already an MP4 whose streams need no work.
    func isMP4(allowingVideo allowedVideo: Set<String>) -> Bool {
        guard containerExtension == "mp4" else { return false }
        guard let videoCodec, allowedVideo.contains(videoCodec) else { return false }
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
