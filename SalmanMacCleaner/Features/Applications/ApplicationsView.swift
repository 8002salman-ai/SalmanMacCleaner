//
//  ApplicationsView.swift
//  SalmanMacCleaner
//
//  Application inventory: real discovery from /Applications, ~/Applications
//  and /System/Applications (read-only), deduplicated by canonical path and
//  bundle identifier, with architecture, signing, quarantine and size data.
//

import SwiftUI
import AppKit

struct ApplicationsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apps: [AppRecord] = []
    @State private var isLoading = false
    @State private var heroMode = true
    @State private var searchText = ""
    @State private var systemAppsShown = false

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .applications,
                    isBusy: isLoading,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.applications.scope", comment: ""),
                    primaryAction: {
                        heroMode = false
                        load()
                    },
                    selectors: { EmptyView() }
                )
                .task { load() }
            } else if isLoading && apps.isEmpty {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("apps.scanning")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                workspace
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(String(format: NSLocalizedString("apps.summary", comment: ""), filteredApps.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("apps.show_system", isOn: $systemAppsShown)
                    .toggleStyle(.checkbox)
                    .font(.callout)
                Spacer()
                Button("apps.refresh") { load() }
                    .buttonStyle(AuroraSecondaryButtonStyle())
            }
            List(filteredApps) { app in
                AppInventoryRow(app: app)
            }
            .listStyle(.inset)
        }
        .padding(24)
        .searchable(text: $searchText, prompt: Text("uninstaller.search.prompt"))
    }

    private var filteredApps: [AppRecord] {
        var filtered = apps.filter { systemAppsShown || !$0.isSystemApp }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return filtered
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let found = ApplicationInventoryService.discoverApplications()
            await MainActor.run {
                apps = found
                isLoading = false
            }
        }
    }
}

struct AppInventoryRow: View {
    let app: AppRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                .resizable()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text((app.bundleID ?? "—") + (app.version.map { " · v\($0)" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if app.isSystemApp {
                StatusPill("apps.system_app", kind: .unavailable)
            }
            if app.isRunning {
                StatusPill("apps.running", kind: .info)
            }
            if app.isQuarantined {
                StatusPill("apps.quarantined", kind: .warning)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(app.architectures.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(FileUtilities.formattedBytes(app.bundleSize))
                    .font(.callout.monospacedDigit())
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contextMenu {
            Button("results.reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.bundlePath)])
            }
            if !app.isSystemApp {
                Button("apps.open_in_uninstaller") {
                    AppStateLocator.shared?.module = .uninstaller
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Small indirection so row context menus can navigate to the Uninstaller.
@MainActor
public final class AppStateLocator {
    public static weak var shared: AppState?
    private init() {}
}
