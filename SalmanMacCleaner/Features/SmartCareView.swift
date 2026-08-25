//
//  SmartCareView.swift
//  SalmanMacCleaner
//
//  Smart Care is a read-only one-click health review. It measures storage,
//  Trash, developer caches, applications, background items and permissions,
//  then links each finding to the module that can explain it in detail.
//

import SwiftUI

struct SmartCareView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionService: PermissionService
    @State private var isChecking = false
    @State private var healthProgress = HealthCheckProgress()
    @State private var healthResult: HealthCheckResult?
    @State private var healthTask: Task<HealthCheckResult?, Never>?
    @State private var healthToken = UUID()

    var body: some View {
        Group {
            if let healthResult {
                HealthCheckResultsView(result: healthResult, onOpen: openModule, onRunAgain: runHealthCheck)
            } else if isChecking {
                HealthCheckProgressView(progress: healthProgress, onCancel: cancelHealthCheck)
            } else {
                HeroScreenView(
                    module: .smartCare,
                    isBusy: false,
                    lastScanText: lastCheckText,
                    permissionWarning: permissionWarning,
                    estimatedScope: NSLocalizedString("hero.smart_care.scope", comment: ""),
                    primaryAction: runHealthCheck,
                    selectors: { EmptyView() }
                )
            }
        }
        .onDisappear {
            healthToken = UUID()
            healthTask?.cancel()
        }
    }

    private var lastCheckText: String? {
        guard let last = appState.sessionStore.scans.first else { return nil }
        return String(format: NSLocalizedString("hero.last_scan", comment: ""),
                      last.date.formatted(date: .abbreviated, time: .shortened))
    }

    private var permissionWarning: String? {
        permissionService.snapshot.fullDiskAccess == .granted
            ? nil
            : permissionService.snapshot.fullDiskAccess.explanation
    }

    private func runHealthCheck() {
        healthTask?.cancel()
        let token = UUID()
        healthToken = token
        healthResult = nil
        isChecking = true
        healthProgress = HealthCheckProgress()
        appState.beginActivity(.scanning(detail: NSLocalizedString("health.checking", comment: "")))

        let permissionStatus = permissionService.snapshot.fullDiskAccess
        let worker = Task.detached(priority: .userInitiated) { () -> HealthCheckResult? in
            do {
                return try HealthCheckService.run(
                    permissionStatus: permissionStatus,
                    progress: { progress in
                        Task { @MainActor in
                            guard healthToken == token else { return }
                            // Progress is informational only; it cannot alter
                            // the read-only worker or cause cleanup.
                            healthProgress = progress
                            appState.progress = progress.fraction
                        }
                    },
                    isCancelled: { Task.isCancelled }
                )
            } catch {
                return nil
            }
        }
        healthTask = worker

        Task { @MainActor in
            let result = await worker.value
            guard healthToken == token else { return }
            healthTask = nil
            isChecking = false
            guard let result else {
                appState.endActivity()
                return
            }
            healthResult = result
            appState.endActivity(message: NSLocalizedString("health.completed", comment: ""))
        }
    }

    private func cancelHealthCheck() {
        healthTask?.cancel()
        healthTask = nil
        healthToken = UUID()
        isChecking = false
        healthProgress = HealthCheckProgress()
        appState.endActivity()
    }

    private func openModule(_ module: SidebarModule) {
        healthTask?.cancel()
        healthToken = UUID()
        appState.module = module
    }
}

private struct HealthCheckProgressView: View {
    let progress: HealthCheckProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 8) {
                Text("health.check_title")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                Text("health.check_read_only")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GlassSectionHeader("health.progress_title", systemImage: "waveform.path.ecg")
            VStack(alignment: .leading, spacing: 10) {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(AuroraPalette.cyan)
                HStack {
                    Text(progress.currentFactor?.title ?? NSLocalizedString("health.preparing", comment: ""))
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(Int(progress.fraction * 100))%")
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AuroraPalette.cyan)
                }
                Text(progress.detail ?? NSLocalizedString("health.reading", comment: ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(String(format: NSLocalizedString("health.factor_count", comment: ""),
                            progress.completedFactors, progress.totalFactors))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(18)
            .glassCard()

            HStack {
                Button("common.cancel", action: onCancel)
                    .buttonStyle(AuroraSecondaryButtonStyle())
                Text("health.no_changes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(34)
        .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity)
    }
}

private struct HealthCheckResultsView: View {
    let result: HealthCheckResult
    let onOpen: (SidebarModule) -> Void
    let onRunAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("health.results_title")
                        .font(.title.weight(.bold))
                    Text("health.results_read_only")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(LocalizedStringKey(result.overallStatus.title), kind: statusKind(result.overallStatus))
            }

            PermissionBannerView(message: result.coverageMessage, systemImage: "lock.shield")

            List(result.factors) { factor in
                factorRow(factor)
                    .listRowInsets(EdgeInsets(top: 5, leading: 0, bottom: 5, trailing: 0))
                    .listRowBackground(Color.clear)
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
            .frame(maxHeight: .infinity)

            HStack {
                Button("health.run_again", action: onRunAgain)
                    .buttonStyle(AuroraSecondaryButtonStyle())
                Spacer()
                Text(result.finishedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(22)
    }

    private func factorRow(_ factor: HealthCheckFactor) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: factor.id == .permissions ? "lock.shield" : "checkmark.seal")
                .font(.title3)
                .foregroundStyle(color(for: factor.status))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(factor.id.title)
                        .font(.callout.weight(.semibold))
                    StatusPill(LocalizedStringKey(factor.status.title), kind: statusKind(factor.status))
                    Spacer()
                }
                Text(factor.summary)
                    .font(.callout)
                Text(factor.evidence)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let destination = factor.id.destination {
                Button {
                    onOpen(destination)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .accessibilityLabel("health.open_detail")
                }
                .buttonStyle(.plain)
                .help("health.open_detail")
            }
        }
        .padding(14)
        .glassCard()
    }

    private func statusKind(_ status: HealthCheckStatus) -> StatusPill.Kind {
        switch status {
        case .good: return .ok
        case .attention: return .warning
        case .unavailable: return .unavailable
        }
    }

    private func color(for status: HealthCheckStatus) -> Color {
        switch status {
        case .good: return AuroraPalette.success
        case .attention: return AuroraPalette.amber
        case .unavailable: return .secondary
        }
    }
}
