//
//  PermissionsView.swift
//  SalmanMacCleaner
//
//  Full Disk Access onboarding: explains what FDA enables, what SIP keeps
//  protected, that macOS requires the user to grant access manually, and the
//  coverage impact of continuing with a limited scan. Includes
//  "Open Full Disk Access Settings", "Recheck Permission" and
//  "Continue with Limited Scan" actions.
//

import SwiftUI
import AppKit

struct PermissionsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionService: PermissionService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                statusCard
                explanationCard
                actionsCard
            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if permissionService.snapshot.lastCheck == .distantPast {
                permissionService.recheck()
            }
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("permissions.status_title", systemImage: "lock.shield")
            HStack(spacing: 14) {
                ModuleArtwork(module: .permissions, size: 120)
                VStack(alignment: .leading, spacing: 8) {
                    StatusPill(LocalizedStringKey(permissionService.snapshot.fullDiskAccess.title), kind: statusKind)
                    Text(permissionService.snapshot.fullDiskAccess.explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(String(format: NSLocalizedString("permissions.last_check", comment: ""),
                                permissionService.snapshot.lastCheck.formatted(date: .abbreviated, time: .shortened)))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
        }
        .padding(18)
        .glassCard()
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader("permissions.why_title", systemImage: "questionmark.circle")
            Text("permissions.why_fda")
                .font(.callout)
            Text("permissions.why_sip")
                .font(.callout)
            Text("permissions.why_manual")
                .font(.callout)
                .foregroundStyle(AuroraPalette.amber)
        }
        .padding(18)
        .glassCard()
    }

    private var actionsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            GlassSectionHeader("permissions.actions_title", systemImage: "slider.horizontal.3")
            HStack(spacing: 12) {
                Button {
                    permissionService.openFullDiskAccessSettings()
                } label: {
                    Label("permissions.open_fda_settings", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())

                Button {
                    permissionService.recheck()
                } label: {
                    Label("permissions.recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())

                Button {
                    appState.module = .deepScan
                } label: {
                    Label("permissions.continue_limited", systemImage: "forward")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }
            Text("permissions.coverage_impact")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(permissionService.snapshot.coverageImpact)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(18)
        .glassCard()
    }

    private var statusKind: StatusPill.Kind {
        switch permissionService.snapshot.fullDiskAccess {
        case .likelyFullAccess: return .ok
        case .limitedAccess, .accessDenied: return .warning
        case .notDetermined: return .info
        }
    }
}
