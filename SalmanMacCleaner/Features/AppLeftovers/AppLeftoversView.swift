//
//  AppLeftoversView.swift
//  SalmanMacCleaner
//
//  App Leftovers: builds the installed-app bundle-ID inventory, then inspects
//  support roots for entries whose exact owning application is gone.
//  HIGH confidence only is suggested; groups share one owning bundle ID.
//

import SwiftUI
import AppKit

struct AppLeftoversView: View {
    @EnvironmentObject private var appState: AppState
    @State private var leftovers: [LeftoverCandidate] = []
    @State private var isScanning = false
    @State private var heroMode = true
    @State private var selection: Set<String> = []
    @State private var showConfirmation = false

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .appLeftovers,
                    isBusy: isScanning,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.app_leftovers.scope", comment: ""),
                    primaryAction: {
                        heroMode = false
                        runScan()
                    },
                    selectors: { EmptyView() }
                )
            } else if isScanning {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("leftovers.scanning")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                results
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            if leftovers.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "leftovers.empty.title",
                    message: "leftovers.empty.message"
                )
                HStack {
                    Spacer()
                    Button("leftovers.rescan") { runScan() }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                    Spacer()
                }
            } else {
                Text(String(format: NSLocalizedString("leftovers.summary", comment: ""),
                            leftovers.count, FileUtilities.formattedBytes(totalBytes)))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                List(leftovers) { group in
                    DisclosureGroup {
                        ForEach(group.paths, id: \.self) { path in
                            HStack(spacing: 8) {
                                Image(systemName: "doc")
                                    .foregroundStyle(.secondary)
                                Text(path)
                                    .font(.caption)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(FileUtilities.formattedBytes(FileUtilities.fileSize(atPath: path)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("results.reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Toggle("", isOn: binding(for: group.groupID))
                                .toggleStyle(.checkbox)
                                .labelsHidden()
                                .disabled(group.confidence != .high)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.owningBundleID)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(String(format: NSLocalizedString("leftovers.paths_count", comment: ""), group.paths.count))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            ConfidenceBadge(confidence: group.confidence)
                            Text(FileUtilities.formattedBytes(group.totalSize))
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(group.confidence != .high)
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .padding(24)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                HStack {
                    Text(String(format: NSLocalizedString("results.selected", comment: ""), selection.count))
                    Spacer()
                    Button("results.preview_cleanup") {
                        showConfirmation = true
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    Button("results.clean_selected") {
                        showConfirmation = true
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    .disabled(appState.settings.dryRun)
                }
                .padding(14)
                .background(.ultraThinMaterial)
            }
        }
        .cleanupConfirmation(
            isPresented: $showConfirmation,
            config: .standard(itemCount: selection.count, totalBytes: selectedBytes, previewOnly: appState.settings.dryRun),
            onConfirm: { performCleanup() }
        )
    }

    private var totalBytes: Int64 {
        leftovers.reduce(0) { $0 + $1.totalSize }
    }

    private var selectedBytes: Int64 {
        leftovers.filter { selection.contains($0.groupID) }.reduce(0) { $0 + $1.totalSize }
    }

    private func binding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(groupID) },
            set: { on in
                if on { selection.insert(groupID) } else { selection.remove(groupID) }
            }
        )
    }

    private func runScan() {
        isScanning = true
        selection = []
        Task.detached(priority: .userInitiated) {
            let apps = ApplicationInventoryService.discoverApplications()
            let found = ResidualCorrelationEngine.discoverLeftovers(installedApps: apps)
            await MainActor.run {
                leftovers = found.filter { $0.confidence == .high || $0.confidence == .medium }
                isScanning = false
            }
        }
    }

    private func performCleanup() {
        let selectedGroups = leftovers.filter { selection.contains($0.groupID) }
        var items: [CleanupItem] = []
        for group in selectedGroups {
            for path in group.paths {
                items.append(CleanupItem(path: path, size: FileUtilities.fileSize(atPath: path), kind: "leftover"))
            }
        }
        guard !items.isEmpty else { return }
        let root = PathSafety.userHome.path
        let previewOnly = appState.settings.dryRun
        appState.beginActivity(.cleaning(detail: NSLocalizedString("leftovers.cleaning", comment: "")))

        let task = Task {
            let result = await CleanupEngine.shared.clean(
                items: items,
                root: root,
                previewOnly: previewOnly,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.leftovers", comment: ""),
                category: "appLeftovers",
                itemCount: items.count,
                bytes: result.totalBytes,
                previewOnly: previewOnly,
                movedCount: result.trashed.count,
                failedCount: result.failedCount,
                root: root
            ))
            appState.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("leftovers.preview_done", comment: "")
                    : NSLocalizedString("leftovers.clean_done", comment: ""),
                result.succeededCount
            ))
            runScan()
        }
        withExtendedLifetime(task) {}
    }
}
