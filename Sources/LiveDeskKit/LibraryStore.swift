import Foundation
import Observation
import UniformTypeIdentifiers

public enum LibraryError: Error, LocalizedError, Equatable {
    case unsupportedType(String)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .unsupportedType(let ext): return "Formato non supportato: .\(ext)"
        case .notFound: return "File non trovato"
        }
    }
}

/// Owns the wallpaper library on disk: `<root>/state.json` and `<root>/Media/`.
@MainActor
@Observable
public final class LibraryStore {
    public let root: URL
    public let builtInScenesRoot: URL?
    public private(set) var state: LibraryState
    public private(set) var builtIns: [Wallpaper] = []
    public private(set) var lastError: String?

    private let fm = FileManager.default

    public var mediaFolder: URL { root.appendingPathComponent("Media", isDirectory: true) }
    public var stateURL: URL { root.appendingPathComponent("state.json") }

    /// Built-in scenes first, then user items in import order.
    public var wallpapers: [Wallpaper] { builtIns + state.wallpapers }
    public var settings: PlaybackSettings { state.settings }

    public nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LiveDesk", isDirectory: true)
    }

    public init(root: URL = LibraryStore.defaultRoot, builtInScenesRoot: URL? = Bundle.main.url(forResource: "Scenes", withExtension: nil)) {
        self.root = root
        self.builtInScenesRoot = builtInScenesRoot
        self.state = LibraryState()
        try? fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    public func load() {
        if let data = try? Data(contentsOf: stateURL) {
            do {
                state = try Self.decoder.decode(LibraryState.self, from: data)
            } catch {
                lastError = "state.json illeggibile: \(error.localizedDescription)"
                try? fm.copyItem(at: stateURL, to: root.appendingPathComponent("state.corrupt-\(Int(Date().timeIntervalSince1970)).json"))
                state = LibraryState()
            }
        }
        builtIns = loadBuiltIns()
        if state.assignments.isEmpty, let first = wallpapers.first {
            state.assignments[LibraryState.allScreensKey] = first.id
        }
    }

    public func save() {
        do {
            let data = try Self.encoder.encode(state)
            try data.write(to: stateURL, options: .atomic)
        } catch {
            lastError = "Salvataggio fallito: \(error.localizedDescription)"
        }
    }

    private func loadBuiltIns() -> [Wallpaper] {
        guard let base = builtInScenesRoot,
              let names = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        return names.sorted().compactMap { name -> Wallpaper? in
            let folder = base.appendingPathComponent(name)
            guard let manifest = try? SceneManifest.load(from: folder) else { return nil }
            let id = manifest.id ?? UUID()
            return Wallpaper(id: id, title: manifest.name, kind: .scene, relativePath: name,
                             isBuiltIn: true, addedAt: .distantPast)
        }
    }

    // MARK: Queries

    public func wallpaper(id: UUID) -> Wallpaper? {
        wallpapers.first { $0.id == id }
    }

    public func url(for wallpaper: Wallpaper) -> URL {
        if wallpaper.isBuiltIn, let base = builtInScenesRoot {
            return base.appendingPathComponent(wallpaper.relativePath)
        }
        return mediaFolder.appendingPathComponent(wallpaper.relativePath)
    }

    /// Wallpaper for a screen: its own assignment, else the all-screens one. Ignores dangling ids.
    public func wallpaperID(forScreen key: String) -> UUID? {
        for candidate in [state.assignments[key], state.assignments[LibraryState.allScreensKey]] {
            if let id = candidate, wallpaper(id: id) != nil { return id }
        }
        return nil
    }

    public func desiredAssignments(screens: [String]) -> [String: UUID] {
        var result: [String: UUID] = [:]
        for key in screens {
            if let id = wallpaperID(forScreen: key) { result[key] = id }
        }
        return result
    }

    // MARK: Mutations

    @discardableResult
    public func importItem(at source: URL) throws -> Wallpaper {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDir) else { throw LibraryError.notFound }
        let id = UUID()
        let kind: WallpaperKind
        var title = source.deletingPathExtension().lastPathComponent
        let destName: String
        if isDir.boolValue {
            let manifest = try SceneManifest.load(from: source)
            kind = .scene
            title = manifest.name
            destName = id.uuidString
        } else {
            let ext = source.pathExtension.lowercased()
            guard let type = UTType(filenameExtension: ext) else { throw LibraryError.unsupportedType(ext) }
            if type.conforms(to: .movie) || type.conforms(to: .video) {
                kind = .video
            } else if type.conforms(to: .image) {
                kind = .image
            } else {
                throw LibraryError.unsupportedType(ext)
            }
            destName = "\(id.uuidString).\(ext)"
        }
        try fm.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: mediaFolder.appendingPathComponent(destName))
        let item = Wallpaper(id: id, title: title, kind: kind, relativePath: destName)
        state.wallpapers.append(item)
        save()
        return item
    }

    public func remove(id: UUID) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == id }) else { return }
        let item = state.wallpapers.remove(at: index)
        try? fm.removeItem(at: url(for: item))
        state.assignments = state.assignments.filter { $0.value != id }
        save()
    }

    public func rename(id: UUID, to title: String) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == id }) else { return }
        state.wallpapers[index].title = title
        save()
    }

    public func setOnLockScreen(id: UUID, _ value: Bool) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == id }),
              state.wallpapers[index].kind == .video else { return }
        state.wallpapers[index].onLockScreen = value
        save()
    }

    /// Assigns a wallpaper to one screen, or to all screens (clearing per-screen overrides).
    public func assign(_ id: UUID, toScreen key: String?) {
        if let key {
            state.assignments[key] = id
        } else {
            state.assignments = [LibraryState.allScreensKey: id]
        }
        save()
    }

    public func updateSettings(_ change: (inout PlaybackSettings) -> Void) {
        change(&state.settings)
        save()
    }

    public func setUserPaused(_ paused: Bool) {
        state.userPaused = paused
        save()
    }

    public func setInstalledAerialIDs(_ ids: [UUID]) {
        state.installedAerialIDs = ids
        save()
    }

    /// Moves every assignment to the next wallpaper in library order.
    public func advanceRotation() {
        let list = wallpapers
        guard list.count > 1 else { return }
        for (key, id) in state.assignments {
            let index = list.firstIndex { $0.id == id } ?? -1
            state.assignments[key] = list[(index + 1) % list.count].id
        }
        save()
    }

    /// Records where a downloaded wallpaper came from.
    public func annotate(id: UUID, title: String, credit: String?, sourcePage: String?, catalogID: String?) {
        guard let index = state.wallpapers.firstIndex(where: { $0.id == id }) else { return }
        state.wallpapers[index].title = title
        state.wallpapers[index].credit = credit
        state.wallpapers[index].sourcePage = sourcePage
        state.wallpapers[index].catalogID = catalogID
        save()
    }

    public func wallpaper(catalogID: String) -> Wallpaper? {
        state.wallpapers.first { $0.catalogID == catalogID }
    }

    public func setCustomCatalogURL(_ value: String?) {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        state.customCatalogURL = (trimmed?.isEmpty ?? true) ? nil : trimmed
        save()
    }

    public func clearError() { lastError = nil }

    // MARK: Coding

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
