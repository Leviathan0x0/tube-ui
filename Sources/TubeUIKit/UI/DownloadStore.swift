import AVFoundation
import Foundation
import Observation

/// Offline downloads. Fetches the split picture / audio files Innertube hands out,
/// merges them into a plain .mp4 (passthrough, no re-encode), and stores
/// `<id>.mp4` plus an `<id>.json` sidecar (title/channel/length for rescans)
/// under Application Support/TubeUI/Downloads. The Downloads tab lists `items`.
@MainActor
@Observable
final class DownloadStore {
    static let shared = DownloadStore()

    struct DownloadedVideo: Identifiable, Sendable {
        var id: String
        var title: String
        var channel: String
        var length: String?
        var fileURL: URL
        var size: Int64
    }

    struct StoredMeta: Codable, Sendable {
        var id: String
        var title: String
        var channel: String
        var length: String?
    }

    private enum DownloadError: Error {
        case noStreams
        case badResponse

        var message: String {
            switch self {
            case .noStreams: "No downloadable format for this video."
            case .badResponse: "The download server refused the request."
            }
        }
    }

    private(set) var items: [DownloadedVideo] = []
    private(set) var progress: [String: Double] = [:]
    private(set) var error: String?

    private init() {
        refresh()
    }

    func isDownloaded(_ id: String) -> Bool {
        items.contains { $0.id == id }
    }

    nonisolated static func downloadsDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("TubeUI/Downloads", isDirectory: true)
    }

    nonisolated static func fileURL(for id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id).mp4")
    }

    nonisolated static func metaURL(for id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    func refresh() {
        items = Self.merge(directory: Self.downloadsDirectory())
    }

    /// Scan a folder of `<id>.mp4` + optional `<id>.json` sidecars into items.
    nonisolated static func merge(directory: URL) -> [DownloadedVideo] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return [] }
        var found: [DownloadedVideo] = []
        for file in files {
            guard file.pathExtension == "mp4" else { continue }
            let id = file.deletingPathExtension().lastPathComponent
            guard YTVideo.isVideoID(id) else { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
            let meta = sidecar(for: id, in: directory)
            found.append(DownloadedVideo(
                id: id,
                title: (meta?.title.isEmpty == false) ? meta!.title : id,
                channel: meta?.channel ?? "",
                length: meta?.length,
                fileURL: file,
                size: size
            ))
        }
        return found.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private nonisolated static func sidecar(for id: String, in directory: URL) -> StoredMeta? {
        guard let data = try? Data(contentsOf: metaURL(for: id, in: directory)) else { return nil }
        return try? JSONDecoder().decode(StoredMeta.self, from: data)
    }

    func download(_ video: YTVideo) async {
        guard YTVideo.isVideoID(video.id), !isDownloaded(video.id), progress[video.id] == nil else { return }
        error = nil
        progress[video.id] = 0
        defer { progress[video.id] = nil }
        do {
            let directory = Self.downloadsDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = Self.fileURL(for: video.id, in: directory)
            try? FileManager.default.removeItem(at: destination)  // stale partial from a failed run
            let sources = await Innertube.playables(videoID: video.id, accessToken: TubeModel.shared.tokens?.accessToken)
            if let paired = sources.first(where: { $0.audioURL != nil }), let audioURL = paired.audioURL {
                try await downloadPaired(paired, audioURL: audioURL, to: destination, key: video.id)
            } else if let muxed = sources.first(where: { $0.audioURL == nil && $0.height != nil }) {
                try await fetch(muxed.url, userAgent: muxed.userAgent, to: destination, key: video.id, base: 0, weight: 1)
            } else {
                throw DownloadError.noStreams
            }
            let meta = StoredMeta(id: video.id, title: video.title, channel: video.channel, length: video.length)
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: Self.metaURL(for: video.id, in: directory))
            }
            refresh()
        } catch {
            self.error = (error as? DownloadError)?.message ?? error.localizedDescription
        }
    }

    /// Internal progress write for the delegate reporter.
    func reportProgress(_ id: String, _ value: Double) {
        progress[id] = value
    }

    func remove(_ item: DownloadedVideo) {
        try? FileManager.default.removeItem(at: item.fileURL)
        try? FileManager.default.removeItem(at: Self.metaURL(for: item.id, in: Self.downloadsDirectory()))
        refresh()
    }

    /// Download the split tracks, then mux them with a passthrough export.
    private func downloadPaired(
        _ paired: Innertube.PlayableMedia,
        audioURL: URL,
        to destination: URL,
        key: String
    ) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tube-dl-\(key)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let videoPart = folder.appendingPathComponent("video.mp4")
        let audioPart = folder.appendingPathComponent("audio.m4a")
        async let videoFetch: Void = fetch(paired.url, userAgent: paired.userAgent, to: videoPart, key: key, base: 0, weight: 0.45)
        async let audioFetch: Void = fetch(audioURL, userAgent: paired.userAgent, to: audioPart, key: key, base: 0.45, weight: 0.45)
        try await videoFetch
        try await audioFetch
        progress[key] = 0.9
        let composition = try await composition(video: paired.url, audio: audioURL, userAgent: paired.userAgent, duration: paired.duration)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError.badResponse
        }
        try await export.export(to: destination, as: .mp4)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw DownloadError.badResponse
        }
    }

    /// Same split-track composition the player uses, clamped to the authored length.
    private func composition(video: URL, audio: URL, userAgent: String, duration: TimeInterval?) async throws -> AVComposition {
        let options = [AVURLAssetHTTPUserAgentKey: userAgent]
        let videoAsset = AVURLAsset(url: video, options: options)
        let audioAsset = AVURLAsset(url: audio, options: options)
        async let videoTracks = videoAsset.loadTracks(withMediaType: .video)
        async let audioTracks = audioAsset.loadTracks(withMediaType: .audio)
        async let videoDuration = videoAsset.load(.duration)
        async let audioDuration = audioAsset.load(.duration)
        guard let picture = try await videoTracks.first, let sound = try await audioTracks.first else {
            throw DownloadError.noStreams
        }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw DownloadError.badResponse }
        let limits = [try await videoDuration, try await audioDuration].map(\.seconds).filter { $0.isFinite && $0 > 0 }
        var seconds = limits.min() ?? 0
        if let authored = duration, authored > 0 {
            seconds = seconds > 0 ? min(seconds, authored) : authored
        }
        guard seconds > 0 else { throw DownloadError.noStreams }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: seconds, preferredTimescale: 600))
        try videoTrack.insertTimeRange(range, of: picture, at: .zero)
        try audioTrack.insertTimeRange(range, of: sound, at: .zero)
        return composition
    }

    private func fetch(
        _ url: URL,
        userAgent: String,
        to destination: URL,
        key: String,
        base: Double,
        weight: Double
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let reporter = DownloadProgressReporter(key: key, base: base, weight: weight)
        let session = URLSession(configuration: .ephemeral, delegate: reporter, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (fileURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DownloadError.badResponse
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: fileURL, to: destination)
        DownloadStore.shared.reportProgress(key, base + weight)
    }
}

/// URLSessionDownloadDelegate → DownloadStore.progress. Owns no mutable state.
private final class DownloadProgressReporter: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let key: String
    private let base: Double
    private let weight: Double

    init(key: String, base: Double, weight: Double) {
        self.key = key
        self.base = base
        self.weight = weight
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { @MainActor [key, base, weight] in
            DownloadStore.shared.reportProgress(key, min(base + weight * fraction, base + weight))
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The async download(for:) API hands us the file directly.
    }
}

