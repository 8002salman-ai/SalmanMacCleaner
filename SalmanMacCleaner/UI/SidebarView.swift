//
//  SidebarView.swift
//  SalmanMacCleaner
//
//  Sidebar with search field and navigation sections. Selection is driven by
//  the shared AppState.section value, so the detail column always follows the
//  sidebar.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        List(selection: $appState.section) {
            Section(NSLocalizedString("sidebar.section.tools", comment: "")) {
                ForEach(primarySections) { section in
                    Label {
                        Text(section.title)
                    } icon: {
                        Image(systemName: section.systemImage)
                            .foregroundStyle(Color.accentColor)
                    }
                    .badge(section.permissionBadge.map { Text($0) })
                    .tag(section)
                }
            }

            Section(NSLocalizedString("sidebar.section.manage", comment: "")) {
                ForEach(secondarySections) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $appState.sidebarSearchText, placement: .sidebar, prompt: Text("search.sidebar.prompt"))
        .navigationTitle("app.name")
        .safeAreaInset(edge: .bottom) {
            DryRunBadge()
                .padding(8)
        }
    }

    private var primarySections: [AppSection] {
        [.dashboard, .largeFiles, .duplicates, .developerCaches]
    }

    private var secondarySections: [AppSection] {
        [.startupItems, .uninstaller, .settings]
    }
}

/// Compact dry-run status badge pinned under the sidebar.
struct DryRunBadge: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: appState.settings.dryRun ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .foregroundStyle(appState.settings.dryRun ? Color.green : Color.orange)
            Text(LocalizedStringKey(appState.settings.dryRun ? "badge.dry_run_on" : "badge.dry_run_off"))
                .font(.caption)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.quaternary, in: Capsule())
        .help(Text(LocalizedStringKey(appState.settings.dryRun ? "badge.dry_run_on.help" : "badge.dry_run_off.help")))
    }
}
