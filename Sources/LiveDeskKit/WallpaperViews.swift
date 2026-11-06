import AppKit
import AVFoundation
import MetalKit

/// Borderless window glued to the desktop layer of one screen, on every Space, below desktop icons.
public final class WallpaperWindow: NSWindow {
    public init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        hasShadow = false
        backgroundColor = .black
        isReleasedWhenClosed = false
        animationBehavior = .none
        place(on: screen)
    }

    public func place(on screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }
}

@MainActor
public protocol WallpaperContent: NSView {
    func setPlaying(_ playing: Bool)
    func apply(settings: PlaybackSettings)
    func teardown()
}

// MARK: Video

public final class VideoContentView: NSView, WallpaperContent {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private let playerLayer = AVPlayerLayer()
    private var rate: Float = 1
    private var playing = false

    public init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.frame = bounds
        layer?.addSublayer(playerLayer)
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 2
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        playerLayer.frame = bounds
    }

    public func setPlaying(_ playing: Bool) {
        self.playing = playing
        if playing {
            player.defaultRate = rate
            player.play()
        } else {
            player.pause()
        }
    }

    public func apply(settings: PlaybackSettings) {
        rate = Float(min(4, max(0.1, settings.speed)))
        player.defaultRate = rate
        if playing { player.rate = rate }
    }

    public func teardown() {
        player.pause()
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        playerLayer.player = nil
    }
}

// MARK: Image

public final class ImageContentView: NSView, WallpaperContent {
    public init(url: URL) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspectFill
        layer?.contents = NSImage(contentsOf: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func setPlaying(_ playing: Bool) {}
    public func apply(settings: PlaybackSettings) {}
    public func teardown() { layer?.contents = nil }
}

// MARK: Scene

public final class SceneContentView: MTKView, WallpaperContent {
    private let renderer: SceneRenderer

    public init(folder: URL, audio: SystemAudioTap?) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw SceneRendererError.noDevice }
        let manifest = try SceneManifest.load(from: folder)
        renderer = try SceneRenderer(folder: folder, manifest: manifest, device: device, viewPixelFormat: .bgra8Unorm)
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        enableSetNeedsDisplay = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        delegate = renderer
        isPaused = true
        if let audio { renderer.audioProvider = { audio.bands } }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    public var usesAudio: Bool { renderer.manifest.needsAudio }

    public func setPlaying(_ playing: Bool) {
        if playing { renderer.resetClock() }
        isPaused = !playing
        if !playing { renderStill() }
    }

    public override func layout() {
        super.layout()
        if isPaused { renderStill() }
    }

    /// A paused scene still shows a frame instead of black.
    private func renderStill() {
        guard window != nil, drawableSize.width > 0, drawableSize.height > 0 else { return }
        renderer.resetClock()
        draw()
    }

    public func apply(settings: PlaybackSettings) {
        preferredFramesPerSecond = min(120, max(15, settings.sceneFPS))
        renderer.renderScale = settings.sceneQuality
        renderer.speed = settings.speed
    }

    public func teardown() {
        isPaused = true
        delegate = nil
    }
}

// MARK: Error

public final class MessageContentView: NSView, WallpaperContent {
    public init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 600),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    public func setPlaying(_ playing: Bool) {}
    public func apply(settings: PlaybackSettings) {}
    public func teardown() {}
}
