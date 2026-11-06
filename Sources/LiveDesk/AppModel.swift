import AppKit
import LiveDeskKit
import Observation
import ServiceManagement

@MainActor
@Observable
final class AppModel {
    let store: LibraryStore
    let coordinator: PlayerCoordinator
    let thumbnails: ThumbnailCache
    let aerial: AerialInstaller
    let discover = DiscoverModel()

    var message: String?
    var lockScreenStatus: AerialInstaller.Status = .idle
    var thumbnailVersion = 0
    var stateVersion = 0
    var launchAtLogin = SMAppService.mainApp.status == .enabled

    init() {
        store = LibraryStore()
        coordinator = PlayerCoordinator(store: store)
        thumbnails = ThumbnailCache(root: store.root)
        aerial = AerialInstaller(backupFolder: store.root.appendingPathComponent("AerialBackups", isDirectory: true))
        aerial.onStatusChange = { [weak self] status in self?.lockScreenStatus = status }
        coordinator.onStateChange = { [weak self] in self?.stateVersion += 1 }
    }

    func start() {
        coordinator.start()
        generateThumbnails()
        if store.settings.lockScreenSync {
            Task { await repairLockScreenIfNeeded() }
        }
        if let error = store.lastError { message = error; store.clearError() }
    }

    // MARK: Screens

    struct ScreenChoice: Identifiable, Hashable {
        let id: String
        let name: String
    }

    var screens: [ScreenChoice] {
        _ = stateVersion
        return PlayerCoordinator.connectedScreens().map { ScreenChoice(id: $0.key, name: $0.screen.localizedName) }
    }

    // MARK: Library

    func importItems(_ urls: [URL]) {
        var lastImported: Wallpaper?
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                lastImported = try store.importItem(at: url)
            } catch {
                message = "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        generateThumbnails()
        if let lastImported, urls.count == 1 { apply(lastImported.id, screen: nil) }
    }

    func remove(_ wallpaper: Wallpaper) {
        let wasOnLockScreen = wallpaper.onLockScreen
        store.remove(id: wallpaper.id)
        thumbnails.remove(id: wallpaper.id)
        coordinator.reconcile()
        if wasOnLockScreen { syncLockScreen() }
    }

    func apply(_ id: UUID, screen: String?) {
        store.assign(id, toScreen: screen)
        coordinator.reconcile()
    }

    func isActive(_ id: UUID) -> Bool {
        _ = stateVersion
        return coordinator.activeScreens.contains { coordinator.playingWallpaperID(screen: $0) == id }
    }

    func togglePause() {
        store.setUserPaused(!store.state.userPaused)
        coordinator.applyPlayback()
    }

    var isPaused: Bool {
        _ = stateVersion
        return store.state.userPaused
    }

    var pauseSummary: String? {
        _ = stateVersion
        let reasons = Set(coordinator.activeScreens.compactMap { coordinator.pauseReason(screen: $0) })
        return reasons.isEmpty ? nil : reasons.sorted().joined(separator: ", ")
    }

    func updateSettings(_ change: (inout PlaybackSettings) -> Void) {
        store.updateSettings(change)
        coordinator.settingsChanged()
    }

    private func generateThumbnails() {
        let items = store.wallpapers.filter { $0.kind != .scene }
        Task {
            for item in items {
                if await thumbnails.ensure(for: item, source: store.url(for: item)) {
                    thumbnailVersion += 1
                }
            }
        }
    }

    // MARK: Catalog downloads

    /// Downloads a catalog video into the library and optionally applies it to all screens.
    func download(_ item: CatalogItem, apply applyNow: Bool) async {
        let folder = store.root.appendingPathComponent("Downloads", isDirectory: true)
        do {
            let file = try await discover.downloads.download(item, to: folder)
            defer { try? FileManager.default.removeItem(at: file) }
            let wallpaper = try store.importItem(at: file)
            store.annotate(id: wallpaper.id, title: item.title, credit: item.credit,
                           sourcePage: item.pageURL?.absoluteString, catalogID: item.id)
            generateThumbnails()
            if applyNow { apply(wallpaper.id, screen: nil) }
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            message = "\(item.title): \(error.localizedDescription)"
        }
    }

    // MARK: Lock Screen

    var lockScreenAvailable: Bool { aerial.isAvailable }

    func setLockScreenSync(_ enabled: Bool) {
        store.updateSettings { $0.lockScreenSync = enabled }
        if enabled {
            syncLockScreen()
        } else {
            do {
                try aerial.uninstall(previouslyInstalled: store.state.installedAerialIDs)
                store.setInstalledAerialIDs([])
            } catch {
                message = "Rimozione dal blocco schermo fallita: \(error.localizedDescription)"
            }
        }
    }

    func setOnLockScreen(_ wallpaper: Wallpaper, _ value: Bool) {
        store.setOnLockScreen(id: wallpaper.id, value)
        if value && !store.settings.lockScreenSync {
            store.updateSettings { $0.lockScreenSync = true }
        }
        if store.settings.lockScreenSync { syncLockScreen() }
    }

    private var lockScreenSources: [AerialInstaller.Source] {
        store.wallpapers
            .filter { $0.kind == .video && $0.onLockScreen }
            .map { AerialInstaller.Source(id: $0.id, title: $0.title, file: store.url(for: $0)) }
    }

    func syncLockScreen() {
        let sources = lockScreenSources
        let installed = store.state.installedAerialIDs
        Task {
            do {
                let ids = try await aerial.sync(sources, previouslyInstalled: installed)
                store.setInstalledAerialIDs(ids)
            } catch {
                message = "Blocco schermo: \(error.localizedDescription)"
            }
        }
    }

    private func repairLockScreenIfNeeded() async {
        let wanted = Set(lockScreenSources.map(\.id))
        if wanted != Set(store.state.installedAerialIDs) {
            syncLockScreen()
        } else if let ids = await aerial.repairIfNeeded(lockScreenSources, installed: store.state.installedAerialIDs) {
            store.setInstalledAerialIDs(ids)
        }
    }

    func openWallpaperSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Login item

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Avvio al login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
