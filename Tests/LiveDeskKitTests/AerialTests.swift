import Foundation
import Testing
@testable import LiveDeskKit

/// Shape copied from the real macOS 27 entries.json (values shortened).
let appleManifest = """
{
  "assets": [{
    "accessibilityLabel": "macOS",
    "categories": ["dynamic-aerials"],
    "id": "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19",
    "includeInShuffle": false,
    "localizedNameKey": "DYNAMIC_LIGHT_KEY",
    "pointsOfInterest": {},
    "preferredOrder": 0,
    "previewImage": "https://example.invalid/a.png",
    "shotID": "GG_LM_H",
    "showInTopLevel": true,
    "subcategories": ["17647EAB-8357-48B0-BCD6-B892194267C5"],
    "url-4K-SDR-240FPS": "https://example.invalid/a.mov",
    "variant": {"appearance": "light", "orientation": "landscape"},
    "videoGravity": "resize"
  }],
  "categories": [{
    "id": "dynamic-aerials",
    "localizedNameKey": "AerialCategoryDynamic",
    "preferredOrder": 0,
    "subcategories": [{"id": "17647EAB-8357-48B0-BCD6-B892194267C5", "combineVariants": true}]
  }, {
    "id": "A33A55D9-EDEA-4596-A850-6C10B54FBBB5",
    "localizedNameKey": "AerialCategoryLandscapes",
    "preferredOrder": 1,
    "subcategories": []
  }],
  "initialAssetCount": 4,
  "localizationVersion": "22L-1",
  "version": 1
}
"""

struct AerialManifestEditorTests {
    let items = [
        AerialItem(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, title: "Mare",
                   videoURL: URL(fileURLWithPath: "/tmp/v/1.mov"), thumbnailURL: URL(fileURLWithPath: "/tmp/t/1.png")),
        AerialItem(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, title: "Neve",
                   videoURL: URL(fileURLWithPath: "/tmp/v/2.mov"), thumbnailURL: URL(fileURLWithPath: "/tmp/t/2.png")),
    ]

    func json(_ data: Data) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func addsCategoryAndAssetsPreservingApple() throws {
        let out = try AerialManifestEditor.apply(items: items, to: Data(appleManifest.utf8))
        let root = json(out)
        let assets = root["assets"] as! [[String: Any]]
        let categories = root["categories"] as! [[String: Any]]
        #expect(assets.count == 3)
        #expect(categories.count == 3)
        #expect(root["localizationVersion"] as? String == "22L-1")
        #expect(root["initialAssetCount"] as? Int == 4)

        let apple = assets.first { $0["id"] as? String == "4DFE24ED-71CC-42D4-9FE8-3B8959B6CC19" }!
        #expect((apple["variant"] as? [String: String])?["appearance"] == "light")

        let ours = categories.last!
        #expect(ours["id"] as? String == AerialManifestEditor.categoryID)
        #expect(ours["preferredOrder"] as? Int == 2)
        #expect(ours["representativeAssetID"] as? String == "11111111-1111-1111-1111-111111111111")

        let mare = assets.first { $0["id"] as? String == "11111111-1111-1111-1111-111111111111" }!
        #expect(mare["url-4K-SDR-240FPS"] as? String == "file:///tmp/v/1.mov")
        #expect(mare["categories"] as? [String] == [AerialManifestEditor.categoryID])
        #expect(mare["subcategories"] as? [String] == [AerialManifestEditor.subcategoryID])
        #expect(AerialManifestEditor.containsCategory(out))
        #expect(Set(AerialManifestEditor.ourAssetIDs(out)) == Set(items.map(\.id.uuidString)))
    }

    @Test func idempotent() throws {
        let once = try AerialManifestEditor.apply(items: items, to: Data(appleManifest.utf8))
        let twice = try AerialManifestEditor.apply(items: items, to: once)
        #expect((json(twice)["assets"] as! [Any]).count == 3)
        #expect((json(twice)["categories"] as! [Any]).count == 3)
    }

    @Test func emptyRemovesEverythingOurs() throws {
        let added = try AerialManifestEditor.apply(items: items, to: Data(appleManifest.utf8))
        let removed = try AerialManifestEditor.apply(items: [], to: added)
        #expect(!AerialManifestEditor.containsCategory(removed))
        #expect(AerialManifestEditor.ourAssetIDs(removed).isEmpty)
        #expect((json(removed)["assets"] as! [Any]).count == 1)
        #expect((json(removed)["categories"] as! [Any]).count == 2)
    }

    @Test func rejectsNonObject() {
        #expect(throws: AerialManifestError.self) { try AerialManifestEditor.apply(items: items, to: Data("[]".utf8)) }
    }
}

@MainActor
struct AerialInstallerTests {
    func fakeAerials() throws -> URL {
        let root = makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("manifest"), withIntermediateDirectories: true)
        try Data(appleManifest.utf8).write(to: root.appendingPathComponent("manifest/entries.json"))
        return root
    }

    @Test func uninstallRestoresAndBacksUp() throws {
        let root = try fakeAerials()
        let backups = makeTempDir()
        let installer = AerialInstaller(aerialsRoot: root, backupFolder: backups)
        installer.restartsWallpaperAgent = false
        #expect(installer.isAvailable)

        // Simulate a previous install.
        let id = UUID()
        let data = try AerialManifestEditor.apply(items: [AerialItem(id: id, title: "x", videoURL: installer.videoURL(for: id), thumbnailURL: installer.thumbnailURL(for: id))],
                                                  to: Data(appleManifest.utf8))
        try data.write(to: installer.manifestURL)
        #expect(installer.needsRepair(expected: [id]) == false)
        #expect(installer.needsRepair(expected: [id, UUID()]))

        try installer.uninstall(previouslyInstalled: [id])
        let after = try Data(contentsOf: installer.manifestURL)
        #expect(!AerialManifestEditor.containsCategory(after))
        #expect(FileManager.default.fileExists(atPath: backups.appendingPathComponent("entries-last.json").path))
    }

    @Test func missingCatalogIsReported() async {
        let installer = AerialInstaller(aerialsRoot: makeTempDir(), backupFolder: makeTempDir())
        installer.restartsWallpaperAgent = false
        #expect(!installer.isAvailable)
        await #expect(throws: (any Error).self) { try await installer.sync([], previouslyInstalled: []) }
        if case .failed = installer.status {} else { Issue.record("status should be failed") }
    }
}
