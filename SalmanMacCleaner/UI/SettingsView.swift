//
//  SettingsView.swift
//  SalmanMacCleaner
//
//  Settings: thresholds, exclusions, scan depth, categories and appearance,
//  plus the master dry-run toggle and history export.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var newExclusion = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Safety
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle(isOn: $appState.settings.dryRun) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.dryrun")
                                    .font(.headline)
                                Text("settings.dryrun.description")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("settings.dryRun")

                        Toggle(isOn: $appState.settings.confirmBeforeCleanup) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("settings.confirm")
                                    .font(.headline)
                                Text("settings.confirm.description")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                    }
                    .padding(8)
                } label: {
                    Label("settings.safety.title", systemImage: "shield.lefthalf.filled")
                }

                // Scanning
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("settings.threshold")
                            Spacer()
                            Slider(value: $appState.settings.largeFileThresholdMB, in: 50...2000, step: 50)
                                .frame(width: 220)
                            Text(String(format: "%.0f MB", appState.settings.largeFileThresholdMB))
                                .font(.callout.monospacedDigit())
                                .frame(width: 80, alignment: .trailing)
                        }

                        Stepper(value: $appState.settings.maxScanDepth, in: 1...12) {
                            Text(String(format: NSLocalizedString("settings.depth", comment: ""), appState.settings.maxScanDepth))
                        }

                        Stepper(value: $appState.settings.devCacheMaxAgeDays, in: 0...365, step: 7) {
                            Text(String(format: NSLocalizedString("settings.dev_cache_age", comment: ""), appState.settings.devCacheMaxAgeDays))
                        }

                        Toggle(isOn: $appState.settings.scanDevCachesOnLaunch) {
                            Text("settings.scan_on_launch")
                        }
                        .toggleStyle(.checkbox)

                        Picker("settings.default_category", selection: $appState.settings.defaultScannerCategory) {
                            ForEach(DeveloperCacheCategory.allCases) { category in
                                Text(category.title).tag(category.rawValue)
                            }
                        }
                        .frame(maxWidth: 320)
                    }
                    .padding(8)
                } label: {
                    Label("settings.scanning.title", systemImage: "magnifyingglass")
                }

                // Exclusions
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            TextField("settings.exclusion.placeholder", text: $newExclusion)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(addExclusion)
                            Button("settings.exclusion.add", action: addExclusion)
                                .disabled(newExclusion.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if appState.settings.excludedPatterns.isEmpty {
                            Text("settings.exclusion.empty")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(appState.settings.excludedPatterns, id: \.self) { pattern in
                                HStack {
                                    Text(pattern)
                                        .font(.callout)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button {
                                        appState.settings.excludedPatterns.removeAll { $0 == pattern }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundStyle(.secondary)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("settings.exclusions.title", systemImage: "nosign")
                }

                // Appearance
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("settings.appearance", selection: $appState.settings.appearance) {
                            ForEach(AppearanceMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 360)
                    }
                    .padding(8)
                } label: {
                    Label("settings.appearance.title", systemImage: "paintbrush")
                }

                // Data
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(String(format: NSLocalizedString("settings.history.count", comment: ""), appState.history.entries.count))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("settings.export.json") {
                                _ = appState.history.exportInteractive(format: .json)
                            }
                            Button("settings.export.csv") {
                                _ = appState.history.exportInteractive(format: .csv)
                            }
                            Button("settings.history.clear", role: .destructive) {
                                appState.history.clear()
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("settings.data.title", systemImage: "externaldrive")
                }

                // Reset
                HStack {
                    Button("settings.reset", role: .destructive) {
                        appState.settings.resetAll()
                    }
                    .help("settings.reset.help")
                    Spacer()
                }
            }
            .padding(20)
        }
        .navigationTitle(AppSection.settings.title)
    }

    private func addExclusion() {
        let trimmed = newExclusion.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !appState.settings.excludedPatterns.contains(trimmed) {
            appState.settings.excludedPatterns.append(trimmed)
        }
        newExclusion = ""
    }
}
