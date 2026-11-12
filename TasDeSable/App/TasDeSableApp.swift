import AppKit
import SwiftUI

/// Délégué AppKit : l'application se termine quand sa dernière fenêtre est fermée.
///
/// `applicationShouldTerminateAfterLastWindowClosed` ne suffit pas avec SwiftUI, qui garde des
/// fenêtres internes : à chaque fermeture, on vérifie donc qu'il reste une fenêtre visible.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil,
                                               queue: .main) { notification in
            let closing = notification.object as? NSWindow
            // La fenêtre est encore visible pendant willClose : on vérifie au tour suivant.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let remaining = NSApp.windows.filter {
                        $0 !== closing && $0.isVisible && !($0 is NSPanel) && $0.canBecomeMain
                    }
                    if remaining.isEmpty { NSApp.terminate(nil) }
                }
            }
        }
    }
}

/// Point d'entrée : crée les réglages et le modèle, puis les partage avec la fenêtre principale
/// et la page de réglages.
@main
struct TasDeSableApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
