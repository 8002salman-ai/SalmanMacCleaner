//
//  DuplicatesViewModel.swift
//  SalmanMacCleaner
//
//  State for the Duplicate Finder: roots, scan lifecycle, grouping view state
//  and selected-only cleanup through CleanupEngine.
//

import Foundation
import SwiftUI

@MainActor
final class DuplicatesViewModel: ObservableObject {
    @Published var roots: [URL] = []
    @Published var groups: [DuplicateGroup] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var detail: String?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selection: Set<UUID> = []
    @Published var showConfirmation = false
    @Published var folderPickerPresented = false
    @Published var hasRun = false

    private var scanToken = UUID()

    var visibleGroups: [DuplicateGroup] {
        if searchText.isEmpty {
            return groups
        }
        return groups.filter { group in
            group.files.contains { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var totalReclaimable: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }

    var selectedBytes: Int64 {
        let selectedIDs = selection
        var bytes: Int64 = 0
        for group in groups {
            for file in group.files where selectedIDs.contains(file.id) {
                bytes += file.size
            }
        }
        return bytes
    }

    func addRoot(_ url: URL?) {
        folderPickerPresented = false
        guard let url else { return }
        switch FolderPicker.validatePickedFolder(url) {
        case .success(let validated):
            if !roots.contains(validated) {
                roots.append(validated)
                groups = []
                selection = []
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func reset() {
        roots = []
        groups = []
        selection = []
        hasRun = false
        progress = 0
    }

    func startScan(settings: SettingsStore, coordinator: ScanCoordinator, activity: AppState) {
        guard !roots.isEmpty else {
            errorMessage = NSLocalizedString("duplicates.error.no_roots", comment: "")
            return
        }
        errorMessage = nil
        isScanning = true
        progress = 0
        selection = []
        groups = []

        let rootsSnapshot = roots
        let depth = settings.maxScanDepth
        let operation = ScanOperation<[DuplicateGroup]>(
            title: NSLocalizedString("duplicates.scanning", comment: ""),
            roots: rootsSnapshot.map { $0.path }
        ) { progressCallback, isCancelled in
            try DuplicateFinder.scan(
                roots: rootsSnapshot,
                maxDepth: depth,
                progress: progressCallback,
                isCancelled: isCancelled
            )
        }

        let token = UUID()
        self.scanToken = token
        activity.beginActivity(.scanning(detail: operation.title))
        coordinator.start(operation, onProgress: { [weak self] fraction, detail in
            self?.progress = fraction
            self?.detail = detail
        }, onComplete: { [weak self] outcome in
            guard let self, self.scanToken == token else { return }
            self.isScanning = false
            self.hasRun = true
            switch outcome {
            case .success(let found):
                self.groups = found
                activity.endActivity(message: String(
                    format: NSLocalizedString("duplicates.results.summary", comment: ""),
                    found.count,
                    FileUtilities.formattedBytes(found.reduce(0) { $0 + $1.reclaimableBytes })
                ))
            case .failure(let error):
                if (error as? DuplicateScanError) == .cancelled || (error as? ScanError) == .cancelled {
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
        guard !selection.isEmpty else { return }

        var items: [CleanupItem] = []
        for group in groups {
            for file in group.files where selection.contains(file.id) {
                items.append(CleanupItem(path: file.path, size: file.size, kind: "file"))
            }
        }
        guard !items.isEmpty else { return }

        let root = roots.first?.path ?? PathSafety.userHome.path
        let previewOnly = settings.dryRun

        activity.beginActivity(.cleaning(detail: NSLocalizedString("duplicates.cleaning", comment: "")))
        let task = Task {
            let outcome = await CleanupEngine.shared.clean(
                items: items,
                root: root,
                previewOnly: previewOnly,
                progress: { fraction, detail in
                    Task { @MainActor in activity.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }

            history.record(HistoryEntry(
                action: NSLocalizedString("history.action.duplicates", comment: ""),
                category: "duplicates",
                itemCount: items.count,
                bytes: outcome.totalBytes,
                dryRun: previewOnly,
                root: root
            ))
            activity.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("duplicates.preview_done", comment: "")
                    : NSLocalizedString("duplicates.clean_done", comment: ""),
                outcome.succeededCount
            ))
            self.groups = []
            self.selection = []
        }
        withExtendedLifetime(task) {}
    }
}
