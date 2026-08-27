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
    @StateObject private var folderStore = FolderAuthorizationsStore.shared

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
                Button {
                    folderStore.presentFolderPicker { url in
                        viewModel.addAuthorizedRoot(url)
                    }
                } label: {
                    Label("duplicates.choose_external", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.borderless)
                .help(Text("duplicates.choose_external.help"))

                if !viewModel.roots.isEmpty {
                    Text(viewModel.roots.map(\.path).joined(separator: ", "))
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
                    .tint(AuroraPalette.cyan)
                HStack(spacing: 10) {
                    Text(viewModel.detail ?? NSLocalizedString("duplicates.phase.prepare", comment: ""))
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(String(format: NSLocalizedString("duplicates.scan_stats", comment: ""),
                                viewModel.scanStats.filesConsidered,
                                FileUtilities.formattedBytes(viewModel.scanStats.bytesConsidered),
                                Self.formatElapsed(viewModel.scanElapsed)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("duplicates.cancel_scan", role: .cancel) {
                    appState.cancelCurrentScan()
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }

            if let error = viewModel.errorMessage {
                HStack(spacing: 12) {
                    PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
                    Button(LocalizedStringKey("common.retry"), action: retryScan)
                        .buttonStyle(AuroraSecondaryButtonStyle())
                        .disabled(viewModel.roots.isEmpty || viewModel.isScanning)
                }
            }

            if !viewModel.groups.isEmpty {
                resultsView()
            } else if !viewModel.isScanning && viewModel.hasRun && viewModel.roots.isEmpty == false {
                // Scan has completed with coverage data but no groups found
                VStack(spacing: 12) {
                    if let coverage = viewModel.coverageSummary,
                       viewModel.coverageReport?.isPartial == true {
                        PermissionBannerView(message: coverage, systemImage: "exclamationmark.triangle.fill")
                    }
                    EmptyStateView(
                        systemImage: "sparkles",
                        title: "duplicates.empty.title",
                        message: viewModel.coverageReport?.isPartial == true
                            ? "duplicates.coverage.partial_empty"
                            : "duplicates.empty.message"
                    )
                }
            } else if !viewModel.isScanning && !viewModel.hasRun && viewModel.roots.isEmpty == false {
                // Idle state: default roots exist but no scan has been run yet
                VStack(spacing: 20) {
                    EmptyStateView(
                        systemImage: "folder.badge.plus",
                        title: "duplicates.prompt.title",
                        message: "duplicates.prompt.message"
                    )
                    HStack(spacing: 12) {
                        Button {
                            viewModel.folderPickerPresented = true
                        } label: {
                            Label("duplicates.choose_folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .help(Text("duplicates.choose_folder.help"))
                        Button {
                            folderStore.presentFolderPicker { url in
                                viewModel.addAuthorizedRoot(url)
                            }
                        } label: {
                            Label("duplicates.choose_external", systemImage: "externaldrive.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .help(Text("duplicates.choose_external.help"))

                        if !viewModel.roots.isEmpty {
                            Text(viewModel.roots.map(\.path).joined(separator: ", "))
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
                    .padding(.top, 8)
                }
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
                    if appState.settings.dryRun {
                        Button {
                            viewModel.showConfirmation = true
                        } label: {
                            Label("common.preview_cleanup", systemImage: "eye")
                        }
                    } else {
                        Button(role: .destructive) {
                            viewModel.showConfirmation = true
                        } label: {
                            Label("common.trash_selected", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .cleanupConfirmation(
            isPresented: $viewModel.showConfirmation,
            config: .standard(
                itemCount: viewModel.selection.count,
                totalBytes: viewModel.selectedBytes,
                previewOnly: appState.settings.dryRun,
                details: viewModel.selectedConfirmationDetails
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
        .onDisappear {
            if viewModel.isScanning { appState.cancelCurrentScan() }
        }
    }

    private func retryScan() {
        viewModel.retryScan(settings: appState.settings, activity: appState)
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remainder = total % 60
        return String(format: "%d:%02d", minutes, remainder)
    }

    @ViewBuilder
    private func resultsView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cleanupReport = viewModel.cleanupReport {
                CleanupResultSummaryView(result: cleanupReport)
            }
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

            if let coverage = viewModel.coverageSummary {
                PermissionBannerView(
                    message: coverage,
                    systemImage: viewModel.coverageReport?.isPartial == true ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
                )
            }

            HStack(spacing: 10) {
                Picker("duplicates.sort", selection: $viewModel.sortOption) {
                    ForEach(DuplicatesSortOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 220)

                Spacer()

                Button("duplicates.select_all") {
                    viewModel.selectAllRemovable()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.visibleGroups.isEmpty)

                Button("duplicates.deselect_all") {
                    viewModel.deselectAll()
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.selection.isEmpty)
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
                        detail: Self.rowDetail(for: file),
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(String(format: NSLocalizedString("duplicates.keeper", comment: ""), keeper.name))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let date = keeper.modificationDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
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

    /// Exact path plus the measured modification date so the user can tell
    /// which copy is newest before choosing what to remove.
    private static func rowDetail(for file: ScannedItem) -> String {
        guard let date = file.modificationDate else { return file.path }
        let formatted = date.formatted(date: .abbreviated, time: .omitted)
        return String(format: NSLocalizedString("duplicates.row_detail", comment: ""), formatted, file.path)
    }
}
