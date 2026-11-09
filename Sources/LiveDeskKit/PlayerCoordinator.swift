import AppKit
import CoreGraphics
import os

public extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// Stable identity across reconnects and reboots.
    var stableKey: String? {
        guard let id = displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

/// Owns one wallpaper window per connected screen and keeps them in sync with the library.
/// Configuration for disconnected screens stays in the store; only connected screens get players.
@MainActor
public final class PlayerCoordinator {
    final class Player {
        let window: WallpaperWindow
        let content: WallpaperContent
        let wallpaperID: UUID
        var screen: NSScreen
        var playing = false

        init(window: WallpaperWindow, content: WallpaperContent, wallpaperID: UUID, screen: NSScreen) {
            self.window = window
            self.content = content
            self.wallpaperID = wallpaperID
            self.screen = screen
        }
    }

    private let store: LibraryStore
    public let audio = SystemAudioTap()
    private var players: [String: Player] = [:]
    public private(set) var conditions = PlaybackConditions()
    private var observers: [NSObjectProtocol] = []
    private var pollTimer: Timer?
    private var rotationTimer: Timer?
    private var audioRunning = false
    private var rotationMinutes = 0
    private var lastSnapshot: StateSnapshot?

    /// What the UI shows; `onStateChange` fires only when this changes.
    struct StateSnapshot: Equatable {
        var conditions: PlaybackConditions
        var wallpapers: [String: UUID]
        var playing: [String: Bool]
    }
    private let log = Logger(subsystem: "dev.livedesk", category: "players")

    public var onStateChange: (() -> Void)?

    public init(store: LibraryStore) {
        self.store = store
    }

    public var activeScreens: [String] { players.keys.sorted() }

    public func playingWallpaperID(screen key: String) -> UUID? { players[key]?.wallpaperID }

    public func pauseReason(screen key: String) -> String? {
        PlaybackPolicy.pauseReason(screen: key, conditions: conditions, settings: store.settings)
    }

    public static func connectedScreens() -> [(key: String, screen: NSScreen)] {
        var seen = Set<String>()
        return NSScreen.screens.compactMap { screen in
            guard let key = screen.stableKey, seen.insert(key).inserted else { return nil }
            return (key, screen)
        }
    }

    // MARK: Lifecycle

    public func start() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConditions() }
        })
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true), (NSWorkspace.screensDidWakeNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.conditions.screensAsleep = asleep
                    if !asleep { self?.reconcile() }
                    self?.applyPlayback()
                }
            })
        }
        for (name, inactive) in [(NSWorkspace.sessionDidResignActiveNotification, true), (NSWorkspace.sessionDidBecomeActiveNotification, false)] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.conditions.sessionInactive = inactive
                    self?.applyPlayback()
                }
            })
        }
        observers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        })
        observers.append(workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConditions() }
        })

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshConditions() }
        }
        reconcile()
        refreshConditions()
        updateRotationTimer()
    }

    public func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        pollTimer?.invalidate()
        rotationTimer?.invalidate()
        for key in Array(players.keys) { destroy(key) }
        stopAudio()
    }

    // MARK: Reconcile

    /// Creates, replaces and destroys windows so connected screens show their configured wallpaper.
    public func reconcile() {
        let connected = Self.connectedScreens()
        let screenByKey = Dictionary(connected.map { ($0.key, $0.screen) }, uniquingKeysWith: { a, _ in a })
        let desired = store.desiredAssignments(screens: connected.map(\.key))
        let current = players.mapValues(\.wallpaperID)
        let plan = Reconciler.plan(current: current, desired: desired)

        for key in plan.destroy { destroy(key) }
        for key in plan.update { destroy(key) }
        for key in plan.create + plan.update {
            guard let screen = screenByKey[key], let id = desired[key], let wallpaper = store.wallpaper(id: id) else { continue }
            create(key: key, screen: screen, wallpaper: wallpaper)
        }
        // Retained players: refresh their screen object and frame (resolution / arrangement changes).
        for (key, player) in players {
            guard let screen = screenByKey[key] else { continue }
            player.screen = screen
            if player.window.frame != screen.frame { player.window.place(on: screen) }
        }
        if !plan.isEmpty { log.info("reconcile create=\(plan.create.count) update=\(plan.update.count) destroy=\(plan.destroy.count)") }
        refreshConditions()
    }

    private func create(key: String, screen: NSScreen, wallpaper: Wallpaper) {
        let url = store.url(for: wallpaper)
        let content: WallpaperContent
        switch wallpaper.kind {
        case .video:
            content = VideoContentView(url: url)
        case .image:
            content = ImageContentView(url: url)
        case .scene:
            do {
                content = try SceneContentView(folder: url, audio: audio)
            } catch {
                content = MessageContentView(message: "\(wallpaper.title): \(error.localizedDescription)")
            }
        }
        let window = WallpaperWindow(screen: screen)
        content.frame = NSRect(origin: .zero, size: screen.frame.size)
        content.autoresizingMask = [.width, .height]
        window.contentView = content
        content.apply(settings: store.settings)
        window.orderFrontRegardless()
        players[key] = Player(window: window, content: content, wallpaperID: wallpaper.id, screen: screen)
    }

    private func destroy(_ key: String) {
        guard let player = players.removeValue(forKey: key) else { return }
        player.content.teardown()
        player.window.contentView = nil
        player.window.orderOut(nil)
        player.window.close()
    }

    // MARK: Playback

    public func settingsChanged() {
        for player in players.values { player.content.apply(settings: store.settings) }
        // Restart the rotation countdown only when its interval changed, not on every slider move.
        if store.settings.rotationMinutes != rotationMinutes { updateRotationTimer() }
        applyPlayback()
    }

    private func refreshConditions() {
        conditions.userPaused = store.state.userPaused
        conditions.onBattery = PowerState.onBattery
        conditions.lowPowerMode = PowerState.lowPowerMode
        if store.settings.pauseWhenCovered, !players.isEmpty {
            let windows = OcclusionDetector.onScreenWindows()
            let pid = ProcessInfo.processInfo.processIdentifier
            var covered = Set<String>()
            for (key, player) in players {
                guard let id = player.screen.displayID else { continue }
                if OcclusionDetector.isCovered(screenBounds: CGDisplayBounds(id), windows: windows, ownPID: pid) {
                    covered.insert(key)
                }
            }
            conditions.coveredScreens = covered
        } else {
            conditions.coveredScreens = []
        }
        applyPlayback()
    }

    public func applyPlayback() {
        conditions.userPaused = store.state.userPaused
        var anyAudioScene = false
        for (key, player) in players {
            let play = PlaybackPolicy.shouldPlay(screen: key, conditions: conditions, settings: store.settings)
            if play != player.playing {
                player.content.setPlaying(play)
                player.playing = play
            }
            if play, let scene = player.content as? SceneContentView, scene.usesAudio { anyAudioScene = true }
        }
        if anyAudioScene && store.settings.audioReactive { startAudio() } else { stopAudio() }
        // Called every 2 s by the poll timer: only notify the UI when something visible changed.
        let snapshot = StateSnapshot(conditions: conditions,
                                     wallpapers: players.mapValues(\.wallpaperID),
                                     playing: players.mapValues(\.playing))
        if snapshot != lastSnapshot {
            lastSnapshot = snapshot
            onStateChange?()
        }
    }

    private func startAudio() {
        guard !audioRunning else { return }
        audioRunning = true
        audio.start()
    }

    private func stopAudio() {
        guard audioRunning else { return }
        audioRunning = false
        audio.stop()
    }

    private func updateRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        let minutes = store.settings.rotationMinutes
        rotationMinutes = minutes
        guard minutes > 0 else { return }
        rotationTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.store.state.userPaused else { return }
                self.store.advanceRotation()
                self.reconcile()
            }
        }
    }
}
