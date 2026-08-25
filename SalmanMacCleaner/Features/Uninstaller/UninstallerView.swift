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
    @State private var isCleaning = false
    /// Exact outcome of the last preview/uninstall run.
    @State private var report: ExecutedCleanupResult?

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
        .cleanupConfirmation(
            isPresented: $showConfirmation,
            config: .standard(
                itemCount: selectedPaths.count,
                totalBytes: selectedBytes,
                previewOnly: appState.settings.dryRun
            ),
            onConfirm: { performCleanup() }
        )
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
                    // One honest action. Preview Mode on → "Preview Selected"
                    // (confirms with "Confirm Preview", moves nothing).
                    // Preview Mode off → "Move Selected to Trash".
                    Button {
                        showConfirmation = true
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: appState.settings.dryRun ? "eye.fill" : "trash.fill")
                            Text(appState.settings.dryRun ? "results.preview_selected" : "common.trash_selected")
                        }
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    .disabled(selectedPaths.isEmpty || isCleaning || app.isRunning)
                    .help(appState.settings.dryRun
                          ? Text("results.preview_selected.help")
                          : Text("common.trash_selected.help"))
                }

                if let report {
                    uninstallReport(report)
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

    /// Bytes represented by the current explicit selection.
    private var selectedBytes: Int64 {
        var total: Int64 = 0
        if let app = selectedApp, selectedPaths.contains(app.bundlePath) {
            total += app.bundleSize
        }
        for item in matchedItems where selectedPaths.contains(item.path) {
            total += item.size
        }
        return total
    }

    /// Uninstall the selected app and only the support items the user
    /// explicitly checked. The bundle is admitted through a narrow,
    /// explicit grant (the bundle path itself) — never by widening the
    /// cleanup policy. System apps, running apps, other users' files and
    /// preferences are refused with an exact reason.
    private func performCleanup() {
        guard let app = selectedApp else { return }
        let previewOnly = appState.settings.dryRun
        report = nil

        var selection: [ScannedItem] = []
        var authorizedRoots: [String] = []
        if selectedPaths.contains(app.bundlePath) {
            selection.append(ScannedItem(
                path: app.bundlePath,
                size: app.bundleSize,
                isDirectory: true
            ))
            // The grant covers exactly this bundle — nothing else on disk.
            authorizedRoots.append(URL(fileURLWithPath: app.bundlePath).standardizedFileURL.path)
        }
        for item in matchedItems where selectedPaths.contains(item.path) {
            selection.append(item)
        }
        guard !selection.isEmpty else { return }

        let home = PathSafety.userHome.path
        let built = CleanupPlanBuilder.buildDetailed(
            selection: selection,
            records: selection.compactMap {
                MetadataCollector.collect(
                    url: URL(fileURLWithPath: $0.path, isDirectory: $0.isDirectory)
                )
            },
            containmentRoot: home,
            previewOnly: previewOnly,
            allowBundles: true,
            authorizedRoots: authorizedRoots
        )

        // Selections whose metadata could not be read are reported, never
        // silently dropped.
        let accounted = Set(built.plan.items.map { $0.path } + built.rejections.map { $0.path })
        let unreadable: [(path: String, reason: String, bytes: Int64)] = selection.compactMap { item in
            let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.path
            guard !accounted.contains(canonical) else { return nil }
            return (
                canonical,
                NSLocalizedString("plan.skip.no_record", comment: "") + " \(canonical)",
                item.size
            )
        }

        appState.beginActivity(.cleaning(detail: NSLocalizedString(
            previewOnly ? "uninstaller.previewing" : "uninstaller.cleaning",
            comment: ""
        )))
        isCleaning = true

        Task {
            let result = await CleanupExecutor.shared.execute(
                plan: built.plan,
                allowBundles: true,
                authorizedRoots: authorizedRoots,
                skipped: built.rejections + unreadable,
                selectedCount: built.selectedCount + unreadable.count,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            isCleaning = false
            report = result

            // Only what really moved leaves the list; everything else stays
            // visible with its reported reason.
            let moved = Set(result.moved)
            if !moved.isEmpty {
                matchedItems.removeAll { moved.contains($0.path) }
                selectedPaths.subtract(moved)
            }

            if !built.plan.items.isEmpty {
                appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                    action: NSLocalizedString("history.action.uninstall", comment: ""),
                    category: "uninstaller",
                    itemCount: result.succeededCount,
                    bytes: result.previewOnly ? result.previewedBytes : result.movedBytes,
                    previewOnly: result.previewOnly,
                    movedCount: result.moved.count,
                    failedCount: result.failedCount,
                    skippedCount: result.skippedCount,
                    root: home
                ))
            }
            appState.endActivity(message: result.summary)

            if !previewOnly, moved.contains(app.bundlePath) {
                selectedApp = nil
                selectedPaths = []
                load()
            }
        }
    }

    /// Exact per-run report: counts, bytes, refusal reasons and a way to see
    /// the moved bundle/components in the Trash.
    private func uninstallReport(_ report: ExecutedCleanupResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: report.previewOnly
                      ? "eye.fill"
                      : (report.failedCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(report.previewOnly
                                     ? AuroraPalette.cyan
                                     : (report.failedCount > 0 ? AuroraPalette.amber : AuroraPalette.success))
                Text(report.summary)
                    .font(.callout.weight(.semibold))
                Spacer()
                if !report.trashDestinations.isEmpty {
                    Button("results.reveal_in_trash") {
                        let urls = report.trashDestinations.values.sorted().prefix(50)
                            .map { URL(fileURLWithPath: $0) }
                        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
                    }
                    .buttonStyle(.link)
                    .help("results.reveal_in_trash.help")
                }
                Button {
                    self.report = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("common.clear")
            }
            Text(String(
                format: NSLocalizedString("cleanup.report.counts", comment: ""),
                report.selectedCount,
                report.plannedCount,
                report.moved.count,
                report.previewed.count,
                report.skippedCount,
                report.failedCount,
                FileUtilities.formattedBytes(report.previewOnly ? report.previewedBytes : report.movedBytes)
            ))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            ForEach(report.reasons(limit: 4), id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AuroraPalette.amber)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .combine)
    }
}
