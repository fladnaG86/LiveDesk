import AppKit
import LiveDeskKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.coordinator.stop()
    }
}

@main
struct LiveDeskApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("LiveDesk", systemImage: "sparkles.tv") {
            MenuContent(model: delegate.model)
        }
        Window("LiveDesk", id: "library") {
            TabView {
                LibraryView(model: delegate.model)
                    .tabItem { Label("Libreria", systemImage: "square.grid.2x2") }
                DiscoverView(model: delegate.model)
                    .tabItem { Label("Scopri", systemImage: "sparkle.magnifyingglass") }
            }
            .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.presented)
        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

struct MenuContent: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Apri libreria…") {
            openWindow(id: "library")
            NSApp.activate()
        }
        .keyboardShortcut("l")
        Button(model.isPaused ? "Riprendi" : "Metti in pausa") { model.togglePause() }
            .keyboardShortcut("p")
        if let reason = model.pauseSummary, !model.isPaused {
            Text("Fermo: \(reason)")
        }
        Divider()
        Menu("Sfondo") {
            ForEach(model.store.wallpapers) { item in
                Button(item.title) { model.apply(item.id, screen: nil) }
            }
        }
        SettingsLink { Text("Impostazioni…") }
            .keyboardShortcut(",")
        Divider()
        Button("Esci da LiveDesk") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
