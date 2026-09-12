import SwiftUI
import AppIntents

@main
struct AgendaBlocchiApp: App {
    init() {
        AgendaAppShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
