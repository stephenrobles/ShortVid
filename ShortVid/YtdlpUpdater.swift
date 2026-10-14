import Foundation
import os

nonisolated let ytdlpLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ShortVid", category: "yt-dlp")

// MARK: - Which yt-dlp runs

/// The yt-dlp executable the app will run: either the copy the build put in
/// `Contents/Helpers`, or a newer one fetched by "Update yt-dlp…".
nonisolated struct YtdlpInstallation: Sendable, Equatable {
    enum Source: Sendable, Equatable {
        case bundled
        case updated

        var label: String {
            switch self {
            case .bundled: return "bundled"
            case .updated: return "updated"
            }
        }
    }

    let url: URL
    let version: String?
    let source: Source
}

nonisolated struct YtdlpStatus: Sendable, Equatable {
    let bundledVersion: String?
    let updatedVersion: String?
    let active: YtdlpInstallation
}

/// yt-dlp versions are dates ("2026.08.19"), occasionally with a fourth
/// component on pre-release builds. Compare them component by component.
nonisolated enum YtdlpVersion {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = components(lhs), r = components(rhs)
        for index in 0..<max(l.count, r.count) {
            let a = index < l.count ? l[index] : 0
            let b = index < r.count ? r[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isNewer(_ version: String, than other: String) -> Bool {
        compare(version, other) == .orderedDescending
    }

    /// "2026.08.19" yes; "Traceback (most recent call last)" no.
    static func looksValid(_ version: String) -> Bool {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        return parts.count >= 3 && parts.allSatisfy { Int($0) != nil }
    }

    private static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".").map { Int($0) ?? 0 }
    }
}

/// Decides between the bundled yt-dlp and the updated copy in Application
/// Support, preferring the updated one only when its version is newer.
///
/// `yt-dlp --version` takes a couple of seconds (PyInstaller unpacks itself
/// on every launch), so the answer is cached and keyed on the two files'
/// size and modification date; an update invalidates it.
actor YtdlpResolver {
    static let shared = YtdlpResolver()

    private var cached: (key: [String], status: YtdlpStatus)?

    func status() async -> YtdlpStatus {
        let key = [fingerprint(BundledTools.bundledYtdlp), fingerprint(BundledTools.updatedYtdlp)]
        if let cached, cached.key == key { return cached.status }

        async let bundled = BundledTools.version(of: BundledTools.bundledYtdlp)
        async let updated = BundledTools.version(of: BundledTools.updatedYtdlp)
        let bundledVersion = await bundled
        let updatedVersion = await updated

        var active = YtdlpInstallation(url: BundledTools.bundledYtdlp, version: bundledVersion, source: .bundled)
        if let updatedVersion, bundledVersion.map({ YtdlpVersion.isNewer(updatedVersion, than: $0) }) ?? true {
            active = YtdlpInstallation(url: BundledTools.updatedYtdlp, version: updatedVersion, source: .updated)
        }

        let status = YtdlpStatus(bundledVersion: bundledVersion, updatedVersion: updatedVersion, active: active)
        cached = (key, status)
        ytdlpLog.info("Resolved \(active.source.label, privacy: .public) yt-dlp \(active.version ?? "?", privacy: .public) at \(active.url.path, privacy: .public) (bundled \(bundledVersion ?? "missing", privacy: .public), updated \(updatedVersion ?? "none", privacy: .public))")
        return status
    }

    func invalidate() {
        cached = nil
    }

    private func fingerprint(_ url: URL) -> String {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return "missing" }
        let size = attributes[.size] as? Int ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(size)@\(modified)"
    }
}

// MARK: - Fetching a new one

nonisolated enum YtdlpUpdateError: LocalizedError {
    case badResponse(Int)
    case wontRun(String)
    case unexpectedOutput(String)

    var errorDescription: String? {
        switch self {
        case .badResponse(let code):
            return "GitHub answered with HTTP \(code)."
        case .wontRun(let reason):
            return "The downloaded yt-dlp would not run: \(reason)"
        case .unexpectedOutput(let output):
            return "The downloaded yt-dlp did not report a version (got “\(output)”)."
        }
    }
}

nonisolated enum YtdlpUpdateOutcome: Sendable, Equatable {
    /// A newer copy is installed and will be used from now on.
    case updated(String)
    /// The latest release is the version already in use.
    case alreadyCurrent(String)
}

nonisolated enum YtdlpUpdatePhase: Sendable, Equatable {
    case downloading(Double)
    case verifying
    case installing
}

/// Downloads the latest official yt-dlp macOS build into Application Support,
/// checks that it runs, and swaps it into place atomically.
nonisolated enum YtdlpUpdateEngine {
    static let downloadURL = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    static func update(progress: @escaping @Sendable (YtdlpUpdatePhase) -> Void) async throws -> YtdlpUpdateOutcome {
        let fm = FileManager.default
        let supportDirectory = BundledTools.supportDirectory
        let destination = BundledTools.updatedYtdlp
        let previous = supportDirectory.appending(path: "yt-dlp.previous")

        let before = await YtdlpResolver.shared.status()

        // Download into a scratch folder next to the final location so the
        // final move is a rename on the same volume.
        try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        let staging = supportDirectory.appending(path: "staging-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let staged = staging.appending(path: "yt-dlp")

        progress(.downloading(0))
        try await download(to: staged) { progress(.downloading($0)) }
        try Task.checkCancellation()

        // Make it runnable: executable bit, no quarantine flag.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.path)
        removeQuarantine(staged)

        // Prove it launches from this process before touching anything.
        progress(.verifying)
        let version = try await verifiedVersion(of: staged)
        try Task.checkCancellation()

        // The bundled copy is signed with the app's own identity; keep using
        // it unless the download is actually newer.
        if let bundledVersion = before.bundledVersion, !YtdlpVersion.isNewer(version, than: bundledVersion) {
            try? fm.removeItem(at: destination)
            try? fm.removeItem(at: previous)
            await YtdlpResolver.shared.invalidate()
            ytdlpLog.info("Downloaded yt-dlp \(version, privacy: .public) is not newer than bundled \(bundledVersion, privacy: .public); keeping the bundled copy")
            return .alreadyCurrent(version)
        }

        // Swap it in, keeping whatever was there as yt-dlp.previous.
        progress(.installing)
        let hadPrevious = fm.fileExists(atPath: destination.path)
        if hadPrevious {
            try? fm.removeItem(at: previous)
            _ = try fm.replaceItemAt(destination, withItemAt: staged,
                                     backupItemName: previous.lastPathComponent,
                                     options: .withoutDeletingBackupItem)
        } else {
            try fm.moveItem(at: staged, to: destination)
        }
        await YtdlpResolver.shared.invalidate()

        // Confirm the installed copy runs; otherwise put the old one back.
        do {
            let installed = try await verifiedVersion(of: destination)
            guard installed == version else {
                throw YtdlpUpdateError.unexpectedOutput(installed)
            }
        } catch {
            ytdlpLog.error("Installed yt-dlp failed verification, reverting: \(error.localizedDescription, privacy: .public)")
            try? fm.removeItem(at: destination)
            if hadPrevious { try? fm.moveItem(at: previous, to: destination) }
            await YtdlpResolver.shared.invalidate()
            throw error
        }

        ytdlpLog.info("Installed yt-dlp \(version, privacy: .public) at \(destination.path, privacy: .public)")
        if before.active.version == version {
            return .alreadyCurrent(version)
        }
        return .updated(version)
    }

    // MARK: Steps

    private static func download(to destination: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let delegate = DownloadProgressDelegate(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw YtdlpUpdateError.badResponse((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    private static func removeQuarantine(_ file: URL) {
        // ENOATTR when there is none; URLSession downloads in an unsandboxed
        // app usually carry no quarantine flag, but don't depend on it.
        _ = file.withUnsafeFileSystemRepresentation { path in
            path.map { removexattr($0, "com.apple.quarantine", 0) }
        }
    }

    /// Runs `yt-dlp --version` and returns the version it prints.
    private static func verifiedVersion(of executable: URL) async throws -> String {
        let result: ToolProcessResult
        do {
            result = try await ToolProcess.run(executable, arguments: ["--version"])
        } catch {
            throw YtdlpUpdateError.wontRun(error.localizedDescription)
        }
        guard result.succeeded else {
            let detail = result.stderr
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "exit status \(result.status)"
            throw YtdlpUpdateError.wontRun(detail)
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard YtdlpVersion.looksValid(version) else {
            throw YtdlpUpdateError.unexpectedOutput(String(version.prefix(80)))
        }
        return version
    }
}

/// Forwards URLSession's byte counts as a 0…1 fraction.
private nonisolated final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The async `download(for:)` API hands the file back to its caller.
    }
}

// MARK: - UI state

/// Drives the "Update yt-dlp…" button and menu item.
@Observable
final class YtdlpUpdater {
    enum State: Equatable {
        case idle
        case running(YtdlpUpdatePhase)
        case finished(YtdlpUpdateOutcome)
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var status: YtdlpStatus?
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    func refreshStatus() async {
        status = await YtdlpResolver.shared.status()
    }

    func start() {
        guard !isRunning else { return }
        state = .running(.downloading(0))
        task = Task {
            do {
                let outcome = try await YtdlpUpdateEngine.update { phase in
                    Task { @MainActor in self.note(phase) }
                }
                state = .finished(outcome)
            } catch is CancellationError {
                state = .idle
            } catch let error as URLError where error.code == .cancelled {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
            await refreshStatus()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
    }

    private func note(_ phase: YtdlpUpdatePhase) {
        guard isRunning else { return }
        state = .running(phase)
    }
}
