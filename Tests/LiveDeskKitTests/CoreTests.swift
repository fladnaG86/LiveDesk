import AVFoundation
import CoreGraphics
import Foundation
import Metal
import Testing
@testable import LiveDeskKit

func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("livedesk-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Repo-relative Resources/Scenes, found from this source file.
let repoScenes = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/Scenes", isDirectory: true)

@MainActor
struct LibraryStoreTests {
    @Test func importPersistsAndReloads() throws {
        let root = makeTempDir()
        let src = makeTempDir().appendingPathComponent("Sea Waves.mov")
        try Data([0, 1, 2]).write(to: src)

        let store = LibraryStore(root: root, builtInScenesRoot: nil)
        let item = try store.importItem(at: src)
        #expect(item.kind == .video)
        #expect(item.title == "Sea Waves")
        #expect(FileManager.default.fileExists(atPath: store.url(for: item).path))

        let reloaded = LibraryStore(root: root, builtInScenesRoot: nil)
        #expect(reloaded.wallpapers.map(\.id) == [item.id])
    }

    @Test func imageAndUnsupportedTypes() throws {
        let dir = makeTempDir()
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: nil)
        let png = dir.appendingPathComponent("a.png")
        try Data([1]).write(to: png)
        #expect(try store.importItem(at: png).kind == .image)

        let txt = dir.appendingPathComponent("notes.txt")
        try Data([1]).write(to: txt)
        #expect(throws: LibraryError.unsupportedType("txt")) { try store.importItem(at: txt) }
    }

    @Test func assignmentFallsBackToAllScreens() throws {
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: nil)
        let dir = makeTempDir()
        let a = dir.appendingPathComponent("a.mov"); try Data([1]).write(to: a)
        let b = dir.appendingPathComponent("b.mov"); try Data([1]).write(to: b)
        let wa = try store.importItem(at: a)
        let wb = try store.importItem(at: b)

        store.assign(wa.id, toScreen: nil)
        store.assign(wb.id, toScreen: "SCREEN-2")
        #expect(store.wallpaperID(forScreen: "SCREEN-1") == wa.id)
        #expect(store.wallpaperID(forScreen: "SCREEN-2") == wb.id)
        #expect(store.desiredAssignments(screens: ["SCREEN-1", "SCREEN-2"]) == ["SCREEN-1": wa.id, "SCREEN-2": wb.id])

        // Assigning to all screens clears overrides.
        store.assign(wb.id, toScreen: nil)
        #expect(store.wallpaperID(forScreen: "SCREEN-2") == wb.id)
        #expect(store.state.assignments.count == 1)
    }

    @Test func removeDeletesFileAndAssignments() throws {
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: nil)
        let src = makeTempDir().appendingPathComponent("a.mp4"); try Data([1]).write(to: src)
        let item = try store.importItem(at: src)
        store.assign(item.id, toScreen: "X")
        let file = store.url(for: item)
        store.remove(id: item.id)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(store.state.assignments.values.contains(item.id) == false)
        #expect(store.wallpaperID(forScreen: "X") == nil)
    }

    @Test func builtInScenesLoadWithStableIDs() {
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: repoScenes)
        #expect(store.builtIns.count == 12)
        #expect(store.builtIns.allSatisfy { $0.kind == .scene && $0.isBuiltIn })
        let again = LibraryStore(root: makeTempDir(), builtInScenesRoot: repoScenes)
        #expect(store.builtIns.map(\.id) == again.builtIns.map(\.id))
        // First launch assigns something.
        #expect(store.wallpaperID(forScreen: "ANY") != nil)
    }

    @Test func rotationAdvances() throws {
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: repoScenes)
        let first = store.wallpaperID(forScreen: "S")
        store.advanceRotation()
        #expect(store.wallpaperID(forScreen: "S") != first)
    }

    @Test func corruptStateIsBackedUp() throws {
        let root = makeTempDir()
        try Data("{not json".utf8).write(to: root.appendingPathComponent("state.json"))
        let store = LibraryStore(root: root, builtInScenesRoot: nil)
        #expect(store.lastError != nil)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(files.contains { $0.hasPrefix("state.corrupt-") })
    }

    @Test func oldStateWithMissingKeysDecodes() throws {
        let json = #"{"wallpapers":[{"id":"A11C0E5E-7A1B-4C2D-8E3F-0A1B2C3D4E99","title":"x","kind":"video","relativePath":"x.mov"}]}"#
        let state = try LibraryStore.decoder.decode(LibraryState.self, from: Data(json.utf8))
        #expect(state.wallpapers.first?.onLockScreen == false)
        #expect(state.settings == PlaybackSettings())
    }
}

struct ReconcilerTests {
    @Test func plan() {
        let a = UUID(), b = UUID(), c = UUID()
        let p = Reconciler.plan(current: ["s1": a, "s2": b, "gone": c], desired: ["s1": a, "s2": c, "new": a])
        #expect(p.create == ["new"])
        #expect(p.update == ["s2"])
        #expect(p.destroy == ["gone"])
        #expect(Reconciler.plan(current: ["s1": a], desired: ["s1": a]).isEmpty)
    }
}

struct SceneManifestTests {
    func folder(_ manifest: String, files: [String] = ["a.metal"]) throws -> URL {
        let dir = makeTempDir()
        try Data(manifest.utf8).write(to: dir.appendingPathComponent("manifest.json"))
        for f in files { try Data("// x".utf8).write(to: dir.appendingPathComponent(f)) }
        return dir
    }

    @Test func valid() throws {
        let m = try SceneManifest.load(from: folder(#"{"name":"A","passes":[{"source":"a.metal","function":"main0"}],"usesAudio":true}"#))
        #expect(m.name == "A")
        #expect(m.needsAudio)
    }

    @Test func invalidOnes() throws {
        #expect(throws: SceneManifestError.missingManifest) { try SceneManifest.load(from: makeTempDir()) }
        #expect(throws: SceneManifestError.noPasses) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[]}"#))
        }
        let nine = Array(repeating: #"{"source":"a.metal","function":"f"}"#, count: 9).joined(separator: ",")
        #expect(throws: SceneManifestError.tooManyPasses(9)) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[\#(nine)]}"#))
        }
        #expect(throws: SceneManifestError.notMetal("a.txt")) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[{"source":"a.txt","function":"f"}]}"#, files: ["a.txt"]))
        }
        #expect(throws: SceneManifestError.invalidPath("../a.metal")) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[{"source":"../a.metal","function":"f"}]}"#))
        }
        #expect(throws: SceneManifestError.missingSource("b.metal")) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[{"source":"b.metal","function":"f"}]}"#))
        }
        #expect(throws: SceneManifestError.invalidFunction("f()")) {
            try SceneManifest.load(from: folder(#"{"name":"A","passes":[{"source":"a.metal","function":"f()"}]}"#))
        }
    }

    /// Compiles every built-in scene with the real Metal compiler.
    @Test func builtInScenesCompile() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let names = try FileManager.default.contentsOfDirectory(atPath: repoScenes.path).filter { !$0.hasPrefix(".") }
        #expect(names.count == 12)
        for name in names {
            let folder = repoScenes.appendingPathComponent(name)
            let manifest = try SceneManifest.load(from: folder)
            _ = try SceneRenderer(folder: folder, manifest: manifest, device: device, viewPixelFormat: .bgra8Unorm)
        }
    }

    @Test func brokenShaderReportsCompileError() throws {
        let dir = try folder(#"{"name":"A","passes":[{"source":"a.metal","function":"f"}]}"#)
        try Data("fragment float4 f( { nope".utf8).write(to: dir.appendingPathComponent("a.metal"))
        let device = try #require(MTLCreateSystemDefaultDevice())
        #expect(throws: SceneRendererError.self) {
            _ = try SceneRenderer(folder: dir, manifest: SceneManifest.load(from: dir), device: device, viewPixelFormat: .bgra8Unorm)
        }
    }
}

struct PlaybackPolicyTests {
    @Test func rules() {
        var s = PlaybackSettings()
        var c = PlaybackConditions()
        #expect(PlaybackPolicy.shouldPlay(screen: "a", conditions: c, settings: s))
        c.onBattery = true
        #expect(!PlaybackPolicy.shouldPlay(screen: "a", conditions: c, settings: s))
        s.pauseOnBattery = false
        #expect(PlaybackPolicy.shouldPlay(screen: "a", conditions: c, settings: s))
        c.coveredScreens = ["a"]
        #expect(!PlaybackPolicy.shouldPlay(screen: "a", conditions: c, settings: s))
        #expect(PlaybackPolicy.shouldPlay(screen: "b", conditions: c, settings: s))
        c.userPaused = true
        #expect(PlaybackPolicy.pauseReason(screen: "b", conditions: c, settings: s) == "In pausa")
    }
}

struct OcclusionTests {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)

    @Test func fullscreenWindowCovers() {
        let w = WindowRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), alpha: 1, ownerPID: 42)
        #expect(OcclusionDetector.isCovered(screenBounds: screen, windows: [w], ownPID: 1))
    }

    @Test func ignoresSmallOwnTransparentAndOtherLayers() {
        let small = WindowRect(layer: 0, bounds: CGRect(x: 0, y: 0, width: 500, height: 800), alpha: 1, ownerPID: 42)
        let own = WindowRect(layer: 0, bounds: screen, alpha: 1, ownerPID: 1)
        let clear = WindowRect(layer: 0, bounds: screen, alpha: 0.5, ownerPID: 42)
        let dock = WindowRect(layer: 20, bounds: screen, alpha: 1, ownerPID: 42)
        #expect(!OcclusionDetector.isCovered(screenBounds: screen, windows: [small, own, clear, dock], ownPID: 1))
    }

    @Test func windowOnOtherScreenDoesNotCover() {
        let w = WindowRect(layer: 0, bounds: CGRect(x: 1000, y: 0, width: 1000, height: 800), alpha: 1, ownerPID: 42)
        #expect(!OcclusionDetector.isCovered(screenBounds: screen, windows: [w], ownPID: 1))
    }
}

struct OfflineRenderTests {
    @Test func blendWeights() {
        var o = OfflineRenderOptions()
        o.fps = 10; o.duration = 4; o.crossfade = 1
        #expect(o.frameCount == 40)
        #expect(o.crossfadeFrames == 10)
        #expect(o.blendWeight(frame: 0) == 0)
        #expect(o.blendWeight(frame: 5) == 0.5)
        #expect(o.blendWeight(frame: 10) == 1)
        o.crossfade = 100
        #expect(o.crossfadeFrames == 20) // capped at half
    }

    @Test func rendersSmallLoopingMovie() async throws {
        var o = OfflineRenderOptions()
        o.width = 128; o.height = 72; o.fps = 10; o.duration = 2; o.crossfade = 0.5; o.bitrate = 500_000
        let out = makeTempDir().appendingPathComponent("aurora.mov")
        var last = 0.0
        try OfflineSceneRenderer.render(folder: repoScenes.appendingPathComponent("aurora"), to: out, options: o) { last = $0 }
        #expect(last == 1)
        let asset = AVURLAsset(url: out)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 2) < 0.15)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 128, height: 72))
    }
}
