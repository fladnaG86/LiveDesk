import LiveDeskKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    private func binding<T>(_ keyPath: WritableKeyPath<PlaybackSettings, T>) -> Binding<T> {
        Binding(
            get: { model.store.settings[keyPath: keyPath] },
            set: { value in model.updateSettings { $0[keyPath: keyPath] = value } }
        )
    }

    var body: some View {
        TabView {
            Form {
                Section("Riproduzione") {
                    LabeledContent("Velocità") {
                        HStack {
                            Slider(value: binding(\.speed), in: 0.25...2, step: 0.25)
                            Text(String(format: "%.2g×", model.store.settings.speed)).monospacedDigit().frame(width: 44)
                        }
                    }
                    Picker("Cambia sfondo ogni", selection: binding(\.rotationMinutes)) {
                        Text("Mai").tag(0)
                        Text("15 minuti").tag(15)
                        Text("1 ora").tag(60)
                        Text("1 giorno").tag(1440)
                    }
                    Toggle("Avvia al login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                }
                Section("Risparmio energetico") {
                    Toggle("Pausa a batteria", isOn: binding(\.pauseOnBattery))
                    Toggle("Pausa in modalità basso consumo", isOn: binding(\.pauseInLowPowerMode))
                    Toggle("Pausa quando una finestra copre lo schermo", isOn: binding(\.pauseWhenCovered))
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Generali", systemImage: "gearshape") }

            Form {
                Section("Scene") {
                    LabeledContent("Qualità") {
                        Slider(value: binding(\.sceneQuality), in: 0.25...1, step: 0.25)
                    }
                    Picker("Fotogrammi al secondo", selection: binding(\.sceneFPS)) {
                        Text("30").tag(30)
                        Text("60").tag(60)
                        Text("120").tag(120)
                    }
                    Toggle("Reagisci all'audio del Mac", isOn: binding(\.audioReactive))
                    Text("Le scene audio ascoltano il suono riprodotto dal Mac. Al primo uso macOS chiede il permesso.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Scene", systemImage: "sparkles") }

            Form {
                Section("Blocco schermo") {
                    Toggle("Mostra i video LiveDesk nel blocco schermo", isOn: Binding(
                        get: { model.store.settings.lockScreenSync },
                        set: { model.setLockScreenSync($0) }
                    ))
                    .disabled(!model.lockScreenAvailable)
                    Text("Copia i video segnati con il lucchetto nel catalogo Aerial di macOS, nella categoria «LiveDesk». Poi scegli il video in Impostazioni > Sfondo: macOS lo usa per blocco schermo e salvaschermo.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !model.lockScreenAvailable {
                        Text("Catalogo Aerial non trovato: apri Impostazioni > Sfondo una volta.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("Risincronizza") { model.syncLockScreen() }
                            .disabled(!model.store.settings.lockScreenSync)
                        Button("Apri Impostazioni Sfondo") { model.openWallpaperSettings() }
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Blocco schermo", systemImage: "lock.display") }
        }
        .frame(width: 520, height: 400)
    }
}
