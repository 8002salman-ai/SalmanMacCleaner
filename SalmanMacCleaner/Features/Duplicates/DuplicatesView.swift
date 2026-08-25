//
//  DuplicatesView.swift
//  SalmanMacCleaner
//
//  Duplicate Finder UI: explicit folder selection, streaming SHA-256 scan with
//  progress, grouped results with a keeper per group, and selected-only
//  trash cleanup.
//

import SwiftUI

struct DuplicatesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DuplicatesViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SafetyNoteView(text: "duplicates.safety_note")

            HStack(spacing: 12) {
                Button {
                    viewModel.folderPickerPresented = true
                } label: {
                    Label("duplicates.choose_folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                if !viewModel.roots.isEmpty {
                    Text(viewModel.roots.joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("common.clear", role: .destructive) {
                        viewModel.reset()
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button {
                    viewModel.startScan(settings: appState.settings, coordinator: ScanCoordinator.shared, activity: appState)
                } label: {
                    if viewModel.isScanning {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("duplicates.scan", systemImage: "doc.on.doc")
                    }
                }
                .disabled(viewModel.roots.isEmpty || viewModel.isScanning)
            }

            if viewModel.isScanning {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                Text(viewModel.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = viewModel.errorMessage {
                PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
            }

            if !viewModel.groups.isEmpty {
                resultsView()
            } else if !viewModel.isScanning && viewModel.hasRun && viewModel.roots.isEmpty == false {
                EmptyStateView(
                    systemImage: "sparkles",
                    title: "duplicates.empty.title",
                    message: "duplicates.empty.message"
                )
            } else if viewModel.roots.isEmpty {
                EmptyStateView(
                    systemImage: "doc.on.doc",
                    title: "duplicates.prompt.title",
                    message: "duplicates.prompt.message"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle(SidebarModule.duplicates.title)
        .searchable(text: $viewModel.searchText, prompt: Text("search.items.prompt"))
        .toolbar {
            ToolbarItemGroup {
                if !viewModel.selection.isEmpty {
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
                    .disabled(appState.settings.dryRun)
                }
            }
        }
        .cleanupConfirmation(
            isPresented: $viewModel.showConfirmation,
            config: .standard(
                itemCount: viewModel.selection.count,
                totalBytes: viewModel.selectedBytes,
                destructive: !appState.settings.dryRun
            ),
            onConfirm: {
                viewModel.performCleanup(settings: appState.settings, history: appState.history, activity: appState)
            }
        )
        .sheet(isPresented: $viewModel.folderPickerPresented) {
            FolderPickerView(message: "duplicates.picker.message") { url in
                viewModel.addRoot(url)
            }
        }
    }

    @ViewBuilder
    private func resultsView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: NSLocalizedString("duplicates.results.summary", comment: ""),
                            viewModel.groups.count, FileUtilities.formattedBytes(viewModel.totalReclaimable)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if viewModel.groups.contains(where: { $0.containsHardLinks }) {
                    Label("duplicates.hardlink_note", systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Text(NSLocalizedString("duplicates.hardlink_note.help", comment: "")))
                }
            }

            SelectionSummaryBar(
                selectedCount: viewModel.selection.count,
                selectedBytes: viewModel.selectedBytes,
                previewOnly: appState.settings.dryRun
            )

            List(viewModel.visibleGroups) { group in
                GroupDisclosureRow(
                    group: group,
                    selection: $viewModel.selection,
                    searchText: viewModel.searchText
                )
            }
            .listStyle(.inset)
        }
    }
}

struct GroupDisclosureRow: View {
    let group: DuplicateGroup
    @Binding var selection: Set<UUID>
    let searchText: String

    var body: some View {
        DisclosureGroup {
            ForEach(group.removableFiles) { file in
                Toggle(isOn: binding(for: file.id)) {
                    ItemRowLabel(
                        name: file.name,
                        detail: file.path,
                        size: file.size
                    )
                }
                .toggleStyle(.checkbox)
                .help(Text(file.path))
            }
            if let keeper = group.keeper {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text(String(format: NSLocalizedString("duplicates.keeper", comment: ""), keeper.name))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(FileUtilities.formattedBytes(keeper.size))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }
        } label: {
            HStack {
                Image(systemName: "doc.on.doc.fill")
                    .foregroundStyle(.tint)
                Text("\(group.files.count) × \(FileUtilities.formattedBytes(group.size))")
                    .font(.callout.monospacedDigit())
                Spacer()
                Text(FileUtilities.formattedBytes(group.reclaimableBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if group.hash.count > 8 {
                    Text(String(group.hash.prefix(8)))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { selected in
                if selected { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}
