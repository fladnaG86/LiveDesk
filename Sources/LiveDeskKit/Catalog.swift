import Foundation

public enum CatalogSource: String, CaseIterable, Codable, Sendable, Identifiable {
    case pexels
    case pixabay
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .pexels: return "Pexels"
        case .pixabay: return "Pixabay"
        case .custom: return "Il mio catalogo"
        }
    }

    public var requiresKey: Bool { self != .custom }

    /// Where to get a free API key.
    public var keySignupURL: URL? {
        switch self {
        case .pexels: return URL(string: "https://www.pexels.com/api/")
        case .pixabay: return URL(string: "https://pixabay.com/api/docs/")
        case .custom: return nil
        }
    }

    public var defaultLicense: String {
        switch self {
        case .pexels: return "Pexels License"
        case .pixabay: return "Pixabay Content License"
        case .custom: return ""
        }
    }
}

/// A downloadable wallpaper offered by a catalog.
public struct CatalogItem: Identifiable, Hashable, Sendable {
    /// "<source>:<provider id>"
    public var id: String
    public var source: CatalogSource
    public var title: String
    public var author: String?
    public var thumbnailURL: URL?
    public var previewURL: URL?
    public var downloadURL: URL
    public var width: Int
    public var height: Int
    public var duration: Double
    public var pageURL: URL?
    public var license: String

    public init(id: String, source: CatalogSource, title: String, author: String? = nil, thumbnailURL: URL? = nil,
                previewURL: URL? = nil, downloadURL: URL, width: Int, height: Int, duration: Double,
                pageURL: URL? = nil, license: String) {
        self.id = id
        self.source = source
        self.title = title
        self.author = author
        self.thumbnailURL = thumbnailURL
        self.previewURL = previewURL
        self.downloadURL = downloadURL
        self.width = width
        self.height = height
        self.duration = duration
        self.pageURL = pageURL
        self.license = license
    }

    public var resolutionLabel: String {
        let longSide = max(width, height)
        if longSide >= 3800 { return "4K" }
        if longSide >= 2500 { return "QHD" }
        if longSide >= 1900 { return "HD" }
        return "\(height)p"
    }

    /// Credit line stored with the downloaded wallpaper.
    public var credit: String {
        [author, source.displayName, license.isEmpty ? nil : license].compactMap { $0 }.joined(separator: " · ")
    }
}

public enum CatalogError: Error, LocalizedError, Equatable {
    case missingKey(CatalogSource)
    case missingCatalogURL
    case http(Int)
    case badResponse
    case insecureURL(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey(let s): return "Serve una API key \(s.displayName) (gratuita)."
        case .missingCatalogURL: return "Inserisci l'indirizzo del tuo catalog.json."
        case .http(401), .http(403): return "API key rifiutata dal server."
        case .http(429): return "Troppe richieste: riprova tra qualche minuto."
        case .http(let code): return "Errore del server (HTTP \(code))."
        case .badResponse: return "Risposta del catalogo non valida."
        case .insecureURL(let s): return "Indirizzo non sicuro (serve https): \(s)"
        }
    }
}

// MARK: - Parsing

public enum CatalogParsers {
    public static let maxDownloadWidth = 3840

    /// https only; relative strings resolve against `base`.
    public static func secureURL(_ string: String?, relativeTo base: URL? = nil) -> URL? {
        guard let string, !string.isEmpty, let url = URL(string: string, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }

    // Pexels

    private struct PexelsResponse: Decodable {
        struct Video: Decodable {
            struct User: Decodable { let name: String? }
            struct File: Decodable {
                let link: String
                let width: Int?
                let height: Int?
                let file_type: String?
            }
            let id: Int
            let width: Int?
            let height: Int?
            let duration: Double?
            let url: String?
            let image: String?
            let user: User?
            let video_files: [File]
        }
        let videos: [Video]
    }

    public static func pexels(_ data: Data) throws -> [CatalogItem] {
        guard let response = try? JSONDecoder().decode(PexelsResponse.self, from: data) else { throw CatalogError.badResponse }
        return response.videos.compactMap { video in
            let mp4 = video.video_files.filter { ($0.file_type ?? "").contains("mp4") && ($0.width ?? 0) > 0 }
            let best = mp4.filter { ($0.width ?? 0) <= maxDownloadWidth }.max { ($0.width ?? 0) < ($1.width ?? 0) }
            guard let best, let download = secureURL(best.link) else { return nil }
            let preview = mp4.filter { ($0.width ?? 0) >= 480 }.min { ($0.width ?? 0) < ($1.width ?? 0) } ?? best
            return CatalogItem(
                id: "pexels:\(video.id)", source: .pexels,
                title: titleFromPexelsPage(video.url) ?? "Pexels \(video.id)",
                author: video.user?.name,
                thumbnailURL: secureURL(video.image),
                previewURL: secureURL(preview.link),
                downloadURL: download,
                width: best.width ?? video.width ?? 0, height: best.height ?? video.height ?? 0,
                duration: video.duration ?? 0,
                pageURL: secureURL(video.url), license: CatalogSource.pexels.defaultLicense)
        }
    }

    /// "https://www.pexels.com/video/aerial-view-of-ocean-waves-1093662/" -> "Aerial view of ocean waves"
    public static func titleFromPexelsPage(_ page: String?) -> String? {
        guard let page, let url = URL(string: page) else { return nil }
        var words = url.lastPathComponent.split(separator: "-").map(String.init)
        if let last = words.last, last.allSatisfy(\.isNumber) { words.removeLast() }
        guard !words.isEmpty else { return nil }
        let text = words.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // Pixabay

    private struct PixabayResponse: Decodable {
        struct Hit: Decodable {
            struct Rendition: Decodable {
                let url: String
                let width: Int?
                let height: Int?
                let thumbnail: String?
            }
            let id: Int
            let pageURL: String?
            let tags: String?
            let duration: Double?
            let user: String?
            let videos: [String: Rendition]
        }
        let hits: [Hit]
    }

    public static func pixabay(_ data: Data) throws -> [CatalogItem] {
        guard let response = try? JSONDecoder().decode(PixabayResponse.self, from: data) else { throw CatalogError.badResponse }
        return response.hits.compactMap { hit in
            let order = ["large", "medium", "small", "tiny"]
            let renditions = order.compactMap { key -> (String, PixabayResponse.Hit.Rendition)? in
                guard let r = hit.videos[key], secureURL(r.url) != nil else { return nil }
                return (key, r)
            }
            guard let best = renditions.first(where: { ($0.1.width ?? 0) <= maxDownloadWidth })?.1,
                  let download = secureURL(best.url) else { return nil }
            let preview = hit.videos["tiny"].flatMap { secureURL($0.url) } ?? hit.videos["small"].flatMap { secureURL($0.url) }
            let thumb = hit.videos["medium"]?.thumbnail ?? hit.videos["large"]?.thumbnail ?? hit.videos["small"]?.thumbnail
            return CatalogItem(
                id: "pixabay:\(hit.id)", source: .pixabay,
                title: titleFromTags(hit.tags) ?? "Pixabay \(hit.id)",
                author: hit.user,
                thumbnailURL: secureURL(thumb),
                previewURL: preview,
                downloadURL: download,
                width: best.width ?? 0, height: best.height ?? 0,
                duration: hit.duration ?? 0,
                pageURL: secureURL(hit.pageURL), license: CatalogSource.pixabay.defaultLicense)
        }
    }

    /// "sea, waves, ocean, beach" -> "Sea, waves, ocean"
    public static func titleFromTags(_ tags: String?) -> String? {
        guard let tags else { return nil }
        let parts = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.prefix(3)
        guard !parts.isEmpty else { return nil }
        let text = parts.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    // Custom catalog.json

    private struct CustomCatalog: Decodable {
        struct Item: Decodable {
            let id: String?
            let title: String
            let author: String?
            let video: String
            let preview: String?
            let thumbnail: String?
            let width: Int?
            let height: Int?
            let duration: Double?
            let license: String?
            let page: String?
        }
        let name: String?
        let items: [Item]
    }

    /// Items with a non-https video are skipped. Relative URLs resolve against the catalog URL.
    public static func custom(_ data: Data, base: URL) throws -> [CatalogItem] {
        guard let catalog = try? JSONDecoder().decode(CustomCatalog.self, from: data) else { throw CatalogError.badResponse }
        return catalog.items.compactMap { item in
            guard let video = secureURL(item.video, relativeTo: base) else { return nil }
            return CatalogItem(
                id: "custom:\(item.id ?? video.absoluteString)", source: .custom,
                title: item.title, author: item.author,
                thumbnailURL: secureURL(item.thumbnail, relativeTo: base),
                previewURL: secureURL(item.preview, relativeTo: base),
                downloadURL: video,
                width: item.width ?? 0, height: item.height ?? 0, duration: item.duration ?? 0,
                pageURL: secureURL(item.page, relativeTo: base), license: item.license ?? "")
        }
    }

    public static func filter(_ items: [CatalogItem], query: String?) -> [CatalogItem] {
        let words = (query ?? "").lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let haystack = "\(item.title) \(item.author ?? "")".lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }
}

// MARK: - Client

public final class CatalogClient: Sendable {
    public static let pageSize = 30
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Builds the request for a provider page (exposed for tests).
    public static func request(source: CatalogSource, query: String?, page: Int, apiKey: String?, customURL: URL?) throws -> URLRequest {
        let text = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch source {
        case .pexels:
            guard let key = apiKey, !key.isEmpty else { throw CatalogError.missingKey(.pexels) }
            var c = URLComponents(string: text.isEmpty ? "https://api.pexels.com/videos/popular" : "https://api.pexels.com/videos/search")!
            var items = [URLQueryItem(name: "per_page", value: "\(pageSize)"), URLQueryItem(name: "page", value: "\(page)")]
            if text.isEmpty {
                items.append(URLQueryItem(name: "min_width", value: "1920"))
            } else {
                items += [URLQueryItem(name: "query", value: text), URLQueryItem(name: "orientation", value: "landscape"),
                          URLQueryItem(name: "size", value: "large")]
            }
            c.queryItems = items
            var r = URLRequest(url: c.url!)
            r.setValue(key, forHTTPHeaderField: "Authorization")
            return r
        case .pixabay:
            guard let key = apiKey, !key.isEmpty else { throw CatalogError.missingKey(.pixabay) }
            var c = URLComponents(string: "https://pixabay.com/api/videos/")!
            c.queryItems = [
                URLQueryItem(name: "key", value: key), URLQueryItem(name: "q", value: text),
                URLQueryItem(name: "page", value: "\(page)"), URLQueryItem(name: "per_page", value: "\(pageSize)"),
                URLQueryItem(name: "safesearch", value: "true"), URLQueryItem(name: "min_width", value: "1920"),
                URLQueryItem(name: "order", value: "popular"),
            ]
            return URLRequest(url: c.url!)
        case .custom:
            guard let customURL else { throw CatalogError.missingCatalogURL }
            guard customURL.scheme?.lowercased() == "https" else { throw CatalogError.insecureURL(customURL.absoluteString) }
            var r = URLRequest(url: customURL)
            r.cachePolicy = .reloadRevalidatingCacheData
            return r
        }
    }

    public func fetch(source: CatalogSource, query: String?, page: Int, apiKey: String?, customURL: URL?) async throws -> [CatalogItem] {
        if source == .custom && page > 1 { return [] } // a custom catalog is one file
        var request = try Self.request(source: source, query: query, page: page, apiKey: apiKey, customURL: customURL)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            // Pixabay answers 400 past the last page.
            if source == .pixabay && http.statusCode == 400 && page > 1 { return [] }
            throw CatalogError.http(http.statusCode)
        }
        switch source {
        case .pexels: return try CatalogParsers.pexels(data)
        case .pixabay: return try CatalogParsers.pixabay(data)
        case .custom: return CatalogParsers.filter(try CatalogParsers.custom(data, base: customURL!), query: query)
        }
    }
}
