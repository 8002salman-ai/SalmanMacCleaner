//
//  AppUpdaterView.swift
//  SalmanMacCleaner
//
//  App Updater. Two concepts, kept strictly separate:
//  A. Salman Mac Cleaner self-update via Sparkle 2 (only active when a real
//     signed feed + EdDSA public key are configured).
//  B. Third-party application update inventory — deliberately unavailable
//     until a trustworthy update source exists. No version data is invented.
//

import SwiftUI
import AppKit

struct AppUpdaterView: View {
    @EnvironmentObject private var appState: AppState
    @State private var state = SparkleUpdaterController.shared.state

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                selfUpdateSection
                thirdPartySection
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
    }

    private var selfUpdateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("updater.self_title", systemImage: "arrow.down.circle")

            HStack(spacing: 14) {
                ModuleArtwork(module: .appUpdater, size: 130)
                VStack(alignment: .leading, spacing: 8) {
                    Text(SparkleUpdaterController.currentVersion)
                        .font(.title2.weight(.bold))
                    Text(SparkleUpdaterController.isConfigured
                         ? NSLocalizedString("updater.configured", comment: "")
                         : SparkleUpdaterController.unconfiguredReason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button {
                            checkNow()
                        } label: {
                            Label("updater.check_now", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(AuroraPrimaryButtonStyle())
                        .disabled(!SparkleUpdaterController.isConfigured)

                        Toggle("settings.auto_check_updates", isOn: $appState.settings.autoCheckUpdates)
                            .toggleStyle(.checkbox)
                        Toggle("settings.auto_download_updates", isOn: $appState.settings.autoDownloadUpdates)
                            .toggleStyle(.checkbox)
                    }
                }
                Spacer()
            }
            .padding(18)
            .glassCard()

            StatusPill(LocalizedStringKey(state.title), kind: stateKind)
        }
    }

    private var thirdPartySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader("updater.third_party_title", systemImage: "square.grid.2x2")
            PermissionBannerView(
                message: NSLocalizedString("updater.third_party_unavailable", comment: ""),
                systemImage: "info.circle"
            )
        }
        .padding(18)
        .glassCard()
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
