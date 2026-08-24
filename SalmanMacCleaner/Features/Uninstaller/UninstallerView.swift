//
//  UninstallerView.swift
//  SalmanMacCleaner
//
//  Cautious application uninstaller: lists only the user's own apps with
//  confidence labels, blocks running apps, and removes via the trash-only
//  engine after a second confirmation.
//

import SwiftUI

struct UninstallerView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = UninstallerViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SafetyNoteView(text: "uninstaller.safety_note")

            HStack(spacing: 12) {
                Button {
                    viewModel.refresh()
                } label: {
                    Label("uninstaller.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(viewModel.isLoading)
                if viewModel.isLoading {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Text(String(format: NSLocalizedString("uninstaller.count", comment: ""), viewModel.candidates.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
            }

            if viewModel.candidates.isEmpty && !viewModel.isLoading {
                EmptyStateView(
                    systemImage: "app.badge",
                    title: "uninstaller.empty.title",
                    message: "uninstaller.empty.message"
                )
            } else {
                List(viewModel.filteredCandidates) { candidate in
                    UninstallCandidateRow(
                        candidate: candidate,
                        selected: viewModel.selectedCandidateID == candidate.id
                    ) {
                        viewModel.selectedCandidateID = candidate.id
                    }
                }
                .listStyle(.inset)
            }

            if let candidate = viewModel.selectedCandidate {
                Divider()
                selectedDetail(candidate)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle(AppSection.uninstaller.title)
        .searchable(text: $viewModel.searchText, prompt: Text("uninstaller.search.prompt"))
        .onAppear {
            if viewModel.candidates.isEmpty { viewModel.refresh() }
        }
        .cleanupConfirmation(
            isPresented: $viewModel.showConfirmation,
            config: ConfirmationDialogConfig(
                title: "uninstaller.confirm.title",
                message: String(format: NSLocalizedString("uninstaller.confirm.message", comment: ""),
                                 viewModel.selectedCandidate?.name ?? ""),
                confirmTitle: "common.confirm.trash",
                destructive: !appState.settings.dryRun
            ),
            onConfirm: {
                viewModel.performCleanup(settings: appState.settings, history: appState.history, activity: appState)
            }
        )
    }

    @ViewBuilder
    private func selectedDetail(_ candidate: UninstallCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(candidate.name).font(.headline)
                ConfidenceBadge(confidence: candidate.confidence)
                if let version = candidate.version {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(FileUtilities.formattedBytes(candidate.totalSize))
                    .font(.callout.monospacedDigit())
            }

            if candidate.isRunning {
                PermissionBannerView(
                    message: NSLocalizedString("uninstaller.running_warning", comment: ""),
                    systemImage: "play.circle.fill"
                )
            }

            if !candidate.supportItems.isEmpty {
                DisclosureGroup {
                    ForEach(candidate.supportItems) { item in
                        HStack {
                            Image(systemName: item.isDirectory ? "folder" : "doc")
                                .foregroundStyle(.secondary)
                            Text(item.path)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(FileUtilities.formattedBytes(item.size))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                } label: {
                    Text(String(format: NSLocalizedString("uninstaller.support_items", comment: ""), candidate.supportItems.count))
                        .font(.callout)
                }
            }

            HStack {
                Button {
                    viewModel.showConfirmation = true
                } label: {
                    Label("common.preview_cleanup", systemImage: "eye")
                }
                Button(role: .destructive) {
                    viewModel.showConfirmation = true
                } label: {
                    Label("common.trash_selected", systemImage: "trash")
                }
                .disabled(appState.settings.dryRun || candidate.isRunning)
                .help(Text(LocalizedStringKey(candidate.isRunning ? "uninstaller.running_warning" : "common.trash_selected.help")))
                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct UninstallCandidateRow: View {
    let candidate: UninstallCandidate
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: candidate.isRunning ? "play.circle" : "app.dashed")
                    .foregroundStyle(candidate.isRunning ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(candidate.name)
                        .font(.callout)
                    Text(candidate.bundlePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                ConfidenceBadge(confidence: candidate.confidence)
                Text(FileUtilities.formattedBytes(candidate.totalSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        .accessibilityLabel(candidate.name)
    }
}
