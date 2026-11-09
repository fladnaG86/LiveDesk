import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

public enum Thumbnails {
    /// Grabs a frame from a video (around 1 s in) and writes it as PNG.
    public static func writeVideoFrame(from video: URL, to output: URL, maxSize: CGSize = CGSize(width: 1280, height: 1280)) async throws {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maxSize
        let duration = try await asset.load(.duration)
        let at = CMTime(seconds: min(1, duration.seconds / 2), preferredTimescale: 600)
        let (image, _) = try await generator.image(at: at)
        try writePNG(image, to: output)
    }

    public static func writePNG(_ image: CGImage, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Thumbnail PNGs for library items, cached in `<root>/Thumbs/<id>.png`.
@MainActor
public final class ThumbnailCache {
    public let folder: URL
    private var inFlight: Set<UUID> = []
    /// Decoded images, so SwiftUI re-renders do not hit the disk.
    private var memory: [UUID: NSImage] = [:]

    public init(root: URL) {
        folder = root.appendingPathComponent("Thumbs", isDirectory: true)
    }

    public func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).png") }

    public func cachedImage(for id: UUID) -> NSImage? {
        if let image = memory[id] { return image }
        guard let image = NSImage(contentsOf: url(for: id)) else { return nil }
        memory[id] = image
        return image
    }

    /// Generates the thumbnail when missing. Returns true when a new file was written.
    public func ensure(for wallpaper: Wallpaper, source: URL) async -> Bool {
        let out = url(for: wallpaper.id)
        guard !FileManager.default.fileExists(atPath: out.path), !inFlight.contains(wallpaper.id) else { return false }
        inFlight.insert(wallpaper.id)
        defer { inFlight.remove(wallpaper.id) }
        switch wallpaper.kind {
        case .video:
            return (try? await Thumbnails.writeVideoFrame(from: source, to: out, maxSize: CGSize(width: 640, height: 640))) != nil
        case .image:
            guard let src = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 640,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return false }
            return (try? Thumbnails.writePNG(image, to: out)) != nil
        case .scene:
            // Metal render off the main thread; 16:9 like the card.
            let ok = await Task.detached(priority: .utility) {
                guard let image = try? OfflineSceneRenderer.renderStill(folder: source, width: 640, height: 360) else { return false }
                return (try? Thumbnails.writePNG(image, to: out)) != nil
            }.value
            return ok
        }
    }

    public func remove(id: UUID) {
        memory[id] = nil
        try? FileManager.default.removeItem(at: url(for: id))
    }
}
