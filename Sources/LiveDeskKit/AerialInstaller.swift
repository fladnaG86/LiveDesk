import AVFoundation
import Foundation
import os

/// Puts LiveDesk videos into the system Aerial catalog so macOS can show them on the Lock Screen
/// and in System Settings > Wallpaper. Works on the per-user store used by modern macOS
/// (`~/Library/Application Support/com.apple.wallpaper/aerials`), so no root helper is needed.
@MainActor
public final class AerialInstaller {
    public struct Source: Sendable {
        public var id: UUID
        public var title: String
        public var file: URL

        public init(id: UUID, title: String, file: URL) {
            self.id = id
            self.title = title
            self.file = file
        }
    }

    public enum Status: Equatable {
        case idle
        case working(String)
        case done(Int)
        case failed(String)
    }

    public let aerialsRoot: URL
    public let backupFolder: URL
    public private(set) var status: Status = .idle
    public var onStatusChange: ((Status) -> Void)?
    /// Restarting WallpaperAgent makes the system reread the catalog. Disabled in tests.
    public var restartsWallpaperAgent = true

    private let fm = FileManager.default
    private let log = Logger(subsystem: "dev.livedesk", category: "aerial")
    private var repairAttempts = 0

    public nonisolated static var defaultAerialsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    public init(aerialsRoot: URL = AerialInstaller.defaultAerialsRoot, backupFolder: URL) {
        self.aerialsRoot = aerialsRoot
        self.backupFolder = backupFolder
    }

    public var manifestURL: URL { aerialsRoot.appendingPathComponent("manifest/entries.json") }
    public var videosFolder: URL { aerialsRoot.appendingPathComponent("videos", isDirectory: true) }
    public var thumbnailsFolder: URL { aerialsRoot.appendingPathComponent("thumbnails", isDirectory: true) }

    public var isAvailable: Bool { fm.fileExists(atPath: manifestURL.path) }

    public func videoURL(for id: UUID) -> URL { videosFolder.appendingPathComponent("\(id.uuidString).mov") }
    public func thumbnailURL(for id: UUID) -> URL { thumbnailsFolder.appendingPathComponent("\(id.uuidString).png") }

    private func setStatus(_ s: Status) {
        status = s
        onStatusChange?(s)
    }

    /// Makes the LiveDesk aerial category contain exactly `sources`.
    /// - Parameter previouslyInstalled: ids installed by an earlier sync, whose files get removed if no longer wanted.
    /// - Returns: ids now installed.
    @discardableResult
    public func sync(_ sources: [Source], previouslyInstalled: [UUID]) async throws -> [UUID] {
        guard isAvailable else {
            let message = "Catalogo Aerial di sistema non trovato. Apri Impostazioni > Sfondo una volta e riprova."
            setStatus(.failed(message))
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: message])
        }
        do {
            try fm.createDirectory(at: videosFolder, withIntermediateDirectories: true)
            try fm.createDirectory(at: thumbnailsFolder, withIntermediateDirectories: true)

            var items: [AerialItem] = []
            for (index, source) in sources.enumerated() {
                setStatus(.working("Preparo \(source.title) (\(index + 1)/\(sources.count))"))
                let video = videoURL(for: source.id)
                if !fm.fileExists(atPath: video.path) {
                    try await Self.transcode(source.file, to: video)
                }
                let thumb = thumbnailURL(for: source.id)
                if !fm.fileExists(atPath: thumb.path) {
                    try await Thumbnails.writeVideoFrame(from: video, to: thumb)
                }
                items.append(AerialItem(id: source.id, title: source.title, videoURL: video, thumbnailURL: thumb))
            }

            let wanted = Set(sources.map(\.id))
            for stale in previouslyInstalled where !wanted.contains(stale) {
                try? fm.removeItem(at: videoURL(for: stale))
                try? fm.removeItem(at: thumbnailURL(for: stale))
            }

            setStatus(.working("Aggiorno il catalogo di sistema"))
            try writeManifest(items: items)
            restartAgent()
            setStatus(.done(items.count))
            repairAttempts = 0
            return items.map(\.id)
        } catch {
            setStatus(.failed(error.localizedDescription))
            throw error
        }
    }

    /// Removes everything LiveDesk added.
    public func uninstall(previouslyInstalled: [UUID]) throws {
        guard isAvailable else { return }
        try writeManifest(items: [])
        for id in previouslyInstalled {
            try? fm.removeItem(at: videoURL(for: id))
            try? fm.removeItem(at: thumbnailURL(for: id))
        }
        restartAgent()
        setStatus(.idle)
    }

    /// True when Apple rewrote the catalog and our category disappeared.
    public func needsRepair(expected: [UUID]) -> Bool {
        guard !expected.isEmpty, let data = try? Data(contentsOf: manifestURL) else { return false }
        let present = Set(AerialManifestEditor.ourAssetIDs(data))
        return !AerialManifestEditor.containsCategory(data) || present != Set(expected.map(\.uuidString))
    }

    /// Re-applies the category at most twice per launch, like a careful repair loop.
    public func repairIfNeeded(_ sources: [Source], installed: [UUID]) async -> [UUID]? {
        guard needsRepair(expected: installed), repairAttempts < 2 else { return nil }
        repairAttempts += 1
        log.info("aerial category missing; repair attempt \(self.repairAttempts)")
        return try? await sync(sources, previouslyInstalled: installed)
    }

    // MARK: Internals

    private func writeManifest(items: [AerialItem]) throws {
        let data = try Data(contentsOf: manifestURL)
        try backup(data)
        let updated = try AerialManifestEditor.apply(items: items, to: data)
        try updated.write(to: manifestURL, options: .atomic)
    }

    private func backup(_ data: Data) throws {
        try fm.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let original = backupFolder.appendingPathComponent("entries-original.json")
        if !fm.fileExists(atPath: original.path), !AerialManifestEditor.containsCategory(data) {
            try data.write(to: original)
        }
        try data.write(to: backupFolder.appendingPathComponent("entries-last.json"), options: .atomic)
    }

    private func restartAgent() {
        guard restartsWallpaperAgent else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["WallpaperAgent"]
        try? task.run()
        task.waitUntilExit()
        log.info("WallpaperAgent restarted (status \(task.terminationStatus))")
    }

    /// HEVC QuickTime copy, the format the system aerial player expects.
    static func transcode(_ input: URL, to output: URL) async throws {
        let temp = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temp) }
        let asset = AVURLAsset(url: input)
        let preset = AVAssetExportPresetHEVCHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw CocoaError(.featureUnsupported, userInfo: [NSLocalizedDescriptionKey: "Impossibile convertire il video"])
        }
        session.shouldOptimizeForNetworkUse = false
        try await session.export(to: temp, as: .mov)
        if FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.removeItem(at: output)
        }
        try FileManager.default.moveItem(at: temp, to: output)
    }
}
