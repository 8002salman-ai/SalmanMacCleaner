//
//  SalmanMacCleanerApp.swift
//  SalmanMacCleaner
//
//  App entry point. Installs the shared AppState and applies the user's
//  appearance preference.
//

import SwiftUI

@main
struct SalmanMacCleanerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1000, minHeight: 660)
                .preferredColorScheme(appState.settings.appearance.colorScheme)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(NSLocalizedString("menu.dashboard", comment: "")) {
                    appState.section = .dashboard
                }
                .keyboardShortcut("1", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button(NSLocalizedString("menu.readme", comment: "")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/8002salman-ai/SalmanMacCleaner")!)
                }
            }
        }
    }
}
