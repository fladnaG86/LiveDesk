import Foundation

/// A video to expose in the system Aerial catalog (Wallpaper settings + Lock Screen).
public struct AerialItem: Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var videoURL: URL
    public var thumbnailURL: URL

    public init(id: UUID, title: String, videoURL: URL, thumbnailURL: URL) {
        self.id = id
        self.title = title
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
    }
}

public enum AerialManifestError: Error, LocalizedError {
    case notAnObject
    public var errorDescription: String? { "entries.json non ha il formato atteso" }
}

/// Edits Apple's `aerials/manifest/entries.json`, touching only the LiveDesk category and its assets.
/// Every key it does not own is preserved untouched.
public enum AerialManifestEditor {
    public static let categoryID = "8E7B1C52-4D3A-4F6E-9B21-5C0D7A3E9F14"
    public static let subcategoryID = "1F4A9D63-2B8C-4E57-A0D3-6E9B2C5F7A18"
    public static let displayName = "LiveDesk"
    public static let shotPrefix = "LIVEDESK_"

    /// Returns new manifest data with exactly `items` in the LiveDesk category (removed when empty).
    public static func apply(items: [AerialItem], to data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data, options: [.mutableContainers]) as? [String: Any] else {
            throw AerialManifestError.notAnObject
        }
        var assets = root["assets"] as? [[String: Any]] ?? []
        var categories = root["categories"] as? [[String: Any]] ?? []

        assets.removeAll(where: isOurs)
        categories.removeAll { ($0["id"] as? String) == categoryID }

        if let first = items.first {
            for (index, item) in items.enumerated() {
                assets.append(asset(for: item, order: index))
            }
            let nextOrder = (categories.compactMap { $0["preferredOrder"] as? Int }.max() ?? 0) + 1
            categories.append([
                "id": categoryID,
                "localizedNameKey": displayName,
                "localizedDescriptionKey": displayName,
                "preferredOrder": nextOrder,
                "previewImage": first.thumbnailURL.absoluteString,
                "representativeAssetID": first.id.uuidString,
                "subcategories": [[
                    "id": subcategoryID,
                    "localizedNameKey": displayName,
                    "localizedDescriptionKey": displayName,
                    "preferredOrder": 0,
                    "previewImage": first.thumbnailURL.absoluteString,
                    "representativeAssetID": first.id.uuidString,
                    "combineVariants": false,
                ]],
            ])
        }
        root["assets"] = assets
        root["categories"] = categories
        return try JSONSerialization.data(withJSONObject: root, options: [.withoutEscapingSlashes])
    }

    public static func asset(for item: AerialItem, order: Int) -> [String: Any] {
        [
            "id": item.id.uuidString,
            "accessibilityLabel": item.title,
            "localizedNameKey": item.title,
            "categories": [categoryID],
            "subcategories": [subcategoryID],
            "includeInShuffle": true,
            "showInTopLevel": true,
            "preferredOrder": order,
            "pointsOfInterest": [String: Any](),
            "previewImage": item.thumbnailURL.absoluteString,
            "shotID": shotPrefix + String(item.id.uuidString.prefix(8)),
            "url-4K-SDR-240FPS": item.videoURL.absoluteString,
        ]
    }

    static func isOurs(_ asset: [String: Any]) -> Bool {
        if (asset["shotID"] as? String)?.hasPrefix(shotPrefix) == true { return true }
        return (asset["categories"] as? [String])?.contains(categoryID) == true
    }

    public static func containsCategory(_ data: Data) -> Bool {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let categories = root["categories"] as? [[String: Any]] else { return false }
        return categories.contains { ($0["id"] as? String) == categoryID }
    }

    public static func ourAssetIDs(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return [] }
        return assets.filter(isOurs).compactMap { $0["id"] as? String }
    }
}
