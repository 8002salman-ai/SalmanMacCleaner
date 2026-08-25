//
//  SystemJunkView.swift
//  SalmanMacCleaner
//
//  System Junk: runs the junk-classification scan over high-value locations
//  and presents SAFE / REVIEW / PROTECTED results. Only SAFE items are
//  smart-selected; nothing is removed automatically.
//

import SwiftUI

struct SystemJunkView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isScanning = false
    @State private var outcome: ScanOutcome?

    var body: some View {
        Group {
            if let outcome {
                ResultsWorkspaceView(outcome: outcome)
            } else {
                HeroScreenView(
                    module: .systemJunk,
                    isBusy: isScanning,
                    lastScanText: lastScanText,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.system_junk.scope", comment: ""),
                    primaryAction: { runScan() },
                    selectors: { EmptyView() }
                )
            }
        }
    }

    private var lastScanText: String? {
        guard let last = appState.sessionStore.scans.first else { return nil }
        return String(format: NSLocalizedString("hero.last_scan", comment: ""),
                      last.date.formatted(date: .abbreviated, time: .shortened))
    }

    private func runScan() {
        isScanning = true
        outcome = nil
        let scope = ScanScope(mode: .quick)
        appState.beginActivity(.scanning(detail: NSLocalizedString("hero.action.scan_junk", comment: "")))
        let stream = DeepScanCoordinator.shared.start(scope: scope, settings: appState.settings)

        Task {
            for await event in stream {
                switch event {
                case .phaseChanged(let phase, let detail):
                    appState.activityPhase = .scanning(detail: detail ?? phase.title)
                case .progress(let snapshot):
                    appState.progress = snapshot.fraction ?? 0
                case .outcome(let result):
                    isScanning = false
                    outcome = result
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
