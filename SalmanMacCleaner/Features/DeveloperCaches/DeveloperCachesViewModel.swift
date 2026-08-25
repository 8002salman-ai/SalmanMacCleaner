//
//  DeveloperCachesViewModel.swift
//  SalmanMacCleaner
//
//  Category detection, explicit scan lifecycle, honest coverage, grouping,
//  and selected-only cleanup for Developer Caches.
//

import Foundation
import SwiftUI

struct CategoryGroup: Identifiable {
    let id: String
    let title: String
    let entries: [DeveloperCacheEntry]
}

enum DeveloperCacheSort: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case ageDescending

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sizeDescending: return NSLocalizedString("devcaches.sort.size_desc", comment: "")
        case .sizeAscending: return NSLocalizedString("devcaches.sort.size_asc", comment: "")
        case .nameAscending: return NSLocalizedString("devcaches.sort.name", comment: "")
        case .ageDescending: return NSLocalizedString("devcaches.sort.age", comment: "")
        }
    }
}

@MainActor
final class DeveloperCachesViewModel: ObservableObject {
    @Published var selectedCategories: Set<DeveloperCacheCategory> = []
    @Published private(set) var descriptors: [DeveloperCacheDescriptor] = []
    @Published var entries: [DeveloperCacheEntry] = []
    @Published var isScanning = false
    @Published var progress: Double = 0
    @Published var detail: String?
    @Published var errorMessage: String?
    @Published var deniedPaths: [String] = []
    @Published var truncatedPaths: [String] = []
    @Published var searchText = ""
    @Published var groupByCategory = true
    @Published var categoryFilter: DeveloperCacheCategory?
    @Published var sortOption: DeveloperCacheSort = .sizeDescending
    @Published var selection: Set<UUID> = []
    @Published var showConfirmation = false
    @Published var cleanupReport: CleanupResult?
    @Published var hasRun = false

    private var scanToken = UUID()

    init() {
        refreshDetection()
        selectedCategories = Set(descriptors.filter(\.detected).map(\.category))
    }

    var detectedCategories: Set<DeveloperCacheCategory> {
        Set(descriptors.filter(\.detected).map(\.category))
    }

    var detectedCount: Int { detectedCategories.count }

    func refreshDetection() {
        descriptors = DeveloperCacheScanner.descriptors()
    }

    func selectAllDetected() {
        selectedCategories = detectedCategories
    }

    func clearSelection() {
        selectedCategories.removeAll()
        selection.removeAll()
    }

    var filteredEntries: [DeveloperCacheEntry] {
        var filtered = entries
        if let categoryFilter {
            filtered = filtered.filter { $0.category == categoryFilter.rawValue }
        }
        if !searchText.isEmpty {
            filtered = filtered.filter {
                $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.path.localizedCaseInsensitiveContains(searchText)
                    || $0.category.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending: filtered.sort { $0.size > $1.size }
        case .sizeAscending: filtered.sort { $0.size < $1.size }
        case .nameAscending: filtered.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .ageDescending: filtered.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        }
        return filtered
    }

    var entriesByCategory: [CategoryGroup] {
        Dictionary(grouping: filteredEntries, by: { $0.category })
            .map { key, value in
                CategoryGroup(
                    id: key,
                    title: DeveloperCacheCategory(rawValue: key)?.title ?? key,
                    entries: value
                )
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var filteredBytes: Int64 {
        filteredEntries.reduce(0) { CleanupAccounting.adding($0, $1.size) }
    }

    var selectedBytes: Int64 {
        CleanupAccounting.uniqueBytes(for: entries.filter { selection.contains($0.id) }.map {
            CleanupItem(path: $0.path, size: $0.size, kind: $0.category, device: $0.device, inode: $0.inode)
        })
    }

    func startScan(settings: SettingsStore, coordinator: ScanCoordinator, activity: AppState) {
        errorMessage = nil
        deniedPaths = []
        truncatedPaths = []
        isScanning = true
        progress = 0
        selection = []
        entries = []
        cleanupReport = nil

        let categories = selectedCategories
        let maxAge = settings.devCacheMaxAgeDays
        let operation = ScanOperation<DeveloperCacheScanReport>(
            title: NSLocalizedString("devcaches.scanning", comment: ""),
            roots: categories.flatMap { $0.candidatePaths }
        ) { progressCallback, isCancelled in
            try DeveloperCacheScanner.scanReport(
                categories: categories,
                maxAgeDays: maxAge,
                progress: progressCallback,
                isCancelled: isCancelled
            )
        }

        let token = UUID()
        scanToken = token
        activity.beginActivity(.scanning(detail: operation.title))
        coordinator.start(operation, onProgress: { [weak self] fraction, detail in
            guard let self, self.scanToken == token else { return }
            self.progress = fraction
            self.detail = detail
        }, onComplete: { [weak self] outcome in
            guard let self, self.scanToken == token else { return }
            self.isScanning = false
            self.hasRun = true
            switch outcome {
            case .success(let report):
                self.entries = report.entries
                self.deniedPaths = report.deniedPaths
                self.truncatedPaths = report.truncatedPaths
                activity.endActivity(message: String(
                    format: NSLocalizedString("devcaches.results.summary", comment: ""),
                    report.entries.count,
                    FileUtilities.formattedBytes(report.entries.reduce(0) { CleanupAccounting.adding($0, $1.size) })
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

    func cancelScan(coordinator: ScanCoordinator, activity: AppState) {
        guard isScanning else { return }
        coordinator.cancel()
        isScanning = false
        activity.endActivity(message: NSLocalizedString("scan.cancelled", comment: ""))
    }

    func performCleanup(settings: SettingsStore, history: HistoryStore, activity: AppState) {
        showConfirmation = false
        guard !selection.isEmpty else { return }

        let selected = entries.filter { selection.contains($0.id) }
        let items = selected.map {
            CleanupItem(path: $0.path, size: $0.size, kind: $0.category, device: $0.device, inode: $0.inode)
        }
        let previewOnly = settings.dryRun
        let allowedRoots = Set(selected.flatMap { entry in
            DeveloperCacheCategory(rawValue: entry.category)?.candidatePaths(home: PathSafety.userHome) ?? []
        })
        activity.beginActivity(.cleaning(detail: NSLocalizedString("devcaches.cleaning", comment: "")))

        Task {
            let outcome = await CleanupEngine.shared.clean(
                items: items,
                root: PathSafety.userHome.path,
                previewOnly: previewOnly,
                allowedRoots: Array(allowedRoots),
                progress: { fraction, detail in
                    Task { @MainActor in activity.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            self.cleanupReport = outcome
            let movedPaths = Set(outcome.trashed.map(\.path))
            if !previewOnly {
                self.entries.removeAll { movedPaths.contains($0.path) }
                self.selection.subtract(outcome.trashed.map(\.id))
            }
            history.record(HistoryEntry(
                action: NSLocalizedString("history.action.dev_caches", comment: ""),
                category: "developerCaches",
                itemCount: outcome.succeededCount,
                bytes: previewOnly ? outcome.previewedBytes : outcome.movedBytes,
                dryRun: previewOnly,
                root: PathSafety.userHome.path
            ))
            activity.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.dev_caches", comment: ""),
                category: "developerCaches",
                itemCount: outcome.succeededCount,
                bytes: previewOnly ? outcome.previewedBytes : outcome.movedBytes,
                previewOnly: previewOnly,
                movedCount: outcome.trashed.count,
                failedCount: outcome.failedCount,
                root: PathSafety.userHome.path
            ))
            activity.endActivity(message: outcome.cancelled
                ? NSLocalizedString("cleanup.report.cancelled", comment: "")
                : String(
                    format: previewOnly
                        ? NSLocalizedString("devcaches.preview_done", comment: "")
                        : NSLocalizedString("devcaches.clean_done", comment: ""),
                    previewOnly ? outcome.previewed.count : outcome.trashed.count
                ))
        }
    }
}
