//
//  LargeOldFilesView.swift
//  SalmanMacCleaner
//
//  Large & Old Files: folder-scoped finding of large and long-untouched
//  files. Only user-selected folders are scanned; results are preview-first
//  and require explicit selection.
//

import SwiftUI
import AppKit

struct LargeOldFilesView: View {
    @EnvironmentObject private var appState: AppState
    @State private var chosenFolder: URL?
    @State private var items: [ScannedItem] = []
    @State private var isScanning = false
    @State private var selection: Set<UUID> = []
    @State private var showPicker = false
    @State private var showConfirmation = false
    @State private var cleanupReport: CleanupResult?
    @State private var scanWasPartial = false
    @State private var scanTask: Task<Void, Never>?
    @State private var scanToken = UUID()
    @State private var minimumSizeMB: Double = 200
    @State private var olderThanDays: Int = 90

    var body: some View {
        Group {
            if chosenFolder == nil {
                HeroScreenView(
                    module: .largeOldFiles,
                    isBusy: false,
                    lastScanText: nil,
                    permissionWarning: NSLocalizedString("large_old.permission_note", comment: ""),
                    estimatedScope: NSLocalizedString("hero.large_old.scope", comment: ""),
                    primaryAction: { showPicker = true },
                    selectors: {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("large_old.min_size")
                                Slider(value: $minimumSizeMB, in: 50...2000, step: 50)
                                    .frame(width: 200)
                                Text(String(format: "%.0f MB", minimumSizeMB))
                                    .font(.callout.monospacedDigit())
                            }
                            Stepper(value: $olderThanDays, in: 7...3650, step: 30) {
                                Text(String(format: NSLocalizedString("large_old.older_than", comment: ""), olderThanDays))
                            }
                        }
                    }
                )
                .sheet(isPresented: $showPicker) {
                    FolderPickerView(message: "large_old.picker.message") { url in
                        if let url {
                            chosenFolder = url
                            scan(url)
                        }
                    }
                }
            } else if isScanning {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("large_old.scanning")
                        .foregroundStyle(.secondary)
                    Button("common.cancel") {
                        cancelScan()
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                results
            }
        }
        .onChange(of: appState.cancellationGeneration) { _ in
            if isScanning { cancelScan() }
        }
        .onDisappear {
            if isScanning { cancelScan() }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(chosenFolder?.path ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("common.clear") {
                    chosenFolder = nil
                    items = []
                    selection = []
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("large_old.choose_other") { showPicker = true }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    .sheet(isPresented: $showPicker) {
                        FolderPickerView(message: "large_old.picker.message") { url in
                            if let url {
                                chosenFolder = url
                                scan(url)
                            }
                        }
                    }
            }

            if let cleanupReport {
                CleanupResultSummaryView(result: cleanupReport)
            }
            if scanWasPartial {
                PermissionBannerView(
                    message: NSLocalizedString("large_old.partial_coverage", comment: ""),
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            if items.isEmpty {
                EmptyStateView(
                    systemImage: "externaldrive.badge.timemachine",
                    title: "large_old.empty.title",
                    message: "large_old.empty.message"
                )
            } else {
                SelectionSummaryBar(selectedCount: selection.count, selectedBytes: selectedBytes, previewOnly: appState.settings.dryRun)
                List(items) { item in
                    Toggle(isOn: binding(for: item.id)) {
                        ItemRowLabel(
                            name: item.name,
                            detail: (item.modificationDate?.formatted(date: .abbreviated, time: .omitted)).map { "modified \($0) · " + item.path } ?? item.path,
                            size: item.size
                        )
                    }
                    .toggleStyle(.checkbox)
                    .help(Text(item.path))
                    .contextMenu {
                        Button("results.reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                    }
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
                    if appState.settings.dryRun {
                        Button("results.preview_cleanup") { showConfirmation = true }
                            .buttonStyle(AuroraSecondaryButtonStyle())
                    } else {
                        Button("results.clean_selected") { showConfirmation = true }
                            .buttonStyle(AuroraPrimaryButtonStyle())
                    }
                }
                .padding(14)
                .background(.ultraThinMaterial)
            }
        }
        .cleanupConfirmation(
            isPresented: $showConfirmation,
            config: .standard(
                itemCount: selection.count,
                totalBytes: selectedBytes,
                previewOnly: appState.settings.dryRun,
                details: selectedConfirmationDetails
            ),
            onConfirm: { performCleanup() }
        )
    }

    private var selectedBytes: Int64 {
        CleanupAccounting.uniqueBytes(for: items.filter { selection.contains($0.id) })
    }

    private var selectedConfirmationDetails: [String] {
        items
            .filter { selection.contains($0.id) }
            .sorted { $0.path < $1.path }
            .map {
                ConfirmationDialogConfig.detailLine(
                    path: $0.path,
                    category: NSLocalizedString("junk.old_file", comment: ""),
                    size: $0.size,
                    confidence: NSLocalizedString("safety.review", comment: ""),
                    reason: String(format: NSLocalizedString("large_old.confirm.reason", comment: ""), olderThanDays)
                )
            }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { on in
                if on { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }

    private func scan(_ url: URL) {
        scanTask?.cancel()
        let token = UUID()
        scanToken = token
        isScanning = true
        scanWasPartial = false
        items = []
        selection = []
        let root = url.path
        let minBytes = Int64(minimumSizeMB * 1_048_576)
        let cutoff = Date().addingTimeInterval(-Double(olderThanDays) * 86_400)

        let task = Task.detached(priority: .userInitiated) {
            var found: [ScannedItem] = []
            var entriesVisited = 0
            let coverage = TraversalIssueCounter()
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in
                    coverage.record()
                    return true
                }
            )
            guard let device = VolumeDiscoveryService.deviceID(ofMountPoint: root),
                  let enumerator else {
                await MainActor.run {
                    guard scanToken == token else { return }
                    scanWasPartial = true
                    isScanning = false
                }
                return
            }
            for case let entry as URL in enumerator {
                entriesVisited += 1
                if entriesVisited > 250_000 {
                    coverage.record()
                    break
                }
                guard !Task.isCancelled else {
                    coverage.record()
                    break
                }
                if enumerator.level > 64 {
                    coverage.record()
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]) else {
                    coverage.record()
                    continue
                }
                if values.isSymbolicLink == true { continue }
                guard values.isRegularFile == true, let size = values.fileSize, Int64(size) >= minBytes else { continue }
                guard let modified = values.contentModificationDate, modified < cutoff else { continue }
                let safe = PathSafety.validate(path: entry.path, root: root, expectedDevice: dev_t(device), purpose: .scan, allowSymlink: false)
                guard case .success(let validated) = safe else {
                    coverage.record()
                    continue
                }
                let identity = Crypto.inode(of: validated.canonical)
                found.append(ScannedItem(
                    path: validated.canonical,
                    size: Int64(size),
                    modificationDate: modified,
                    device: identity.map { Int32(clamping: Int64($0.0)) } ?? 0,
                    inode: identity.map { UInt64($0.1) } ?? 0
                ))
            }
            found.sort { $0.size > $1.size }
            let wasCancelled = Task.isCancelled
            await MainActor.run {
                guard scanToken == token else { return }
                items = wasCancelled ? [] : Array(found.prefix(800))
                scanWasPartial = (coverage.count > 0) || wasCancelled
                isScanning = false
                scanTask = nil
            }
        }
        scanTask = task
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanToken = UUID()
        isScanning = false
        scanWasPartial = true
    }

    private func performCleanup() {
        let selected = items.filter { selection.contains($0.id) }
        let cleanupItems = selected.map {
            CleanupItem(
                path: $0.path,
                size: $0.size,
                kind: "file",
                device: $0.device,
                inode: $0.inode
            )
        }
        guard let root = chosenFolder?.path, !cleanupItems.isEmpty else { return }
        let previewOnly = appState.settings.dryRun
        appState.beginActivity(.cleaning(detail: NSLocalizedString("large_old.cleaning", comment: "")))

        let task = Task {
            let result = await CleanupEngine.shared.clean(
                items: cleanupItems,
                root: root,
                previewOnly: previewOnly,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            cleanupReport = result
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.large_old", comment: ""),
                category: "largeOldFiles",
                itemCount: result.succeededCount,
                bytes: previewOnly ? result.totalBytes : result.movedBytes,
                previewOnly: previewOnly,
                movedCount: result.trashed.count,
                failedCount: result.failedCount,
                root: root
            ))
            appState.endActivity(message: result.cancelled
                ? NSLocalizedString("cleanup.report.cancelled", comment: "")
                : String(
                    format: previewOnly
                        ? NSLocalizedString("large_old.preview_done", comment: "")
                        : NSLocalizedString("large_old.clean_done", comment: ""),
                    result.succeededCount
                ))
            if !previewOnly, let folder = chosenFolder {
                scan(folder)
                selection = []
            }
        }
        withExtendedLifetime(task) {}
    }
}
