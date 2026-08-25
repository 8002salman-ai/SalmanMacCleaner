//
//  DeveloperCachesViewModel.swift
//  SalmanMacCleaner
//
//  State for the developer cache scanner: category selection, scan lifecycle,
//  grouping and selected-only cleanup.
//

import Foundation
import SwiftUI

/// A category group for the grouped list rendering.
struct CategoryGroup: Identifiable {
    let id: String
    let title: String
    let entries: [DeveloperCacheEntry]
}

@MainActor
final class DeveloperCachesViewModel: ObservableObject {
    @Published var selectedCategories: Set<DeveloperCacheCategory> = Set(DeveloperCacheCategory.allCases)
    @Published var entries: [DeveloperCacheEntry] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var detail: String?
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var groupByCategory = true
    @Published var selection: Set<UUID> = []
    @Published var showConfirmation = false
    @Published var hasRun = false

    private var scanToken = UUID()

    var filteredEntries: [DeveloperCacheEntry] {
        let filtered: [DeveloperCacheEntry]
        if searchText.isEmpty {
            filtered = entries
        } else {
            filtered = entries.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
            }
        }
        return filtered.sorted { $0.size > $1.size }
    }

    var entriesByCategory: [CategoryGroup] {
        Dictionary(grouping: filteredEntries, by: { $0.category })
            .map { key, value in
                CategoryGroup(
                    id: key,
                    title: DeveloperCacheCategory(rawValue: key)?.title ?? key,
                    entries: value.sorted { $0.size > $1.size }
                )
            }
            .sorted { $0.id < $1.id }
    }

    var filteredBytes: Int64 {
        filteredEntries.reduce(0) { $0 + $1.size }
    }

    var selectedBytes: Int64 {
        entries.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    func startScan(settings: SettingsStore, coordinator: ScanCoordinator, activity: AppState) {
        errorMessage = nil
        isScanning = true
        progress = 0
        selection = []
        entries = []

        let categories = selectedCategories
        let maxAge = settings.devCacheMaxAgeDays
        let operation = ScanOperation<[DeveloperCacheEntry]>(
            title: NSLocalizedString("devcaches.scanning", comment: ""),
            roots: DeveloperCacheCategory.allCases.flatMap { $0.candidatePaths }
        ) { progressCallback, isCancelled in
            try DeveloperCacheScanner.scan(
                categories: categories,
                maxAgeDays: maxAge,
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
                self.entries = found
                activity.endActivity(message: String(
                    format: NSLocalizedString("devcaches.results.summary", comment: ""),
                    found.count,
                    FileUtilities.formattedBytes(found.reduce(0) { $0 + $1.size })
                ))
            case .failure(let error):
                if (error as? DeveloperCacheScanError) == .cancelled || (error as? ScanError) == .cancelled {
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

        let selected = entries.filter { selection.contains($0.id) }
        let items = selected.map {
            CleanupItem(path: $0.path, size: $0.size, kind: $0.category)
        }
        let root = PathSafety.userHome.path
        let previewOnly = settings.dryRun

        activity.beginActivity(.cleaning(detail: NSLocalizedString("devcaches.cleaning", comment: "")))
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
                action: NSLocalizedString("history.action.dev_caches", comment: ""),
                category: "developerCaches",
                itemCount: items.count,
                bytes: outcome.totalBytes,
                dryRun: previewOnly,
                root: root
            ))
            activity.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("devcaches.preview_done", comment: "")
                    : NSLocalizedString("devcaches.clean_done", comment: ""),
                outcome.succeededCount
            ))
            self.entries = []
            self.selection = []
        }
        withExtendedLifetime(task) {}
    }
}
