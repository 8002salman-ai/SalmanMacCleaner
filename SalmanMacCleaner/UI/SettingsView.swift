//
//  SettingsView.swift
//  SalmanMacCleaner
//
//  Organized settings: General, Scanning, Safety, Permissions, Updates,
//  Advanced and About. All sections use glass cards on the Aurora surface.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var permissionService: PermissionService
    @State private var newExclusion = ""

    private enum SectionID: Hashable {
        case general, scanning, safety, permissions, updates, advanced, about
    }

    private var sections: [(SectionID, LocalizedStringKey, String)] {
        [
            (.general, "settings.section.general", "gearshape"),
            (.scanning, "settings.section.scanning", "magnifyingglass"),
            (.safety, "settings.section.safety", "shield.lefthalf.filled"),
            (.permissions, "settings.section.permissions", "lock.shield"),
            (.updates, "settings.section.updates", "arrow.down.circle"),
            (.advanced, "settings.section.advanced", "wrench.and.screwdriver"),
            (.about, "settings.section.about", "info.circle")
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.0) { section in
                    settingsCard(title: section.1, icon: section.2) {
                        content(for: section.0)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func content(for section: SectionID) -> some View {
        switch section {
        case .general:
            Toggle("settings.launch_at_login", isOn: .constant(false))
                .toggleStyle(.checkbox)
                .disabled(true)
                .help(Text("settings.launch_at_login.help"))
            Picker("settings.appearance", selection: $appState.settings.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 380)
            Toggle("settings.animations", isOn: $appState.settings.animationsEnabled)
                .toggleStyle(.checkbox)
        case .scanning:
            Picker("settings.default_mode", selection: $appState.settings.defaultScanMode) {
                ForEach(ScanMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            .frame(maxWidth: 320)
            Toggle("settings.include_hidden", isOn: $appState.settings.includeHiddenFiles)
                .toggleStyle(.checkbox)
            Toggle("settings.include_packages", isOn: $appState.settings.includePackageContents)
                .toggleStyle(.checkbox)
            Toggle("settings.incremental_scans", isOn: $appState.settings.incrementalScans)
                .toggleStyle(.checkbox)
            Toggle("settings.avoid_battery", isOn: $appState.settings.avoidIntensiveWorkOnBattery)
                .toggleStyle(.checkbox)
            Stepper(value: $appState.settings.maxScanDepth, in: 1...12) {
                Text(String(format: NSLocalizedString("settings.depth", comment: ""), appState.settings.maxScanDepth))
            }
            Stepper(value: $appState.settings.minFileAgeDays, in: 0...365, step: 7) {
                Text(String(format: NSLocalizedString("settings.min_age", comment: ""), appState.settings.minFileAgeDays))
            }
        case .safety:
            Toggle(isOn: $appState.settings.dryRun) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.dryrun").font(.headline)
                    Text("settings.dryrun.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle(isOn: $appState.settings.confirmBeforeCleanup) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.confirm").font(.headline)
                    Text("settings.confirm.description")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            Toggle("settings.smart_selection", isOn: $appState.settings.smartSelection)
                .toggleStyle(.checkbox)
            Toggle("settings.redact_paths", isOn: $appState.settings.redactPaths)
                .toggleStyle(.checkbox)
            ignoreListSection
        case .permissions:
            HStack(spacing: 10) {
                StatusPill(LocalizedStringKey(permissionService.snapshot.fullDiskAccess.title), kind: fdaKind)
                Spacer()
                Button("permissions.open_fda_settings") {
                    permissionService.openFullDiskAccessSettings()
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                Button("permissions.recheck") {
                    permissionService.recheck()
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }
            Text(permissionService.snapshot.coverageImpact)
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider().overlay(Color.white.opacity(0.08))
            AuthorizedFoldersSection(store: FolderAuthorizationsStore.shared)
        case .updates:
            Toggle("settings.auto_check_updates", isOn: $appState.settings.autoCheckUpdates)
                .toggleStyle(.checkbox)
            Toggle("settings.auto_download_updates", isOn: $appState.settings.autoDownloadUpdates)
                .toggleStyle(.checkbox)
            Picker("settings.update_channel", selection: $appState.settings.updateChannel) {
                Text("updater.channel.stable").tag("stable")
                Text("updater.channel.beta").tag("beta")
            }
            .frame(maxWidth: 300)
            HStack {
                Text(SparkleUpdaterController.currentVersion)
                    .font(.callout.monospacedDigit())
                Spacer()
                Button("updater.check_now") {
                    SparkleUpdaterController.shared.checkForUpdates()
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                .disabled(!SparkleUpdaterController.isConfigured)
            }
            Text(SparkleUpdaterController.isConfigured
                 ? NSLocalizedString("updater.configured", comment: "")
                 : SparkleUpdaterController.unconfiguredReason)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .advanced:
            Button("settings.force_full_rescan") {
                appState.sessionStore.clearAll()
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            Button("settings.reset", role: .destructive) {
                appState.settings.resetAll()
                appState.ignoreList.removeAll()
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
        case .about:
            HStack(spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("app.name").font(.title3.weight(.bold))
                    Text(SparkleUpdaterController.currentVersion)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("about.architecture")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("about.license")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Button("about.github") {
                        guard let url = URL(string: "https://github.com/8002salman-ai/SalmanMacCleaner") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    Button("about.license_view") {
                        if let path = Bundle.main.path(forResource: "LICENSE", ofType: nil) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                    }
                }
                .buttonStyle(.link)
            }
        }
    }

    private var ignoreListSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("settings.exclusion.placeholder", text: $newExclusion)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addExclusion)
                Button("settings.exclusion.add", action: addExclusion)
                    .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if appState.ignoreList.rules.isEmpty {
                Text("settings.exclusion.empty")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.ignoreList.rules) { rule in
                    HStack {
                        Image(systemName: rule.kind == .exactPath ? "equal" : "text.magnifyingglass")
                            .foregroundStyle(.tertiary)
                        Text(rule.pattern)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            appState.ignoreList.remove(id: rule.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func settingsCard<Content: View>(
        title: LocalizedStringKey,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            GlassSectionHeader(title, systemImage: icon)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var fdaKind: StatusPill.Kind {
        switch permissionService.snapshot.fullDiskAccess {
        case .granted: return .ok
        case .limited, .folderOnly: return .warning
        case .denied: return .warning
        case .unknown: return .info
        }
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        appState.ignoreList.add(pattern: trimmed, kind: trimmed.contains("/") ? .exactPath : .contains)
        newExclusion = ""
    }
}
