import AVFoundation
import Foundation
import Testing
@testable import LiveDeskKit

/// Shapes follow the public Pexels / Pixabay API docs (values made up).
let pexelsFixture = """
{"page":1,"per_page":2,"videos":[
 {"id":1093662,"width":3840,"height":2160,"duration":19,
  "url":"https://www.pexels.com/video/aerial-view-of-ocean-waves-1093662/",
  "image":"https://images.pexels.com/videos/1093662/free-video-1093662.jpg",
  "user":{"id":1,"name":"Jane Doe","url":"https://www.pexels.com/@jane"},
  "video_files":[
   {"id":1,"quality":"hd","file_type":"video/mp4","width":1920,"height":1080,"link":"https://videos.pexels.com/1093662/hd.mp4"},
   {"id":2,"quality":"uhd","file_type":"video/mp4","width":3840,"height":2160,"link":"https://videos.pexels.com/1093662/uhd.mp4"},
   {"id":3,"quality":"uhd","file_type":"video/mp4","width":5120,"height":2880,"link":"https://videos.pexels.com/1093662/5k.mp4"},
   {"id":4,"quality":"sd","file_type":"video/mp4","width":640,"height":360,"link":"https://videos.pexels.com/1093662/sd.mp4"},
   {"id":5,"quality":null,"file_type":"video/mp4","width":null,"height":null,"link":"https://videos.pexels.com/1093662/x.m3u8"}
  ]},
 {"id":7,"width":1280,"height":720,"duration":5,"url":"https://www.pexels.com/video/7/","image":"http://insecure.example/a.jpg",
  "user":{"name":"Bob"},
  "video_files":[{"id":9,"file_type":"video/mp4","width":1280,"height":720,"link":"http://insecure.example/a.mp4"}]}
]}
"""

let pixabayFixture = """
{"total":2,"totalHits":2,"hits":[
 {"id":125,"pageURL":"https://pixabay.com/videos/id-125/","type":"film","tags":"sea, waves, ocean, beach","duration":12,
  "videos":{
   "large":{"url":"https://cdn.pixabay.com/video/125/large.mp4","width":3840,"height":2160,"size":9000,"thumbnail":"https://cdn.pixabay.com/video/125/large.jpg"},
   "medium":{"url":"https://cdn.pixabay.com/video/125/medium.mp4","width":2560,"height":1440,"size":5000,"thumbnail":"https://cdn.pixabay.com/video/125/medium.jpg"},
   "small":{"url":"https://cdn.pixabay.com/video/125/small.mp4","width":1280,"height":720,"size":2000,"thumbnail":"https://cdn.pixabay.com/video/125/small.jpg"},
   "tiny":{"url":"https://cdn.pixabay.com/video/125/tiny.mp4","width":640,"height":360,"size":500,"thumbnail":"https://cdn.pixabay.com/video/125/tiny.jpg"}},
  "views":1,"downloads":1,"likes":1,"comments":0,"user_id":3,"user":"Alice","userImageURL":""},
 {"id":126,"pageURL":"https://pixabay.com/videos/id-126/","tags":"snow","duration":8,
  "videos":{
   "large":{"url":"","width":0,"height":0,"size":0,"thumbnail":""},
   "medium":{"url":"https://cdn.pixabay.com/video/126/medium.mp4","width":1920,"height":1080,"size":5000,"thumbnail":"https://cdn.pixabay.com/video/126/medium.jpg"},
   "small":{"url":"https://cdn.pixabay.com/video/126/small.mp4","width":1280,"height":720,"size":2000,"thumbnail":""},
   "tiny":{"url":"https://cdn.pixabay.com/video/126/tiny.mp4","width":640,"height":360,"size":500,"thumbnail":""}},
  "user":"Carl"}
]}
"""

let customFixture = """
{"name":"Miei sfondi","items":[
 {"id":"mare","title":"Mare d'inverno","author":"Io","video":"videos/mare.mp4","thumbnail":"thumbs/mare.jpg","preview":"https://cdn.example.com/p/mare.mp4","width":3840,"height":2160,"duration":20,"license":"CC0"},
 {"title":"Montagna","video":"https://cdn.example.com/montagna.mov"},
 {"title":"Insicuro","video":"http://cdn.example.com/x.mp4"}
]}
"""

struct CatalogParserTests {
    @Test func pexelsPicksBest4KAndSmallPreview() throws {
        let items = try CatalogParsers.pexels(Data(pexelsFixture.utf8))
        #expect(items.count == 1) // second video has only http links
        let a = items[0]
        #expect(a.id == "pexels:1093662")
        #expect(a.title == "Aerial view of ocean waves")
        #expect(a.author == "Jane Doe")
        #expect(a.downloadURL.absoluteString == "https://videos.pexels.com/1093662/uhd.mp4")
        #expect(a.previewURL?.absoluteString == "https://videos.pexels.com/1093662/sd.mp4")
        #expect(a.width == 3840 && a.resolutionLabel == "4K")
        #expect(a.pageURL?.host == "www.pexels.com")
        #expect(a.credit == "Jane Doe · Pexels · Pexels License")
    }

    @Test func pixabaySkipsEmptyLargeAndBuildsTitle() throws {
        let items = try CatalogParsers.pixabay(Data(pixabayFixture.utf8))
        #expect(items.count == 2)
        #expect(items[0].title == "Sea, waves, ocean")
        #expect(items[0].downloadURL.absoluteString.hasSuffix("/large.mp4"))
        #expect(items[0].previewURL?.absoluteString.hasSuffix("/tiny.mp4") == true)
        #expect(items[0].thumbnailURL?.absoluteString.hasSuffix("/medium.jpg") == true)
        #expect(items[1].downloadURL.absoluteString.hasSuffix("/medium.mp4"))
        #expect(items[1].resolutionLabel == "HD")
    }

    @Test func customResolvesRelativeAndRejectsHTTP() throws {
        let base = URL(string: "https://example.com/wall/catalog.json")!
        let items = try CatalogParsers.custom(Data(customFixture.utf8), base: base)
        #expect(items.map(\.title) == ["Mare d'inverno", "Montagna"])
        #expect(items[0].downloadURL.absoluteString == "https://example.com/wall/videos/mare.mp4")
        #expect(items[0].thumbnailURL?.absoluteString == "https://example.com/wall/thumbs/mare.jpg")
        #expect(items[0].id == "custom:mare")
        #expect(items[1].id == "custom:https://cdn.example.com/montagna.mov")
        #expect(items[0].license == "CC0")
    }

    @Test func filterMatchesAllWords() throws {
        let items = try CatalogParsers.custom(Data(customFixture.utf8), base: URL(string: "https://e.com/c.json")!)
        #expect(CatalogParsers.filter(items, query: "mare inverno").count == 1)
        #expect(CatalogParsers.filter(items, query: "io").map(\.title) == ["Mare d'inverno"])
        #expect(CatalogParsers.filter(items, query: "").count == 2)
        #expect(CatalogParsers.filter(items, query: "deserto").isEmpty)
    }

    @Test func badJSONThrows() {
        #expect(throws: CatalogError.badResponse) { try CatalogParsers.pexels(Data("{}".utf8)) }
        #expect(throws: CatalogError.badResponse) { try CatalogParsers.pixabay(Data("nope".utf8)) }
    }

    @Test func secureURL() {
        #expect(CatalogParsers.secureURL("https://a.com/x.mp4") != nil)
        #expect(CatalogParsers.secureURL("http://a.com/x.mp4") == nil)
        #expect(CatalogParsers.secureURL("file:///etc/passwd") == nil)
        #expect(CatalogParsers.secureURL("../x.mp4", relativeTo: URL(string: "https://a.com/c/d.json")!)?.absoluteString == "https://a.com/x.mp4")
        #expect(CatalogParsers.secureURL("") == nil)
    }
}

struct CatalogRequestTests {
    @Test func pexelsRequests() throws {
        #expect(throws: CatalogError.missingKey(.pexels)) {
            try CatalogClient.request(source: .pexels, query: nil, page: 1, apiKey: nil, customURL: nil)
        }
        let popular = try CatalogClient.request(source: .pexels, query: " ", page: 2, apiKey: "K", customURL: nil)
        #expect(popular.url?.path == "/videos/popular")
        #expect(popular.value(forHTTPHeaderField: "Authorization") == "K")
        #expect(popular.url?.query?.contains("page=2") == true)
        let search = try CatalogClient.request(source: .pexels, query: "mare calmo", page: 1, apiKey: "K", customURL: nil)
        #expect(search.url?.path == "/videos/search")
        #expect(search.url?.query?.contains("query=mare%20calmo") == true)
    }

    @Test func pixabayRequest() throws {
        let r = try CatalogClient.request(source: .pixabay, query: "neve", page: 3, apiKey: "P", customURL: nil)
        let q = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(q.first { $0.name == "key" }?.value == "P")
        #expect(q.first { $0.name == "q" }?.value == "neve")
        #expect(q.first { $0.name == "page" }?.value == "3")
        #expect(q.first { $0.name == "safesearch" }?.value == "true")
    }

    @Test func officialNeedsNothing() throws {
        let r = try CatalogClient.request(source: .official, query: "x", page: 1, apiKey: nil, customURL: nil)
        #expect(r.url == CatalogSource.officialCatalogURL)
        #expect(!CatalogSource.official.requiresKey)
        #expect(CatalogSource.official.isCatalogFile)
    }

    @Test func officialCatalogInRepoParses() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("catalog/catalog.json")
        let items = try CatalogParsers.custom(Data(contentsOf: url), base: CatalogSource.officialCatalogURL, source: .official)
        #expect(items.count == 10)
        #expect(items.allSatisfy { $0.license == "CC0" && $0.width == 3840 && $0.id.hasPrefix("official:") })
        #expect(items.allSatisfy { $0.downloadURL.host == "github.com" && $0.previewURL != nil && $0.thumbnailURL != nil })
    }

    @Test func customRequiresHTTPS() throws {
        #expect(throws: CatalogError.missingCatalogURL) {
            try CatalogClient.request(source: .custom, query: nil, page: 1, apiKey: nil, customURL: nil)
        }
        #expect(throws: CatalogError.insecureURL("http://a.com/c.json")) {
            try CatalogClient.request(source: .custom, query: nil, page: 1, apiKey: nil, customURL: URL(string: "http://a.com/c.json"))
        }
        #expect(try CatalogClient.request(source: .custom, query: nil, page: 1, apiKey: nil, customURL: URL(string: "https://a.com/c.json")).url != nil)
    }
}

struct DownloadHelperTests {
    @Test func extensions() {
        let u = URL(string: "https://a.com/v")!
        #expect(DownloadManager.fileExtension(mime: "video/mp4", url: u) == "mp4")
        #expect(DownloadManager.fileExtension(mime: "video/quicktime", url: u) == "mov")
        #expect(DownloadManager.fileExtension(mime: "application/octet-stream", url: URL(string: "https://a.com/x.MP4")!) == "mp4")
        #expect(DownloadManager.fileExtension(mime: "text/html", url: u) == nil)
    }

    @Test func safeNames() {
        #expect(DownloadManager.safeFileName("Mare / Onde: 4K") == "Mare _ Onde_ 4K")
        #expect(DownloadManager.safeFileName("../../etc") == "______etc")
        #expect(DownloadManager.safeFileName("   ") == "wallpaper")
    }
}

@MainActor
struct LibraryCatalogTests {
    @Test func annotateAndLookup() throws {
        let store = LibraryStore(root: makeTempDir(), builtInScenesRoot: nil)
        let src = makeTempDir().appendingPathComponent("tmp.mp4")
        try Data([1]).write(to: src)
        let w = try store.importItem(at: src)
        store.annotate(id: w.id, title: "Mare", credit: "Jane · Pexels", sourcePage: "https://p/x", catalogID: "pexels:1")
        #expect(store.wallpaper(catalogID: "pexels:1")?.title == "Mare")

        let reloaded = LibraryStore(root: store.root, builtInScenesRoot: nil)
        #expect(reloaded.wallpaper(catalogID: "pexels:1")?.credit == "Jane · Pexels")

        store.setCustomCatalogURL("  https://a.com/c.json ")
        #expect(store.state.customCatalogURL == "https://a.com/c.json")
        store.setCustomCatalogURL("")
        #expect(store.state.customCatalogURL == nil)
    }
}

/// Real network download. Run with: TEST_RUNNER_LIVEDESK_NET=1 xcodebuild … test
@MainActor
struct DownloadIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVEDESK_NET"] == "1"))
    func downloadsPublicVideo() async throws {
        let item = CatalogItem(id: "custom:bbb", source: .custom, title: "Big Buck Bunny / test",
                               downloadURL: URL(string: "https://www.w3schools.com/html/mov_bbb.mp4")!,
                               width: 320, height: 176, duration: 10, license: "CC BY 3.0")
        let manager = DownloadManager()
        let file = try await manager.download(item, to: makeTempDir())
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int ?? 0
        #expect(file.lastPathComponent == "Big Buck Bunny _ test.mp4")
        #expect(size > 100_000)
        #expect(manager.states[item.id] == nil)
    }
}

/// Real network: the published official collection. Run with TEST_RUNNER_LIVEDESK_NET=1.
@MainActor
struct OfficialCollectionIntegrationTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVEDESK_NET"] == "1"))
    func fetchPreviewAndDownload() async throws {
        let items = try await CatalogClient().fetch(source: .official, query: nil, page: 1, apiKey: nil, customURL: nil)
        #expect(items.count == 10)
        let item = try #require(items.min { $0.title < $1.title }) // smallest-ish, deterministic
        let cache = PreviewCache(folder: makeTempDir())
        let localPreview = try await cache.localFile(for: try #require(item.previewURL))
        #expect(localPreview.pathExtension == "mp4")
        #expect(try await AVURLAsset(url: localPreview).load(.isPlayable))
        #expect(try await cache.localFile(for: item.previewURL!) == localPreview) // cached
        let file = try await DownloadManager().download(item, to: makeTempDir())
        #expect(file.pathExtension == "mov")
        let local = AVURLAsset(url: file)
        #expect(try await local.load(.isPlayable))
        let size = try await local.loadTracks(withMediaType: .video).first!.load(.naturalSize)
        #expect(size == CGSize(width: 3840, height: 2160))
    }
}
