//
//  DeepScanView.swift
//  SalmanMacCleaner
//
//  Deep Scan: the deepest honest scan macOS allows. Volume selector with
//  explicit opt-ins, security-scoped folder authorization ("Choose folders
//  for Deep Scan"), real thirteen-phase progress with pause/resume/cancel,
//  honest coverage reporting and the results workspace. Without Full Disk
//  Access the volume roots are reported as skipped with an exact reason and
//  the UI shows "Limited coverage" — never "complete".
//

import SwiftUI
import AppKit

struct DeepScanView: View {
    @EnvironmentObject private var appState: AppState
    @State private var volumes: [VolumeInfo] = []
    @State private var selectedVolumeIDs: Set<String> = []
    @State private var includeHidden = true
    @State private var includePackageContents = false
    @State private var isScanning = false
    @State private var outcome: ScanOutcome?
    @State private var scanTask: Task<Void, Never>?
    @State private var currentSnapshot: ScanProgressSnapshot?
    @StateObject private var folderStore = FolderAuthorizationsStore.shared

    var body: some View {
        Group {
            if let outcome {
                ResultsWorkspaceView(outcome: outcome)
            } else if isScanning {
                scanProgressView
            } else {
                hero
            }
        }
        .onDisappear {
            scanTask?.cancel()
        }
    }

    private var hero: some View {
        HeroScreenView(
            module: .deepScan,
            lastScanText: lastScanText,
            permissionWarning: permissionWarning,
            estimatedScope: NSLocalizedString("hero.deep_scan.scope", comment: ""),
            primaryAction: { runScan() },
            selectors: {
                VStack(alignment: .leading, spacing: 12) {
                    VolumeSelector(selectedVolumeIDs: $selectedVolumeIDs, volumes: volumes)
                    Toggle("settings.include_hidden", isOn: $includeHidden)
                        .toggleStyle(.checkbox)
                    Toggle("settings.include_packages", isOn: $includePackageContents)
                        .toggleStyle(.checkbox)
                    Divider().overlay(Color.white.opacity(0.08))
                    AuthorizedFoldersSection(store: folderStore)
                }
            }
        )
        .task {
            volumes = VolumeDiscoveryService.discoverVolumes()
            if selectedVolumeIDs.isEmpty {
                selectedVolumeIDs = Set(volumes.filter { !$0.requiresOptIn }.prefix(1).map { $0.mountPoint })
            }
            if PermissionService.shared.snapshot.lastCheck == .distantPast {
                PermissionService.shared.recheck()
            }
        }
    }

    private var scanProgressView: some View {
        VStack(spacing: 24) {
            Spacer()
            ModuleArtwork(module: .deepScan, size: 200)
            Text(currentSnapshot?.phase.title ?? ScanPhase.preparingPermissions.title)
                .font(.title2.weight(.semibold))
            if let snapshot = currentSnapshot {
                VStack(spacing: 6) {
                    if snapshot.phase.isIndeterminate {
                        ProgressView()
                            .controlSize(.large)
                        if let path = snapshot.currentPath {
                            Text(privacyTruncated(path))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else if let fraction = snapshot.fraction {
                        ProgressView(value: fraction)
                            .frame(width: 420)
                    }
                    HStack(spacing: 18) {
                        stat("scan.stat.items", value: "\(snapshot.itemsScanned)")
                        stat("scan.stat.folders", value: "\(snapshot.foldersScanned)")
                        stat("scan.stat.bytes", value: FileUtilities.formattedBytes(snapshot.bytesIndexed))
                        stat("scan.stat.elapsed", value: String(format: "%.0fs", snapshot.elapsed))
                        stat("scan.stat.denied", value: "\(snapshot.deniedCount)")
                        stat("scan.stat.errors", value: "\(snapshot.errorCount)")
                    }
                    .padding(.top, 8)
                }
            }
            HStack(spacing: 14) {
                Button(DeepScanCoordinator.shared.isPaused ? "scan.resume" : "scan.pause") {
                    if DeepScanCoordinator.shared.isPaused {
                        DeepScanCoordinator.shared.resume()
                    } else {
                        DeepScanCoordinator.shared.pause()
                    }
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                Button("scan.cancel", role: .destructive) {
                    DeepScanCoordinator.shared.cancel()
                    scanTask?.cancel()
                    isScanning = false
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stat(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var lastScanText: String? {
        guard let last = appState.sessionStore.scans.first else { return nil }
        return String(format: NSLocalizedString("hero.last_scan", comment: ""),
                      last.date.formatted(date: .abbreviated, time: .shortened))
    }

    private var permissionWarning: String? {
        let status = PermissionService.shared.snapshot.fullDiskAccess
        switch status {
        case .granted:
            return nil
        case .limited, .folderOnly, .denied:
            return NSLocalizedString("hero.deep_scan.permission", comment: "")
        case .unknown:
            return NSLocalizedString("hero.deep_scan.permission_not_determined", comment: "")
        }
    }

    private func privacyTruncated(_ path: String) -> String {
        guard path.count > 60 else { return path }
        return "…" + String(path.suffix(56))
    }

    private func runScan() {
        isScanning = true
        outcome = nil
        let scope = ScanScope(
            mode: .deep,
            volumes: Array(selectedVolumeIDs),
            includeHiddenFiles: includeHidden,
            includePackageContents: includePackageContents,
            hashDuplicates: true
        )
        // Security-scoped bookmarks stay active for the whole scan.
        let authorizedFolders = folderStore.activateScopes()
        appState.beginActivity(.scanning(detail: NSLocalizedString("hero.action.start_deep_scan", comment: "")))
        let stream = DeepScanCoordinator.shared.start(
            scope: scope,
            settings: appState.settings,
            volumes: volumes,
            authorizedFolders: authorizedFolders
        )

        scanTask = Task {
            for await event in stream {
                switch event {
                case .phaseChanged(let phase, let detail):
                    appState.activityPhase = .scanning(detail: detail ?? phase.title)
                case .progress(let snapshot):
                    currentSnapshot = snapshot
                    appState.progress = snapshot.fraction ?? 0
                case .outcome(let result):
                    isScanning = false
                    outcome = result
                    appState.lastOutcome = result
                    folderStore.deactivateScopes()
                    appState.sessionStore.recordScan(ScanHistoryRecord(
                        date: result.finishedAt,
                        mode: result.mode.rawValue,
                        scope: (scope.volumes + authorizedFolders.map { $0.path }).joined(separator: ", "),
                        duration: result.finishedAt.timeIntervalSince(result.startedAt),
                        itemsScanned: result.itemsScanned,
                        coveragePercent: ScanCoverageReport.coveragePercent(result.coverage),
                        provenance: result.provenance.rawValue,
                        candidatesBytes: result.safeBytes + result.reviewBytes,
                        applicationCount: result.applicationCount,
                        duplicateGroupCount: result.duplicateGroupCount
                    ))
                    appState.endActivity(message: result.coverage.summaryText)
                case .failed(let message):
                    isScanning = false
                    folderStore.deactivateScopes()
                    appState.endActivity(error: message)
                case .coverageUpdated, .inventoryBatch:
                    break
                }
            }
        }
    }
}
