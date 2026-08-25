//
//  SalmanMacCleanerApp.swift
//  SalmanMacCleaner
//
//  App entry point: Aurora window sizing, shared environment objects,
//  appearance preference and native menu commands (including
//  "Check for Updates…").
//

import SwiftUI
import AppKit

@main
struct SalmanMacCleanerApp: App {
    @StateObject private var appState = AppState()
    @StateObject private var accessibility = AccessibilityEnvironment.shared
    @StateObject private var permissionService = PermissionService.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(accessibility)
                .environmentObject(permissionService)
                .frame(minWidth: 1100, minHeight: 720)
                .preferredColorScheme(appState.settings.appearance.colorScheme)
        }
        .defaultSize(width: 1440, height: 900)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button(NSLocalizedString("menu.check_updates", comment: "")) {
                    SparkleUpdaterController.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command])
            }
            CommandGroup(after: .appTermination) {
                Button(NSLocalizedString("menu.smart_care", comment: "")) {
                    appState.module = .smartCare
                }
                .keyboardShortcut("1", modifiers: [.command])
                Button(NSLocalizedString("menu.deep_scan", comment: "")) {
                    appState.module = .deepScan
                }
                .keyboardShortcut("2", modifiers: [.command])
            }
            CommandGroup(replacing: .help) {
                Button(NSLocalizedString("menu.readme", comment: "")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/8002salman-ai/SalmanMacCleaner")!)
                }
            }
        }
    }
}
