import Foundation

/// Locates the yt-dlp, ffmpeg and ffprobe executables that the build copies
/// into `ShortVid.app/Contents/Helpers` (see `Scripts/bundle-tools.sh`).
nonisolated enum BundledTools {
    static let helpersDirectory = Bundle.main.bundleURL.appending(path: "Contents/Helpers")

    /// The yt-dlp frozen into the bundle at build time. Ask `YtdlpResolver`
    /// for the one to actually run: "Update yt-dlp…" may have installed a
    /// newer copy at `updatedYtdlp`.
    static let bundledYtdlp = helpersDirectory.appending(path: "yt-dlp")
    static let ffmpeg = helpersDirectory.appending(path: "ffmpeg")
    static let ffprobe = helpersDirectory.appending(path: "ffprobe")
    /// JavaScript runtime yt-dlp needs to solve YouTube's player challenges.
    static let deno = helpersDirectory.appending(path: "deno")

    /// `~/Library/Application Support/fm.beard.ShortVid`, where "Update yt-dlp…"
    /// keeps the copy it downloads (plus `yt-dlp.previous` as a fallback).
    static let supportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appending(path: Bundle.main.bundleIdentifier ?? "ShortVid")
    }()

    static let updatedYtdlp = supportDirectory.appending(path: "yt-dlp")

    static func isInstalled(_ tool: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: tool.path)
    }

    /// Short version string for display, e.g. "2026.08.19" or "9.0.2".
    static func version(of tool: URL) async -> String? {
        guard isInstalled(tool) else { return nil }
        let name = tool.lastPathComponent
        let flag = name.hasPrefix("ff") ? "-version" : "--version"
        let result = try? await ToolProcess.run(tool, arguments: [flag])
        guard let firstLine = result?.stdout.split(whereSeparator: \.isNewline).first else { return nil }
        let words = firstLine.split(separator: " ")
        switch name {
        case "yt-dlp":
            return firstLine.trimmingCharacters(in: .whitespaces)   // "2026.08.19"
        case "deno":
            return words.count >= 2 ? String(words[1]) : String(firstLine)   // "deno 2.9.7 (…)" → "2.9.7"
        default:
            // "ffmpeg version 9.0.2-https://… Copyright …" → "9.0.2"
            guard words.count >= 3 else { return String(firstLine) }
            return String(words[2].split(separator: "-").first ?? words[2])
        }
    }
}

nonisolated struct ToolProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { status == 0 }
}

/// Runs a bundled command-line tool and collects its output.
nonisolated enum ToolProcess {
    static func run(
        _ executable: URL,
        arguments: [String],
        currentDirectory: URL? = nil
    ) async throws -> ToolProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = currentDirectory
        }

        // Keep the environment minimal and predictable. PyInstaller (yt-dlp)
        // needs a writable TMPDIR to unpack itself; HOME is used for caches.
        var environment: [String: String] = [:]
        environment["HOME"] = NSHomeDirectory()
        environment["TMPDIR"] = NSTemporaryDirectory()
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["LANG"] = "en_US.UTF-8"
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        // Drain both pipes on background threads so a chatty child can never
        // fill a pipe buffer and deadlock.
        async let stdoutData = readToEnd(stdoutPipe.fileHandleForReading)
        async let stderrData = readToEnd(stderrPipe.fileHandleForReading)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let out = await stdoutData
        let err = await stderrData
        return ToolProcessResult(
            status: process.terminationStatus,
            stdout: String(decoding: out, as: UTF8.self),
            stderr: String(decoding: err, as: UTF8.self)
        )
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                try? handle.close()
                continuation.resume(returning: data)
            }
        }
    }
}
