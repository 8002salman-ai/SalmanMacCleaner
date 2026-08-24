//
//  UninstallerViewModel.swift
//  SalmanMacCleaner
//
//  State for the uninstaller: candidate discovery, selection and trash-only
//  removal of the bundle plus matched support files.
//

import Foundation
import SwiftUI

@MainActor
final class UninstallerViewModel: ObservableObject {
    @Published var candidates: [UninstallCandidate] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var searchText = ""
    @Published var selectedCandidateID: UUID?
    @Published var showConfirmation = false

    var filteredCandidates: [UninstallCandidate] {
        guard !searchText.isEmpty else { return candidates }
        return candidates.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleID?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var selectedCandidate: UninstallCandidate? {
        candidates.first { $0.id == selectedCandidateID }
    }

    func refresh() {
        isLoading = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let discovered = Uninstaller.discoverApplications()
            await MainActor.run {
                self.candidates = discovered
                self.isLoading = false
                if self.selectedCandidateID == nil || !discovered.contains(where: { $0.id == self.selectedCandidateID }) {
                    self.selectedCandidateID = discovered.first?.id
                }
            }
        }
    }

    func performCleanup(settings: SettingsStore, history: HistoryStore, activity: AppState) {
        showConfirmation = false
        guard let candidate = selectedCandidate else { return }
        guard !candidate.isRunning else {
            errorMessage = NSLocalizedString("uninstaller.running_warning", comment: "")
            return
        }

        let items = Uninstaller.cleanupItems(for: candidate)
        let root = PathSafety.userHome.path
        let previewOnly = settings.dryRun

        activity.beginActivity(.cleaning(detail: NSLocalizedString("uninstaller.cleaning", comment: "")))
        let task = Task {
            let outcome = await CleanupEngine.shared.clean(
                items: items,
                root: root,
                previewOnly: previewOnly,
                allowBundles: true,
                progress: { fraction, detail in
                    Task { @MainActor in activity.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }

            history.record(HistoryEntry(
                action: NSLocalizedString("history.action.uninstall", comment: ""),
                category: "uninstaller",
                itemCount: items.count,
                bytes: outcome.totalBytes,
                dryRun: previewOnly,
                root: root
            ))
            activity.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("uninstaller.preview_done", comment: "")
                    : NSLocalizedString("uninstaller.clean_done", comment: ""),
                candidate.name
            ))
            self.refresh()
        }
        withExtendedLifetime(task) {}
    }
}
