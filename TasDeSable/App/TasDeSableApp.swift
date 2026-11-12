import SwiftUI

/// Point d'entrée : crée les réglages et le modèle, puis les partage avec la fenêtre principale
/// et la page de réglages.
@main
struct TasDeSableApp: App {
    @State private var settings: AppSettings
    @State private var model: SimulationModel

    init() {
        let settings = AppSettings()
        _settings = State(initialValue: settings)
        _model = State(initialValue: SimulationModel(settings: settings))
    }

    var body: some Scene {
        WindowGroup("Tas de sable") {
            ContentView()
                .environment(settings)
                .environment(model)
                .environment(\.locale, settings.language.locale)
                .frame(minWidth: 900, minHeight: 600)
        }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(model)
                .environment(\.locale, settings.language.locale)
        }
    }
}
