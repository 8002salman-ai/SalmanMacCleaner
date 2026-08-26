//
//  LargeFilesViewModel.swift
//  SalmanMacCleaner
//
//  State for the Large File Finder: roots, scan lifecycle, selection and
//  cleanup. Cleanup runs through CleanupEngine (trash-only, revalidated).
//

import Foundation
import SwiftUI

@MainActor
final class LargeFilesViewModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var result: ScanResult?
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var detail: String?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var sortOrder: LargeFilesSortOrder = .sizeDescending
    @Published var selection: Set<UUID> = []
    @Published var showConfirmation = false
    @Published var cleanupReport: CleanupResult?
    @Published var folderPickerPresented = false

    private var coordinator: ScanCoordinator?
    private var scanToken = UUID()

    var filteredItems: [ScannedItem] {
        guard let items = result?.items else { return [] }
        let filtered: [ScannedItem]
        if searchText.isEmpty {
            filtered = items
        } else {
            filtered = items.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .sizeDescending: return filtered.sorted { $0.size > $1.size }
        case .sizeAscending: return filtered.sorted { $0.size < $1.size }
        case .nameAscending: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateDescending:
            return filtered.sorted { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        }
    }

    var selectedBytes: Int64 {
        guard let items = result?.items else { return 0 }
        return CleanupAccounting.uniqueBytes(for: items.filter { selection.contains($0.id) })
    }

    var selectedConfirmationDetails: [String] {
        (result?.items ?? [])
            .filter { selection.contains($0.id) }
            .sorted { $0.path < $1.path }
            .map {
                ConfirmationDialogConfig.detailLine(
                    path: $0.path,
                    category: NSLocalizedString("junk.large_file", comment: ""),
                    size: $0.size,
                    confidence: NSLocalizedString("safety.review", comment: ""),
                    reason: NSLocalizedString("largefiles.confirm.reason", comment: "")
                )
            }
    }

    func addRoot(_ url: URL?) {
        folderPickerPresented = false
        guard let url else { return }
        switch FolderPicker.validatePickedFolder(url) {
        case .success(let validated):
            if !roots.contains(validated) {
                roots.append(validated)
                result = nil
                selection = []
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func startScan(settings: SettingsStore, coordinator: ScanCoordinator, activity: AppState, preserveCleanupReport: Bool = false) {
        guard !roots.isEmpty else {
            errorMessage = NSLocalizedString("largefiles.error.no_roots", comment: "")
            return
        }
        errorMessage = nil
        isScanning = true
        progress = 0
        selection = []
        result = nil
        if !preserveCleanupReport {
            cleanupReport = nil
        }

        let rootsSnapshot = roots
        let threshold = Int64(settings.largeFileThresholdMB * 1_048_576)
        let depth = settings.maxScanDepth
        let exclusions = settings.excludedPatterns

        let operation = ScanOperation<ScanResult>(
            title: NSLocalizedString("largefiles.scanning", comment: ""),
            roots: rootsSnapshot.map { $0.path }
        ) { progressCallback, isCancelled in
            try LargeFileScanner.scan(
                roots: rootsSnapshot,
                thresholdBytes: threshold,
                maxDepth: depth,
                excludePatterns: exclusions,
                progress: progressCallback,
                isCancelled: isCancelled
            )
        }

        let token = UUID()
        self.scanToken = token
        self.coordinator = coordinator
        activity.beginActivity(.scanning(detail: operation.title))
        coordinator.start(operation, onProgress: { [weak self] fraction, detail in
            self?.progress = fraction
            self?.detail = detail
        }, onComplete: { [weak self] outcome in
            guard let self, self.scanToken == token else { return }
            self.isScanning = false
            switch outcome {
            case .success(let scanResult):
                self.result = scanResult
                self.errorMessage = scanResult.errorMessage
                activity.endActivity(message: String(
                    format: NSLocalizedString("largefiles.results.summary", comment: ""),
                    scanResult.items.count,
                    FileUtilities.formattedBytes(scanResult.totalBytes)
                ))
            case .failure(let error):
                if (error as? LargeFileScanError) == .cancelled || (error as? ScanError) == .cancelled {
                    activity.endActivity(message: NSLocalizedString("scan.cancelled", comment: ""))
                } else {
                    self.errorMessage = error.localizedDescription
                    activity.endActivity(error: error.localizedDescription)
                }
            }
        })
    }

    func performCleanup(settings: SettingsStore, history: HistoryStore, activity: AppState) {
        showConfirmation = false
        guard let result, !selection.isEmpty else { return }

        let selected = result.items.filter { selection.contains($0.id) }
        let items = selected.map {
            CleanupItem(
                path: $0.path,
                size: $0.size,
                kind: $0.isDirectory ? "folder" : "file",
                device: $0.device,
                inode: $0.inode
            )
        }
        // Preserve multiple explicit folder boundaries while giving the
        // engine one safe lexical containment root.
        let root = PathSafety.userHome.path
        let allowedRoots = result.roots
        let previewOnly = settings.dryRun

        activity.beginActivity(.cleaning(detail: NSLocalizedString("largefiles.cleaning", comment: "")))
        let task = Task {
            let outcome = await CleanupEngine.shared.clean(
                items: items,
                root: root,
                previewOnly: previewOnly,
                allowedRoots: allowedRoots,
                progress: { fraction, detail in
                    Task { @MainActor in activity.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )

            if Task.isCancelled { return }
            self.cleanupReport = outcome
            let entry = HistoryEntry(
                action: NSLocalizedString("history.action.large_files", comment: ""),
                category: "largeFiles",
                itemCount: outcome.succeededCount,
                bytes: previewOnly ? outcome.previewedBytes : outcome.movedBytes,
                dryRun: previewOnly,
                root: root
            )
            history.record(entry)
            activity.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: entry.action,
                category: entry.category,
                itemCount: outcome.succeededCount,
                bytes: previewOnly ? outcome.previewedBytes : outcome.movedBytes,
                previewOnly: previewOnly,
                movedCount: outcome.trashed.count,
                failedCount: outcome.failedCount,
                root: root
            ))
            activity.endActivity(message: outcome.cancelled
                ? NSLocalizedString("cleanup.report.cancelled", comment: "")
                : String(
                    format: previewOnly
                        ? NSLocalizedString("largefiles.preview_done", comment: "")
                        : NSLocalizedString("largefiles.clean_done", comment: ""),
                    outcome.succeededCount
                ))
            if !previewOnly {
                let movedPaths = Set(outcome.trashed.map(\.path))
                let movedIDs = Set(selected.filter { movedPaths.contains($0.path) }.map(\.id))
                if var updated = self.result {
                    updated.items.removeAll { movedPaths.contains($0.path) }
                    updated.totalBytes = CleanupAccounting.uniqueBytes(for: updated.items)
                    self.result = updated
                }
                self.selection.subtract(movedIDs)
                if !outcome.cancelled {
                    // Re-scan the explicit roots so the visible inventory and
                    // its measured bytes are reconciled with the filesystem.
                    self.startScan(
                        settings: settings,
                        coordinator: ScanCoordinator.shared,
                        activity: activity,
                        preserveCleanupReport: true
                    )
                }
            }
        }
        withExtendedLifetime(task) {}
    }
}
