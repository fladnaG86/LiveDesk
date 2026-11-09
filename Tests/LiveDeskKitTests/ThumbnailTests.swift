import CoreGraphics
import Foundation
import Testing
@testable import LiveDeskKit

struct SceneStillTests {
    @Test func rendersStillOfRequestedSize() throws {
        let image = try OfflineSceneRenderer.renderStill(folder: repoScenes.appendingPathComponent("aurora"),
                                                        width: 160, height: 90)
        #expect(image.width == 160)
        #expect(image.height == 90)
        // Not a blank frame: some pixel must differ from black.
        let data = try #require(image.dataProvider?.data as Data?)
        #expect(data.contains { $0 != 0 && $0 != 255 })
    }

    @Test func rendersEveryBuiltInScene() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: repoScenes.path).filter { !$0.hasPrefix(".") }
        #expect(!names.isEmpty)
        for name in names {
            let image = try OfflineSceneRenderer.renderStill(folder: repoScenes.appendingPathComponent(name), width: 64, height: 36)
            #expect(image.width == 64, "\(name)")
        }
    }
}

struct PaletteTests {
    @Test func paletteIndexIsStableAndInRange() {
        let id = UUID(uuidString: "8E7B1C52-0000-4000-8000-000000000001")!
        let w = Wallpaper(id: id, title: "x", kind: .scene, relativePath: "x")
        let first = w.paletteIndex(count: 4)
        #expect((0..<4).contains(first))
        #expect(w.paletteIndex(count: 4) == first)
        // Same id in a fresh value gives the same index (no per-launch hash seed).
        #expect(Wallpaper(id: id, title: "y", kind: .video, relativePath: "y").paletteIndex(count: 4) == first)
        #expect(w.paletteIndex(count: 0) == 0)
    }
}

@MainActor
struct ThumbnailCacheTests {
    @Test func sceneThumbnailIsGeneratedAndCachedInMemory() async throws {
        let root = makeTempDir()
        let cache = ThumbnailCache(root: root)
        let scene = Wallpaper(title: "Aurora", kind: .scene, relativePath: "aurora", isBuiltIn: true)
        let wrote = await cache.ensure(for: scene, source: repoScenes.appendingPathComponent("aurora"))
        #expect(wrote)
        #expect(FileManager.default.fileExists(atPath: cache.url(for: scene.id).path))
        let a = try #require(cache.cachedImage(for: scene.id))
        // Second read comes from memory: same instance even if the file disappears.
        try FileManager.default.removeItem(at: cache.url(for: scene.id))
        let b = try #require(cache.cachedImage(for: scene.id))
        #expect(a === b)
        cache.remove(id: scene.id)
        #expect(cache.cachedImage(for: scene.id) == nil)
    }
}
