//
//  AppUpdaterView.swift
//  SalmanMacCleaner
//
//  Honest updater audit. Self-updates are delegated to the existing Sparkle
//  integration only when its signed feed/key is configured. Third-party
//  updates are not fabricated from app names or downloaded files.
//

import SwiftUI
import AppKit

struct AppUpdaterView: View {
    @EnvironmentObject private var appState: AppState
    @State private var state = SparkleUpdaterController.shared.state
    @State private var availableVersion: String?
    private let audit = SparkleUpdaterController.currentAudit

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("updater.title")
                        .font(.title2.weight(.semibold))
                    Text("updater.subtitle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(LocalizedStringKey(state.title), kind: stateKind)
            }
            .padding(14)
            .glassCard()

            selfUpdateCard
            thirdPartyCard
        }
        .padding(18)
        .onReceive(SparkleUpdaterController.shared.$state) { state = $0 }
        .onReceive(SparkleUpdaterController.shared.$availableVersion) { availableVersion = $0 }
    }

    private var selfUpdateCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader("updater.self_title", systemImage: "arrow.down.circle")
            HStack(alignment: .top, spacing: 14) {
                ModuleArtwork(module: .appUpdater, size: 88)
                VStack(alignment: .leading, spacing: 6) {
                    Text(audit.installedVersion)
                        .font(.title3.weight(.bold).monospacedDigit())
                    auditRow("updater.installed_version", audit.installedVersion)
                    auditRow("updater.available_version", availableVersion ?? NSLocalizedString("updater.not_available", comment: ""))
                    auditRow("updater.release_source", audit.releaseSource)
                    auditRow("updater.architecture", audit.architecture)
                    auditRow("updater.signature", audit.signatureStatus)
                    auditRow("updater.notarization", audit.notarizationStatus)
                    Text(audit.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
            }
            HStack(spacing: 10) {
                Button { checkNow() } label: {
                    Label("updater.check_now", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .disabled(!SparkleUpdaterController.isConfigured)
                .help(Text("updater.check_now.help"))
                Toggle("settings.auto_check_updates", isOn: $appState.settings.autoCheckUpdates)
                    .toggleStyle(.checkbox)
                Toggle("settings.auto_download_updates", isOn: $appState.settings.autoDownloadUpdates)
                    .toggleStyle(.checkbox)
            }
        }
        .padding(14)
        .glassCard()
    }

    private var thirdPartyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            GlassSectionHeader("updater.third_party_title", systemImage: "square.grid.2x2")
            Text("updater.third_party_unavailable")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://github.com/8002salman-ai/SalmanMacCleaner/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("updater.open_release_page", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                .help(Text("updater.open_release_page.help"))
                Text("updater.no_silent_install")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func auditRow(_ key: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.caption).foregroundStyle(.primary).lineLimit(1)
        }
    }

    private var stateKind: StatusPill.Kind {
        switch state {
        case .unconfigured: return .unavailable
        case .checking: return .info
        case .upToDate: return .ok
        case .updateAvailable: return .warning
        case .failed: return .warning
        }
    }

    private func checkNow() {
        SparkleUpdaterController.shared.checkForUpdates()
        state = SparkleUpdaterController.shared.state
    }
}
