import Foundation

public enum WallpaperKind: String, Codable, Sendable, CaseIterable {
    case video
    case scene
    case image
}

public struct Wallpaper: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var kind: WallpaperKind
    /// File or folder name inside the library media folder, or inside the built-in scenes folder.
    public var relativePath: String
    public var isBuiltIn: Bool
    /// Only meaningful for videos: copy this wallpaper into the system Aerial catalog (Lock Screen).
    public var onLockScreen: Bool
    public var addedAt: Date
    /// Author / source / license for downloaded items.
    public var credit: String?
    public var sourcePage: String?
    /// CatalogItem.id this wallpaper was downloaded from.
    public var catalogID: String?

    public init(
        id: UUID = UUID(),
        title: String,
        kind: WallpaperKind,
        relativePath: String,
        isBuiltIn: Bool = false,
        onLockScreen: Bool = false,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.relativePath = relativePath
        self.isBuiltIn = isBuiltIn
        self.onLockScreen = onLockScreen
        self.addedAt = addedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decode(WallpaperKind.self, forKey: .kind)
        relativePath = try c.decode(String.self, forKey: .relativePath)
        isBuiltIn = try c.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        onLockScreen = try c.decodeIfPresent(Bool.self, forKey: .onLockScreen) ?? false
        addedAt = try c.decodeIfPresent(Date.self, forKey: .addedAt) ?? Date()
        credit = try c.decodeIfPresent(String.self, forKey: .credit)
        sourcePage = try c.decodeIfPresent(String.self, forKey: .sourcePage)
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID)
    }
}

public struct PlaybackSettings: Codable, Equatable, Sendable {
    public var pauseOnBattery: Bool = true
    public var pauseInLowPowerMode: Bool = true
    public var pauseWhenCovered: Bool = true
    public var speed: Double = 1.0
    /// Render scale for scenes, 0.25...1.0.
    public var sceneQuality: Double = 1.0
    public var sceneFPS: Int = 60
    public var audioReactive: Bool = true
    /// 0 disables rotation.
    public var rotationMinutes: Int = 0
    public var lockScreenSync: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlaybackSettings()
        pauseOnBattery = try c.decodeIfPresent(Bool.self, forKey: .pauseOnBattery) ?? d.pauseOnBattery
        pauseInLowPowerMode = try c.decodeIfPresent(Bool.self, forKey: .pauseInLowPowerMode) ?? d.pauseInLowPowerMode
        pauseWhenCovered = try c.decodeIfPresent(Bool.self, forKey: .pauseWhenCovered) ?? d.pauseWhenCovered
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? d.speed
        sceneQuality = try c.decodeIfPresent(Double.self, forKey: .sceneQuality) ?? d.sceneQuality
        sceneFPS = try c.decodeIfPresent(Int.self, forKey: .sceneFPS) ?? d.sceneFPS
        audioReactive = try c.decodeIfPresent(Bool.self, forKey: .audioReactive) ?? d.audioReactive
        rotationMinutes = try c.decodeIfPresent(Int.self, forKey: .rotationMinutes) ?? d.rotationMinutes
        lockScreenSync = try c.decodeIfPresent(Bool.self, forKey: .lockScreenSync) ?? d.lockScreenSync
    }
}

/// Persisted library state (state.json).
public struct LibraryState: Codable, Equatable, Sendable {
    /// Assignment key that applies to every screen without its own entry.
    public static let allScreensKey = "*"

    public var wallpapers: [Wallpaper] = []
    /// Screen UUID (or `allScreensKey`) -> wallpaper id.
    public var assignments: [String: UUID] = [:]
    public var settings = PlaybackSettings()
    public var userPaused = false
    public var installedAerialIDs: [UUID] = []
    public var customCatalogURL: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wallpapers = try c.decodeIfPresent([Wallpaper].self, forKey: .wallpapers) ?? []
        assignments = try c.decodeIfPresent([String: UUID].self, forKey: .assignments) ?? [:]
        settings = try c.decodeIfPresent(PlaybackSettings.self, forKey: .settings) ?? PlaybackSettings()
        userPaused = try c.decodeIfPresent(Bool.self, forKey: .userPaused) ?? false
        installedAerialIDs = try c.decodeIfPresent([UUID].self, forKey: .installedAerialIDs) ?? []
        customCatalogURL = try c.decodeIfPresent(String.self, forKey: .customCatalogURL)
    }
}
