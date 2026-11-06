import CryptoKit
import Foundation

/// Downloads small preview clips to disk before playing them. AVPlayer refuses remote files served as
/// `application/octet-stream` (e.g. GitHub release assets); a local file with the right extension always plays.
public actor PreviewCache {
    public static let shared = PreviewCache()
    public static let maxBytes: Int64 = 50 * 1024 * 1024

    public let folder: URL
    private let session: URLSession
    private var inFlight: [URL: Task<URL, Error>] = [:]

    public init(folder: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("LiveDesk/Previews", isDirectory: true),
                session: URLSession = .shared) {
        self.folder = folder
        self.session = session
    }

    public nonisolated func cachedFileURL(for remote: URL) -> URL {
        let digest = SHA256.hash(data: Data(remote.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = ["mp4", "mov", "m4v"].contains(remote.pathExtension.lowercased()) ? remote.pathExtension.lowercased() : "mp4"
        return folder.appendingPathComponent("\(digest.prefix(32)).\(ext)")
    }

    public func localFile(for remote: URL) async throws -> URL {
        let dest = cachedFileURL(for: remote)
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        if let task = inFlight[remote] { return try await task.value }
        let session = self.session
        let folder = self.folder
        let task = Task<URL, Error> {
            let (temp, response) = try await session.download(from: remote)
            defer { try? FileManager.default.removeItem(at: temp) }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw CatalogError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            let size = (try? FileManager.default.attributesOfItem(atPath: temp.path)[.size] as? Int64) ?? 0
            guard size <= Self.maxBytes else { throw DownloadError.tooLarge }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: temp, to: dest)
            return dest
        }
        inFlight[remote] = task
        defer { inFlight[remote] = nil }
        return try await task.value
    }
}
