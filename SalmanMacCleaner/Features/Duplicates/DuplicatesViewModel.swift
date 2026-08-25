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
    @Published var cleanupReport: CleanupResult?
    @Published var folderPickerPresented = false
    @Published var hasRun = false
    @Published var coverageReport: DuplicateScanReport?

    private var scanToken = UUID()

    init() {
        // Duplicate detection is useful for regenerable stores by default, not
        // for personal documents. Personal folders remain available only after
        // an explicit folder-pick grant.
        let defaults = ScanPolicy.quickLibraryRoots(home: PathSafety.userHome)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        roots = defaults.filter {
            FileManager.default.fileExists(atPath: $0.path)
                && PathSafety.kind(of: $0.path) == .directory
                && PathSafety.isOwnedByCurrentUser($0.path)
        }
    }

    var visibleGroups: [DuplicateGroup] {
        if searchText.isEmpty {
            return groups
        }
        return groups.filter { group in
            group.files.contains { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
    }

    var totalReclaimable: Int64 {
        groups.reduce(0) { CleanupAccounting.adding($0, $1.reclaimableBytes) }
    }

    var coverageSummary: String? {
        guard let report = coverageReport else { return nil }
        if report.isPartial {
            return String(format: NSLocalizedString("duplicates.coverage.partial", comment: ""),
                          report.filesConsidered,
                          report.directoriesVisited,
                          report.deniedPaths)
        }
        return String(format: NSLocalizedString("duplicates.coverage.complete", comment: ""),
                      report.filesConsidered,
                      report.directoriesVisited)
    }

    var selectedBytes: Int64 {
        let selectedItems = groups.flatMap { group in
            group.removableFiles.filter { selection.contains($0.id) }
        }
        return CleanupAccounting.uniqueBytes(for: selectedItems)
    }

    var selectedConfirmationDetails: [String] {
        groups.flatMap { group in
            group.removableFiles
                .filter { selection.contains($0.id) }
                .map { file in
                    ConfirmationDialogConfig.detailLine(
                        path: file.path,
                        category: NSLocalizedString("junk.duplicate", comment: ""),
                        size: file.size,
                        confidence: NSLocalizedString("duplicates.confidence.exact", comment: ""),
                        reason: String(format: NSLocalizedString("duplicates.confirm.reason", comment: ""), String(group.hash.prefix(16)))
                    )
                }
        }
        .sorted()
    }

    func addRoot(_ url: URL?) {
        folderPickerPresented = false
        guard let url else { return }
        switch FolderPicker.validatePickedFolder(url) {
        case .success(let validated):
            addValidatedRoot(validated)
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    /// Add a folder that was explicitly granted through a security-scoped
    /// bookmark. Unlike the ordinary picker, this intentionally permits a
    /// user-owned folder outside the home directory, while still refusing
    /// protected roots, bundles, symlinks, and non-directories.
    func addAuthorizedRoot(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard PathSafety.kind(of: standardized.path) == .directory,
              PathSafety.isOwnedByCurrentUser(standardized.path),
              !PathSafety.isProtectedRootLocation(standardized.path),
              !PathSafety.isAppBundle(standardized.path) else {
            errorMessage = NSLocalizedString("folder.error.unauthorized_external", comment: "")
            return
        }
        addValidatedRoot(standardized)
    }

    private func addValidatedRoot(_ url: URL) {
        if !roots.contains(url) {
            roots.append(url)
            groups = []
            selection = []
        }
    }

    func reset() {
        roots = []
        groups = []
        selection = []
        hasRun = false
        coverageReport = nil
        progress = 0
    }

    func startScan(settings: SettingsStore, coordinator: ScanCoordinator, activity: AppState, preserveCleanupReport: Bool = false) {
        guard !roots.isEmpty else {
            errorMessage = NSLocalizedString("duplicates.error.no_roots", comment: "")
            return
        }
        errorMessage = nil
        isScanning = true
        progress = 0
        selection = []
        groups = []
        if !preserveCleanupReport {
            cleanupReport = nil
        }
        coverageReport = nil

        let rootsSnapshot = roots
        let depth = settings.maxScanDepth
        let authorizedURLs = FolderAuthorizationsStore.shared.activateScopes()
        let authorizedPaths = Set(authorizedURLs.map { $0.standardizedFileURL.path })
        let hasAuthorizedExternalRoot = rootsSnapshot.contains { root in
            !PathSafety.isInsideUserHome(root.path)
                && authorizedPaths.contains(root.standardizedFileURL.path)
        }
        let operation = ScanOperation<DuplicateScanReport>(
            title: NSLocalizedString("duplicates.scanning", comment: ""),
            roots: rootsSnapshot.map { $0.path }
        ) { progressCallback, isCancelled in
            try DuplicateFinder.scanReport(
                roots: rootsSnapshot,
                maxDepth: depth,
                allowOutsideHome: hasAuthorizedExternalRoot,
                authorizedRoots: Array(authorizedPaths),
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
            FolderAuthorizationsStore.shared.deactivateScopes()
            guard let self, self.scanToken == token else { return }
            self.isScanning = false
            self.hasRun = true
            switch outcome {
            case .success(let report):
                self.coverageReport = report
                self.groups = report.groups
                activity.endActivity(message: String(
                    format: NSLocalizedString("duplicates.results.summary", comment: ""),
                    report.groups.count,
                    FileUtilities.formattedBytes(report.groups.reduce(Int64(0)) { CleanupAccounting.adding($0, $1.reclaimableBytes) })
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
                items.append(CleanupItem(
                    path: file.path,
                    size: file.size,
                    kind: "file",
                    device: file.device,
                    inode: file.inode
                ))
            }
        }
        guard !items.isEmpty else { return }

        // The engine accepts one containment root; use the home boundary and
        // keep the explicitly selected duplicate roots as the narrower
        // allowlist so items from a second root are not rejected or widened.
        let root = PathSafety.userHome.path
        let allowedRoots = roots.map { $0.standardizedFileURL.path }
        let previewOnly = settings.dryRun
        let authorizedURLs = FolderAuthorizationsStore.shared.activateScopes()
        let authorizedPaths = Set(authorizedURLs.map { $0.standardizedFileURL.path })
        let externalRoots = allowedRoots.filter { !PathSafety.isInsideUserHome($0) }
        guard externalRoots.allSatisfy({ authorizedPaths.contains($0) }) else {
            FolderAuthorizationsStore.shared.deactivateScopes()
            errorMessage = NSLocalizedString("folder.error.authorization_expired", comment: "")
            return
        }

        activity.beginActivity(.cleaning(detail: NSLocalizedString("duplicates.cleaning", comment: "")))
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
            FolderAuthorizationsStore.shared.deactivateScopes()
            if Task.isCancelled { return }
            self.cleanupReport = outcome

            history.record(HistoryEntry(
                action: NSLocalizedString("history.action.duplicates", comment: ""),
                category: "duplicates",
                itemCount: outcome.succeededCount,
                bytes: previewOnly ? outcome.previewedBytes : outcome.movedBytes,
                dryRun: previewOnly,
                root: root
            ))
            activity.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.duplicates", comment: ""),
                category: "duplicates",
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
                        ? NSLocalizedString("duplicates.preview_done", comment: "")
                        : NSLocalizedString("duplicates.clean_done", comment: ""),
                    outcome.succeededCount
                ))
            if !previewOnly {
                let movedPaths = Set(outcome.trashed.map(\.path))
                let movedIDs = Set(self.groups.flatMap { $0.files.filter { movedPaths.contains($0.path) } }.map(\.id))
                self.groups = self.groups.compactMap { group in
                    var updated = group
                    updated.files.removeAll { movedPaths.contains($0.path) }
                    return updated.files.count > 1 ? updated : nil
                }
                self.selection.subtract(movedIDs)
                if !outcome.cancelled {
                    // Verify the source roots after Trash movement so a
                    // concurrent filesystem change cannot leave stale groups.
                    self.startScan(
                        settings: settings,
                        coordinator: coordinator,
                        activity: activity,
                        preserveCleanupReport: true
                    )
                }
            }
        }
        withExtendedLifetime(task) {}
    }
}
