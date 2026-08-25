//
//  SmartCareView.swift
//  SalmanMacCleaner
//
//  Smart Care: one primary Scan action that runs a genuine Quick Scan
//  through the deep-scan engine and lands in the premium results workspace.
//

import SwiftUI

struct SmartCareView: View {
    @EnvironmentObject private var appState: AppState
    @State private var mode: ScanMode = .quick
    @State private var isScanning = false
    @State private var outcome: ScanOutcome?

    var body: some View {
        Group {
            if let outcome {
                ResultsWorkspaceView(outcome: outcome)
            } else {
                HeroScreenView(
                    module: .smartCare,
                    isBusy: isScanning,
                    lastScanText: lastScanText,
                    permissionWarning: permissionWarning,
                    estimatedScope: NSLocalizedString("hero.smart_care.scope", comment: ""),
                    primaryAction: { runScan() },
                    selectors: {
                        ScanModeSelector(mode: $mode)
                    }
                )
            }
        }
    }

    private var lastScanText: String? {
        guard let last = appState.sessionStore.scans.first else { return nil }
        return String(format: NSLocalizedString("hero.last_scan", comment: ""),
                      last.date.formatted(date: .abbreviated, time: .shortened))
    }

    private var permissionWarning: String? {
        PermissionService.shared.snapshot.fullDiskAccess == .granted
            ? nil
            : NSLocalizedString("hero.permission.limited_scan", comment: "")
    }

    private func runScan() {
        isScanning = true
        outcome = nil
        let scope = ScanScope(mode: mode)
        appState.beginActivity(.scanning(detail: mode.title))
        let stream = DeepScanCoordinator.shared.start(scope: scope, settings: appState.settings)

        Task {
            for await event in stream {
                switch event {
                case .phaseChanged(let phase, let detail):
                    appState.activityPhase = phase.isIndeterminate ? .scanning(detail: phase.title) : .scanning(detail: detail ?? phase.title)
                case .progress(let snapshot):
                    appState.progress = snapshot.fraction ?? 0
                case .outcome(let result):
                    isScanning = false
                    outcome = result
                    appState.sessionStore.recordScan(ScanHistoryRecord(
                        date: result.finishedAt,
                        mode: result.mode.rawValue,
                        scope: scope.volumes.isEmpty ? scope.explicitRoots.joined(separator: ", ") : scope.volumes.joined(separator: ", "),
                        duration: result.finishedAt.timeIntervalSince(result.startedAt),
                        itemsScanned: result.itemsScanned,
                        coveragePercent: ScanCoverageReport.coveragePercent(result.coverage),
                        provenance: result.provenance.rawValue,
                        candidatesBytes: result.safeBytes + result.reviewBytes,
                        applicationCount: result.applicationCount,
                        duplicateGroupCount: result.duplicateGroupCount
                    ))
                    appState.endActivity(message: String(
                        format: NSLocalizedString("scan.finished.summary", comment: ""),
                        FileUtilities.formattedBytes(result.safeBytes + result.reviewBytes)
                    ))
                case .failed(let message):
                    isScanning = false
                    appState.endActivity(error: message)
                case .coverageUpdated, .inventoryBatch:
                    break
                }
            }
        }
    }
}
