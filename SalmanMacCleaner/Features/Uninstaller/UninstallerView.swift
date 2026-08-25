//
//  UninstallerView.swift
//  SalmanMacCleaner
//
//  Full application uninstaller: all removable installed applications (not
//  just ~/Applications), exact bundle-id/container/preference-domain resource
//  matching, running-app protection, review plan, trash-only removal and
//  history recording. System apps are never offered.
//

import SwiftUI
import AppKit

struct UninstallerView: View {
    @EnvironmentObject private var appState: AppState
    @State private var apps: [AppRecord] = []
    @State private var selectedApp: AppRecord?
    @State private var matchedItems: [ScannedItem] = []
    @State private var isLoading = false
    @State private var heroMode = true
    @State private var searchText = ""
    @State private var selectedPaths: Set<String> = []
    @State private var showConfirmation = false
    @State private var isQuitting = false

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .uninstaller,
                    isBusy: isLoading,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.uninstaller.scope", comment: ""),
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

    private var removableApps: [AppRecord] {
        var filtered = apps.filter { !$0.isSystemApp }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return filtered
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            // App list
            VStack(alignment: .leading, spacing: 8) {
                Text(String(format: NSLocalizedString("uninstaller.removable_count", comment: ""), removableApps.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                List(removableApps) { app in
                    Button {
                        select(app)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.name)
                                    .font(.callout)
                                    .lineLimit(1)
                                Text(FileUtilities.formattedBytes(app.bundleSize))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.isRunning {
                                Image(systemName: "play.circle.fill")
                                    .foregroundStyle(AuroraPalette.amber)
                            }
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(selectedApp?.bundlePath == app.bundlePath ? AuroraPalette.electricPurple.opacity(0.15) : Color.clear)
                }
                .listStyle(.inset)
            }
            .frame(width: 360)

            Divider().overlay(Color.white.opacity(0.08))

            // Detail
            detailPane
                .frame(maxWidth: .infinity)
        }
        .searchable(text: $searchText, prompt: Text("uninstaller.search.prompt"))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let app = selectedApp {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundlePath))
                        .resizable()
                        .frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name)
                            .font(.title2.weight(.bold))
                        Text((app.bundleID ?? "—") + (app.version.map { " · v\($0)" } ?? ""))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(app.bundlePath)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(FileUtilities.formattedBytes(app.bundleSize))
                        .font(.headline.monospacedDigit())
                }

                if app.isRunning {
                    PermissionBannerView(
                        message: NSLocalizedString("uninstaller.running_warning", comment: ""),
                        systemImage: "play.circle.fill"
                    )
                }

                // Bundle row (always included) + matched components.
                VStack(alignment: .leading, spacing: 6) {
                    Text("uninstaller.components")
                        .font(.subheadline.weight(.semibold))
                    Toggle(isOn: bundleToggle) {
                        HStack(spacing: 8) {
                            Image(systemName: "app.fill")
                            Text("uninstaller.bundle_row")
                            Spacer()
                            Text(FileUtilities.formattedBytes(app.bundleSize))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                    ForEach(matchedItems) { item in
                        Toggle(isOn: binding(for: item.path)) {
                            HStack(spacing: 8) {
                                Image(systemName: item.isDirectory ? "folder" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(item.path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(FileUtilities.formattedBytes(item.size))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    if matchedItems.isEmpty {
                        Text("uninstaller.no_components")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    if app.isRunning {
                        Button {
                            quitAndReselect(app)
                        } label: {
                            Label("uninstaller.quit_app", systemImage: "stop.circle")
                        }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                        .disabled(isQuitting)
                    }
                    Spacer()
                    Button("results.preview_cleanup") { showConfirmation = true }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                    Button("uninstaller.uninstall") { showConfirmation = true }
                        .buttonStyle(AuroraPrimaryButtonStyle())
                        .disabled(appState.settings.dryRun || app.isRunning)
                }
            }
            .padding(24)
        } else {
            EmptyStateView(
                systemImage: "app.badge",
                title: "uninstaller.select_app",
                message: "uninstaller.select_app.message"
            )
        }
    }

    private var bundleToggle: Binding<Bool> {
        Binding(
            get: { selectedApp.map { selectedPaths.contains($0.bundlePath) } ?? false },
            set: { on in
                guard let app = selectedApp else { return }
                if on { selectedPaths.insert(app.bundlePath) } else { selectedPaths.remove(app.bundlePath) }
            }
        )
    }

    private func binding(for path: String) -> Binding<Bool> {
        Binding(
            get: { selectedPaths.contains(path) },
            set: { on in
                if on { selectedPaths.insert(path) } else { selectedPaths.remove(path) }
            }
        )
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

    private func select(_ app: AppRecord) {
        selectedApp = app
        selectedPaths = [app.bundlePath]
        Task.detached(priority: .userInitiated) {
            let items = ResidualCorrelationEngine.supportRoots().flatMap { root -> [ScannedItem] in
                guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: URL(fileURLWithPath: root, isDirectory: true),
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { return [] }
                return entries.compactMap { entry in
                    let name = entry.lastPathComponent
                    let bundleID = app.bundleID ?? ""
                    let appName = app.name
                    let matched: Bool
                    if bundleID.isEmpty {
                        matched = name == appName || name.contains(appName)
                    } else {
                        matched = name.contains(bundleID)
                            || name == appName
                            || (name.hasPrefix("group.") && name.contains(bundleID))
                    }
                    guard matched else { return nil }
                    guard !PathSafety.isProtectedFile(name: name, purpose: .scan) else { return nil }
                    let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                    return ScannedItem(
                        path: entry.path,
                        size: Int64(values?.fileSize ?? 0),
                        isDirectory: values?.isDirectory ?? false
                    )
                }
            }
            await MainActor.run {
                matchedItems = items
            }
        }
    }

    private func quitAndReselect(_ app: AppRecord) {
        isQuitting = true
        let running = NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.standardizedFileURL.path == app.bundlePath
        }
        _ = running?.terminate()
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            isQuitting = false
            load()
            select(app)
        }
    }

    private func performCleanup() {
        guard let app = selectedApp else { return }
        var items: [CleanupItem] = []
        if selectedPaths.contains(app.bundlePath) {
            items.append(CleanupItem(path: app.bundlePath, size: app.bundleSize, kind: "app"))
        }
        for item in matchedItems where selectedPaths.contains(item.path) {
            items.append(CleanupItem(path: item.path, size: item.size, kind: "support"))
        }
        guard !items.isEmpty else { return }
        let root = PathSafety.userHome.path
        let previewOnly = appState.settings.dryRun
        appState.beginActivity(.cleaning(detail: NSLocalizedString("uninstaller.cleaning", comment: "")))

        let task = Task {
            let result = await CleanupExecutor.shared.execute(
                plan: CleanupPlanBuilder.build(
                    selection: items.map { ScannedItem(path: $0.path, size: $0.size) },
                    records: items.compactMap { MetadataCollector.collect(url: URL(fileURLWithPath: $0.path)) },
                    containmentRoot: root,
                    previewOnly: previewOnly
                ),
                allowBundles: true,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.uninstall", comment: ""),
                category: "uninstaller",
                itemCount: items.count,
                bytes: result.bytesReclaimed,
                previewOnly: previewOnly,
                movedCount: result.moved.count,
                failedCount: result.failedCount,
                root: root
            ))
            appState.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("uninstaller.preview_done", comment: "")
                    : NSLocalizedString("uninstaller.clean_done", comment: ""),
                app.name
            ))
            load()
            selectedApp = nil
            selectedPaths = []
        }
        withExtendedLifetime(task) {}
    }
}
