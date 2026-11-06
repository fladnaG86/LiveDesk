import Foundation
import Observation

/// Downloads catalog videos with progress, a size cap and cancellation.
@MainActor
@Observable
public final class DownloadManager {
    public enum State: Equatable {
        case downloading(Double)
        case failed(String)
    }

    public static let maxBytes: Int64 = 3 * 1024 * 1024 * 1024

    public private(set) var states: [String: State] = [:]
    @ObservationIgnored private var tasks: [String: Task<URL, Error>] = [:]
    @ObservationIgnored private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func isDownloading(_ id: String) -> Bool {
        if case .downloading = states[id] { return true }
        return false
    }

    /// Downloads into `folder` and returns the local file (named after the item title).
    public func download(_ item: CatalogItem, to folder: URL) async throws -> URL {
        if let existing = tasks[item.id] { return try await existing.value }
        states[item.id] = .downloading(0)
        let session = self.session
        let id = item.id
        let task = Task<URL, Error> {
            let delegate = ProgressDelegate(maxBytes: Self.maxBytes) { fraction in
                Task { @MainActor [weak self] in
                    if case .downloading = self?.states[id] { self?.states[id] = .downloading(fraction) }
                }
            }
            let (temp, response) = try await session.download(from: item.downloadURL, delegate: delegate)
            defer { try? FileManager.default.removeItem(at: temp) }
            if delegate.exceededLimit { throw DownloadError.tooLarge }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let ext = Self.fileExtension(mime: http.mimeType, url: item.downloadURL)
            guard ext != nil else { throw DownloadError.notAVideo(http.mimeType ?? "?") }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("\(Self.safeFileName(item.title)).\(ext!)")
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        }
        tasks[item.id] = task
        do {
            let url = try await task.value
            tasks[item.id] = nil
            states[item.id] = nil
            return url
        } catch {
            tasks[item.id] = nil
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                states[item.id] = nil
            } else {
                states[item.id] = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    public func cancel(_ id: String) {
        tasks[id]?.cancel()
    }

    public func clearFailure(_ id: String) {
        if case .failed = states[id] { states[id] = nil }
    }

    // MARK: Helpers

    nonisolated static func fileExtension(mime: String?, url: URL) -> String? {
        switch mime?.lowercased() {
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        default:
            let ext = url.pathExtension.lowercased()
            return ["mp4", "mov", "m4v"].contains(ext) ? ext : nil
        }
    }

    nonisolated static func safeFileName(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_,"))
        let cleaned = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" })
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "wallpaper" : String(cleaned.prefix(80))
    }
}

public enum DownloadError: Error, LocalizedError, Equatable {
    case tooLarge
    case notAVideo(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "File troppo grande (oltre 3 GB)."
        case .notAVideo(let mime): return "Il file scaricato non è un video (\(mime))."
        }
    }
}

private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let maxBytes: Int64
    let onProgress: @Sendable (Double) -> Void
    private(set) var exceededLimit = false
    private var lastReported: Double = -1

    init(maxBytes: Int64, onProgress: @escaping @Sendable (Double) -> Void) {
        self.maxBytes = maxBytes
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            exceededLimit = true
            downloadTask.cancel()
            return
        }
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        if fraction - lastReported >= 0.01 || fraction >= 1 {
            lastReported = fraction
            onProgress(fraction)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
