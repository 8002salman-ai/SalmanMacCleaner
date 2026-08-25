//
//  SecurityAuditView.swift
//  SalmanMacCleaner
//
//  Honest Security Audit. No fake malware detection: this module checks
//  Full Disk Access state, quarantine-flagged applications, broken or
//  unsigned launch agents, and links to macOS security configuration.
//  A file is never called malware based on its name.
//

import SwiftUI
import AppKit
import Security

struct SecurityAuditView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionService: PermissionService
    @State private var quarantinedApps: [AppRecord] = []
    @State private var unsignedAgents: [StartupItemDetail] = []
    @State private var brokenAgents: [StartupItemDetail] = []
    @State private var isAuditing = false
    @State private var lastAudit: Date?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("security.no_malware_claim")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                auditSection(
                    title: "security.fda_title",
                    icon: "lock.shield",
                    content: {
                        HStack(spacing: 10) {
                            StatusPill(LocalizedStringKey(permissionService.snapshot.fullDiskAccess.title), kind: fdaKind)
                            Spacer()
                            Button("security.open_fda") {
                                permissionService.openFullDiskAccessSettings()
                            }
                            .buttonStyle(AuroraSecondaryButtonStyle())
                            Button("security.recheck") {
                                permissionService.recheck()
                            }
                            .buttonStyle(AuroraSecondaryButtonStyle())
                        }
                        Text(permissionService.snapshot.fullDiskAccess.explanation)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                )

                auditSection(
                    title: "security.quarantine_title",
                    icon: "doc.badge.gearshape",
                    content: {
                        if quarantinedApps.isEmpty {
                            Label("security.quarantine_none", systemImage: "checkmark.circle")
                                .foregroundStyle(AuroraPalette.success)
                        } else {
                            ForEach(quarantinedApps) { app in
                                HStack {
                                    Text(app.name)
                                    Spacer()
                                    Text("security.quarantined_badge")
                                        .font(.caption)
                                        .foregroundStyle(AuroraPalette.amber)
                                }
                            }
                        }
                    }
                )

                auditSection(
                    title: "security.agents_title",
                    icon: "gearshape.2",
                    content: {
                        if unsignedAgents.isEmpty && brokenAgents.isEmpty {
                            Label("security.agents_ok", systemImage: "checkmark.circle")
                                .foregroundStyle(AuroraPalette.success)
                        } else {
                            if !brokenAgents.isEmpty {
                                Text(String(format: NSLocalizedString("security.broken_agents", comment: ""), brokenAgents.count))
                                    .font(.callout)
                                    .foregroundStyle(AuroraPalette.coral)
                                ForEach(brokenAgents.prefix(5)) { agent in
                                    Text(agent.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            if !unsignedAgents.isEmpty {
                                Text(String(format: NSLocalizedString("security.unsigned_agents", comment: ""), unsignedAgents.count))
                                    .font(.callout)
                                    .foregroundStyle(AuroraPalette.amber)
                                ForEach(unsignedAgents.prefix(5)) { agent in
                                    Text(agent.name)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                )

                auditSection(
                    title: "security.links_title",
                    icon: "link",
                    content: {
                        HStack(spacing: 10) {
                            securityLink("security.link_gatekeeper", url: "x-apple.systempreferences:com.apple.preference.security?General")
                            securityLink("security.link_filevault", url: "x-apple.systempreferences:com.apple.preference.security?FileVault")
                            securityLink("security.link_privacy", url: "x-apple.systempreferences:com.apple.preference.security?Privacy")
                        }
                    }
                )

                HStack {
                    Button {
                        runAudit()
                    } label: {
                        if isAuditing {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("hero.action.run_audit", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(AuroraPrimaryButtonStyle())
                    .disabled(isAuditing)
                    if let lastAudit {
                        Text(String(format: NSLocalizedString("security.last_audit", comment: ""),
                                    lastAudit.formatted(date: .abbreviated, time: .shortened)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if quarantinedApps.isEmpty { runAudit() }
        }
    }

    private var fdaKind: StatusPill.Kind {
        switch permissionService.snapshot.fullDiskAccess {
        case .granted: return .ok
        case .limited, .folderOnly: return .warning
        case .denied: return .warning
        case .unknown: return .info
        }
    }

    private func securityLink(_ title: LocalizedStringKey, url: String) -> some View {
        Button {
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func auditSection<Content: View>(
        title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader(title, systemImage: icon)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func runAudit() {
        isAuditing = true
        Task.detached(priority: .userInitiated) {
            let apps = ApplicationInventoryService.discoverApplications()
            let quarantined = apps.filter { $0.isQuarantined }

            let agents = StartupManager.discover()
            let unsigned = agents.filter { agent in
                guard let executable = agent.executable, executable.hasPrefix("/"),
                      FileManager.default.fileExists(atPath: executable) else { return false }
                var staticCode: SecStaticCode?
                guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: executable) as CFURL, [], &staticCode) == errSecSuccess,
                      let code = staticCode else {
                    return true
                }
                return SecStaticCodeCheckValidity(code, SecCSFlags(), nil) != errSecSuccess
            }
            let broken = agents.filter { $0.isBroken }

            await MainActor.run {
                quarantinedApps = quarantined
                unsignedAgents = unsigned
                brokenAgents = broken
                lastAudit = Date()
                isAuditing = false
            }
        }
    }
}
