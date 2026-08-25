//
//  ContentView.swift
//  SalmanMacCleaner
//
//  Root layout: Aurora background, premium sidebar, per-module detail with
//  hero → results transitions, and a top-right status area (permissions,
//  updates, notifications).
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 300)
        } detail: {
            ZStack {
                AuroraBackground(seed: appState.module.artworkSeed) {
                    moduleView
                        .id(appState.module)
                        .transition(accessibility.reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.985)))
                }
            }
            .animation(.easeInOut(duration: accessibility.reduceMotion ? 0 : 0.28), value: appState.module)
        }
        .navigationTitle(appState.module.title)
        .onAppear {
            AppStateLocator.shared = appState
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                StatusAreaView()
                ActivityToolbarView()
            }
        }
    }

    @ViewBuilder
    private var moduleView: some View {
        switch appState.module {
        case .smartCare: SmartCareView()
        case .deepScan: DeepScanView()
        case .systemJunk: SystemJunkView()
        case .trashBins: TrashBinsView()
        case .appLeftovers: AppLeftoversView()
        case .developerCaches: DeveloperCachesView()
        case .spaceLens: SpaceLensView()
        case .largeOldFiles: LargeOldFilesView()
        case .duplicates: DuplicatesView()
        case .myClutter: MyClutterView()
        case .applications: ApplicationsView()
        case .uninstaller: UninstallerView()
        case .appUpdater: AppUpdaterView()
        case .startupItems: StartupItemsView()
        case .performance: PerformanceView()
        case .securityAudit: SecurityAuditView()
        case .permissions: PermissionsView()
        case .myTools: MyToolsView()
        case .activityHistory: ActivityHistoryView()
        case .settings: SettingsView()
        }
    }
}

/// Top-right status pills: permission state + update availability.
struct StatusAreaView: View {
    @EnvironmentObject private var permissionService: PermissionService
    @EnvironmentObject private var appState: AppState
    @State private var updateAvailable = false

    var body: some View {
        HStack(spacing: 8) {
            Text(displayVersion)
                .font(.callout.monospacedDigit().weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.thinMaterial, in: Capsule())
                .help("SalmanMacCleaner version \(displayVersion)")

            StatusPill(LocalizedStringKey(permissionService.snapshot.fullDiskAccess.title),
                       kind: pillKind)
            if updateAvailable {
                Button {
                    appState.module = .appUpdater
                } label: {
                    StatusPill("status.update_available", kind: .warning)
                }
                .buttonStyle(.plain)
            }
        }
        .task {
            if SparkleUpdaterController.isConfigured {
                updateAvailable = await SparkleUpdaterController.hasPendingUpdate()
            }
        }
        .onReceive(SparkleUpdaterController.shared.$availableVersion) { version in
            updateAvailable = version != nil
        }
    }

    private var displayVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
        return "v\(version) (\(build))"
    }

    private var pillKind: StatusPill.Kind {
        switch permissionService.snapshot.fullDiskAccess {
        case .granted: return .ok
        case .limited, .folderOnly: return .warning
        case .denied: return .warning
        case .unknown: return .info
        }
    }
}
