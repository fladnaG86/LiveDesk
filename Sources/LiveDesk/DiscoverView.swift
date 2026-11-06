import AVFoundation
import LiveDeskKit
import SwiftUI

/// Browse / search state for the Discover tab.
@MainActor
@Observable
final class DiscoverModel {
    let client = CatalogClient()
    let downloads = DownloadManager()

    var source: CatalogSource = .pexels
    var query = ""
    private(set) var items: [CatalogItem] = []
    private(set) var loading = false
    private(set) var hasMore = true
    var error: String?
    private var page = 1
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// Bumped when keys change so views re-read them.
    private(set) var keysVersion = 0

    func apiKey(for source: CatalogSource) -> String? {
        _ = keysVersion
        return Keychain.get(source.rawValue)
    }

    func setAPIKey(_ key: String, for source: CatalogSource) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: source.rawValue)
        keysVersion += 1
    }

    func needsSetup(customURL: String?) -> Bool {
        source.requiresKey ? (apiKey(for: source) ?? "").isEmpty : (customURL ?? "").isEmpty
    }

    func reload(customURL: String?) {
        loadTask?.cancel()
        items = []
        page = 1
        hasMore = true
        error = nil
        loadMore(customURL: customURL)
    }

    func loadMore(customURL: String?) {
        guard !loading, hasMore, !needsSetup(customURL: customURL) else { return }
        loading = true
        let source = self.source, query = self.query, page = self.page
        let key = apiKey(for: source)
        let url = customURL.flatMap(URL.init(string:))
        loadTask = Task {
            defer { loading = false }
            do {
                let result = try await client.fetch(source: source, query: query, page: page, apiKey: key, customURL: url)
                guard !Task.isCancelled, source == self.source else { return }
                let known = Set(items.map(\.id))
                items += result.filter { !known.contains($0.id) }
                self.page += 1
                hasMore = source != .custom && result.count >= CatalogClient.pageSize / 2
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.error = error.localizedDescription
                hasMore = false
            }
        }
    }
}

struct DiscoverView: View {
    @Bindable var model: AppModel
    private var discover: DiscoverModel { model.discover }
    @State private var keyDraft = ""
    @State private var urlDraft = ""

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 340), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if discover.needsSetup(customURL: model.store.state.customCatalogURL) {
                setup
            } else {
                results
            }
            Divider()
            footer
        }
        .onAppear {
            if discover.items.isEmpty { discover.reload(customURL: model.store.state.customCatalogURL) }
        }
        .onChange(of: discover.source) {
            keyDraft = ""
            discover.reload(customURL: model.store.state.customCatalogURL)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Fonte", selection: Bindable(discover).source) {
                ForEach(CatalogSource.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Cerca: mare, città, neve, astratto…", text: Bindable(discover).query)
                    .textFieldStyle(.plain)
                    .onSubmit { discover.reload(customURL: model.store.state.customCatalogURL) }
                if !discover.query.isEmpty {
                    Button {
                        discover.query = ""
                        discover.reload(customURL: model.store.state.customCatalogURL)
                    } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

            Menu {
                Button("Cambia API key / indirizzo…") { forgetSetup() }
            } label: {
                Image(systemName: "key")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func forgetSetup() {
        if discover.source.requiresKey {
            keyDraft = discover.apiKey(for: discover.source) ?? ""
            discover.setAPIKey("", for: discover.source)
        } else {
            urlDraft = model.store.state.customCatalogURL ?? ""
            model.store.setCustomCatalogURL(nil)
        }
    }

    // MARK: Setup

    @ViewBuilder
    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            if discover.source.requiresKey {
                Text("Collega \(discover.source.displayName)").font(.title2.bold())
                Text("\(discover.source.displayName) offre migliaia di video gratuiti con licenza libera. Serve una API key gratuita: registrati, copia la chiave e incollala qui. Viene salvata nel Portachiavi.")
                    .foregroundStyle(.secondary)
                if let url = discover.source.keySignupURL {
                    Link("Ottieni la chiave su \(url.host ?? "")", destination: url)
                }
                HStack {
                    SecureField("API key", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 420)
                        .onSubmit(saveKey)
                    Button("Salva", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Text("Il tuo catalogo").font(.title2.bold())
                Text("Indirizzo https di un file catalog.json con i tuoi video. Formato:")
                    .foregroundStyle(.secondary)
                Text(#"{"name": "Miei sfondi", "items": [{"id": "mare-1", "title": "Mare", "video": "videos/mare.mp4", "thumbnail": "thumbs/mare.jpg", "preview": "previews/mare.mp4", "author": "Io", "license": "CC0"}]}"#)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Text("I percorsi relativi partono dalla cartella del catalog.json.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("https://…/catalog.json", text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 520)
                        .onSubmit(saveURL)
                    Button("Salva", action: saveURL)
                        .disabled(!urlDraft.lowercased().hasPrefix("https://"))
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func saveKey() {
        discover.setAPIKey(keyDraft, for: discover.source)
        keyDraft = ""
        discover.reload(customURL: model.store.state.customCatalogURL)
    }

    private func saveURL() {
        model.store.setCustomCatalogURL(urlDraft)
        discover.reload(customURL: model.store.state.customCatalogURL)
    }

    // MARK: Results

    private var results: some View {
        ScrollView {
            if let error = discover.error, discover.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                    Text(error)
                    Button("Riprova") { discover.reload(customURL: model.store.state.customCatalogURL) }
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else if discover.items.isEmpty && !discover.loading {
                Text("Nessun risultato").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 320)
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(discover.items) { item in
                    DiscoverCard(model: model, item: item)
                        .onAppear {
                            if item.id == discover.items.last?.id {
                                discover.loadMore(customURL: model.store.state.customCatalogURL)
                            }
                        }
                }
            }
            .padding(20)
            if discover.loading {
                ProgressView().padding()
            }
        }
    }

    private var footer: some View {
        HStack {
            switch discover.source {
            case .pexels:
                Link("Video forniti da Pexels", destination: URL(string: "https://www.pexels.com")!)
            case .pixabay:
                Link("Video forniti da Pixabay", destination: URL(string: "https://pixabay.com")!)
            case .custom:
                Text(model.store.state.customCatalogURL ?? "")
            }
            Spacer()
            Text("\(discover.items.count) video").monospacedDigit()
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

struct DiscoverCard: View {
    @Bindable var model: AppModel
    let item: CatalogItem
    @State private var hovering = false

    private var downloaded: Wallpaper? { model.store.wallpaper(catalogID: item.id) }
    private var state: DownloadManager.State? { model.discover.downloads.states[item.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                ZStack {
                    AsyncImage(url: item.thumbnailURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary)
                    }
                    if hovering, let preview = item.previewURL {
                        LoopingVideoView(url: preview).transition(.opacity)
                    }
                }
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 6) {
                    tag(item.resolutionLabel)
                    if item.duration > 0 { tag(Self.duration(item.duration)) }
                }
                .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                if downloaded != nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, .green)
                        .padding(8)
                }
            }

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Text(item.author ?? item.source.displayName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                action
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .contextMenu {
            if let page = item.pageURL {
                Button("Apri su \(item.source.displayName)") { NSWorkspace.shared.open(page) }
            }
            Text(item.credit)
        }
    }

    @ViewBuilder
    private var action: some View {
        if let downloaded {
            Button("Usa") { model.apply(downloaded.id, screen: nil) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        } else if case .downloading(let fraction) = state {
            HStack(spacing: 6) {
                ProgressView(value: fraction).frame(width: 60)
                Button { model.discover.downloads.cancel(item.id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Annulla")
            }
        } else {
            Button {
                Task { await model.download(item, apply: true) }
            } label: {
                Label(state == nil ? "Scarica" : "Riprova", systemImage: "arrow.down.circle")
            }
            .controlSize(.small)
            .help(stateHelp)
        }
    }

    private var stateHelp: String {
        if case .failed(let message) = state { return message }
        return "Scarica e usa come sfondo"
    }

    private func tag(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Muted looping preview used on hover.
struct LoopingVideoView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PlayerNSView { PlayerNSView(url: url) }
    func updateNSView(_ view: PlayerNSView, context: Context) {}
    static func dismantleNSView(_ view: PlayerNSView, coordinator: ()) { view.stop() }

    final class PlayerNSView: NSView {
        private let player = AVQueuePlayer()
        private var looper: AVPlayerLooper?
        private let playerLayer = AVPlayerLayer()

        init(url: URL) {
            super.init(frame: .zero)
            wantsLayer = true
            player.isMuted = true
            playerLayer.player = player
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
            player.play()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }

        func stop() {
            player.pause()
            looper?.disableLooping()
            player.removeAllItems()
        }
    }
}
