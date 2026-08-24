//
//  ContentView.swift
//  SalmanMacCleaner
//
//  Root view: NavigationSplitView sidebar + detail. Search filters the sidebar
//  and every feature view receives the shared environment objects.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            DetailView(section: appState.section)
                .id(appState.section)
        }
        .navigationTitle(appState.section.title)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                ActivityToolbarView()
            }
        }
    }
}

private struct DetailView: View {
    let section: AppSection

    @ViewBuilder
    var body: some View {
        switch section {
        case .dashboard:
            DashboardView()
        case .largeFiles:
            LargeFilesView()
        case .duplicates:
            DuplicatesView()
        case .developerCaches:
            DeveloperCachesView()
        case .startupItems:
            StartupItemsView()
        case .uninstaller:
            UninstallerView()
        case .settings:
            SettingsView()
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
