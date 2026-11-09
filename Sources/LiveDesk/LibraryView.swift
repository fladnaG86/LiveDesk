import LiveDeskKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @State private var targetScreen: String? = nil
    @State private var filter: WallpaperKind? = nil
    @State private var importing = false
    @State private var dropTargeted = false

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    private var items: [Wallpaper] {
        model.store.wallpapers.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if items.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            WallpaperCard(model: model, item: item, targetScreen: targetScreen)
                        }
                    }
                    .padding(20)
                }
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                        .padding(8)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                model.importItems(urls)
                return true
            } isTargeted: { dropTargeted = $0 }
            footer
        }
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: [.movie, .video, .image, .folder],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importItems(urls) }
        }
        .alert("LiveDesk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: {
            Text(model.message ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Picker("Tipo", selection: $filter) {
                Text("Tutti").tag(WallpaperKind?.none)
                Text("Video").tag(WallpaperKind?.some(.video))
                Text("Scene").tag(WallpaperKind?.some(.scene))
                Text("Immagini").tag(WallpaperKind?.some(.image))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)

            Spacer()

            Picker("Applica a", selection: $targetScreen) {
                Text("Tutti gli schermi").tag(String?.none)
                ForEach(model.screens) { screen in
                    Text(screen.name).tag(String?.some(screen.id))
                }
            }
            .frame(maxWidth: 260)

            Button {
                model.togglePause()
            } label: {
                Label(model.isPaused ? "Riprendi" : "Pausa", systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }

            Button {
                importing = true
            } label: {
                Label("Importa", systemImage: "plus")
            }
            .keyboardShortcut("o")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack {
            if let reason = model.pauseSummary {
                Label("Fermo: \(reason)", systemImage: "pause.circle")
            } else {
                Label("In riproduzione", systemImage: "play.circle")
            }
            Spacer()
            lockScreenStatus
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var lockScreenStatus: some View {
        switch model.lockScreenStatus {
        case .idle:
            EmptyView()
        case .working(let text):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(text)
            }
        case .done(let count):
            Label("Blocco schermo: \(count) video nel catalogo di sistema", systemImage: "lock.display")
        case .failed(let text):
            Label(text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private var emptyState: some View {
        let text = Self.emptyText(for: filter)
        return VStack(spacing: 12) {
            Image(systemName: text.icon).font(.system(size: 48)).foregroundStyle(.secondary)
            Text(text.title).font(.title3)
            Text(text.hint).foregroundStyle(.secondary)
            if filter == .video {
                Button("Sfoglia Scopri") { model.selectedTab = .discover }
                    .buttonStyle(.link)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 360)
    }

    private static func emptyText(for filter: WallpaperKind?) -> (icon: String, title: String, hint: String) {
        switch filter {
        case .video:
            return ("film", "Nessun video",
                    "Trascina qui file .mov, .mp4 o .m4v, oppure scaricane uno da Scopri.")
        case .image:
            return ("photo", "Nessuna immagine",
                    "Trascina qui una foto (JPEG, PNG, HEIC) per usarla come sfondo fisso.")
        case .scene:
            return ("sparkles", "Nessuna scena",
                    "Trascina qui una cartella di scena con manifest.json.")
        case nil:
            return ("sparkles.tv", "Trascina qui video, immagini o cartelle di scene",
                    "Formati: .mov, .mp4, .m4v, immagini, cartelle con manifest.json")
        }
    }
}

struct WallpaperCard: View {
    @Bindable var model: AppModel
    let item: Wallpaper
    let targetScreen: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                // Fixed-size container: a .fill image would otherwise report its
                // natural width and spill over neighbouring grid columns.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .overlay { preview }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(model.isActive(item.id) ? Color.accentColor : Color.clear, lineWidth: 3)
                    )
                HStack(spacing: 4) {
                    if item.onLockScreen { badge("lock.fill") }
                    badge(icon)
                }
                .padding(8)
            }
            Text(item.title).font(.headline).lineLimit(1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .onHover { hovering = $0 }
        .onTapGesture { model.apply(item.id, screen: targetScreen) }
        .contextMenu {
            Button("Usa su tutti gli schermi") { model.apply(item.id, screen: nil) }
            ForEach(model.screens) { screen in
                Button("Usa su \(screen.name)") { model.apply(item.id, screen: screen.id) }
            }
            if item.kind == .video {
                Divider()
                Toggle("Mostra nel blocco schermo", isOn: Binding(
                    get: { item.onLockScreen },
                    set: { model.setOnLockScreen(item, $0) }
                ))
            }
            if let credit = item.credit {
                Divider()
                Text(credit)
                if let page = item.sourcePage.flatMap(URL.init(string:)) {
                    Button("Apri pagina originale") { NSWorkspace.shared.open(page) }
                }
            }
            if !item.isBuiltIn {
                Divider()
                Button("Mostra nel Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([model.store.url(for: item)])
                }
                Button("Rimuovi", role: .destructive) { model.remove(item) }
            }
        }
    }

    private var icon: String {
        switch item.kind {
        case .video: return "film"
        case .scene: return "sparkles"
        case .image: return "photo"
        }
    }

    private func badge(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption.weight(.semibold))
            .padding(6)
            .background(.ultraThinMaterial, in: Circle())
    }

    @ViewBuilder
    private var preview: some View {
        let _ = model.thumbnailVersion
        if let image = model.thumbnails.cachedImage(for: item.id) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
        } else {
            LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay(Image(systemName: icon).font(.largeTitle).foregroundStyle(.white.opacity(0.7)))
        }
    }

    private var gradient: [Color] {
        let palettes: [[Color]] = [[.purple, .blue], [.teal, .indigo], [.orange, .pink], [.mint, .cyan]]
        return palettes[item.paletteIndex(count: palettes.count)]
    }
}
