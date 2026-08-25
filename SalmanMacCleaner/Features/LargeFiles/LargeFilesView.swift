//
//  LargeFilesView.swift
//  SalmanMacCleaner
//
//  Large File Finder. Scans only folders the user explicitly selects, shows a
//  sortable/searchable preview table, and cleans up strictly selected rows
//  through the trash-only engine (with a second confirmation).
//

import SwiftUI

struct LargeFilesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = LargeFilesViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SafetyNoteView(text: "largefiles.safety_note")

            HStack(spacing: 12) {
                Button {
                    chooseFolder()
                } label: {
                    Label("largefiles.choose_folder", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.borderedProminent)

                if !viewModel.roots.isEmpty {
                    Text(viewModel.roots.map(\.path).joined(separator: ", "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("common.clear", role: .destructive) {
                        viewModel.roots = []
                        viewModel.result = nil
                    }
                    .buttonStyle(.borderless)
                }

                Spacer()

                Button {
                    viewModel.startScan(settings: appState.settings, coordinator: ScanCoordinator.shared, activity: appState)
                } label: {
                    Label("largefiles.scan", systemImage: "magnifyingglass")
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
            if let cleanupReport = viewModel.cleanupReport {
                CleanupResultSummaryView(result: cleanupReport)
            }

            if let result = viewModel.result {
                if result.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.circle",
                        title: "largefiles.empty.title",
                        message: "largefiles.empty.message"
                    )
                } else {
                    resultsTable(result: result)
                }
            } else if viewModel.roots.isEmpty {
                EmptyStateView(
                    systemImage: "folder.badge.questionmark",
                    title: "largefiles.prompt.title",
                    message: "largefiles.prompt.message"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle(SidebarModule.largeOldFiles.title)
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
                        .help("common.preview_cleanup.help")
                    } else {
                        Button(role: .destructive) {
                            viewModel.showConfirmation = true
                        } label: {
                            Label("common.trash_selected", systemImage: "trash")
                        }
                        .help("common.trash_selected.help")
                    }
                }
            }
        }
        .cleanupConfirmation(
            isPresented: $viewModel.showConfirmation,
            config: .standard(
                itemCount: viewModel.selection.count,
                totalBytes: viewModel.selectedBytes,
                previewOnly: appState.settings.dryRun
            ),
            onConfirm: {
                viewModel.performCleanup(
                    settings: appState.settings,
                    history: appState.history,
                    activity: appState
                )
            }
        )
        .sheet(isPresented: $viewModel.folderPickerPresented) {
            FolderPickerView(message: "largefiles.picker.message") { url in
                viewModel.addRoot(url)
            }
        }
    }

    private func chooseFolder() {
        viewModel.folderPickerPresented = true
    }

    @ViewBuilder
    private func resultsTable(result: ScanResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: NSLocalizedString("largefiles.results.summary", comment: ""),
                            result.items.count, FileUtilities.formattedBytes(result.totalBytes)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if result.skippedCount > 0 {
                    Text(String(format: NSLocalizedString("largefiles.results.skipped", comment: ""), result.skippedCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Picker("common.sort_by", selection: $viewModel.sortOrder) {
                        ForEach(LargeFilesSortOrder.allCases) { order in
                            Text(order.title).tag(order)
                        }
                    }
                } label: {
                    Label("common.sort", systemImage: "arrow.up.arrow.down")
                }
                .fixedSize()
            }

            SelectionSummaryBar(
                selectedCount: viewModel.selection.count,
                selectedBytes: viewModel.selectedBytes,
                previewOnly: appState.settings.dryRun
            )

            List(viewModel.filteredItems) { item in
                Toggle(isOn: selectionBinding(for: item.id)) {
                    ItemRowLabel(
                        name: item.name,
                        detail: item.path,
                        size: item.size
                    )
                }
                .toggleStyle(.checkbox)
                .help(Text(item.path))
            }
            .listStyle(.inset)
        }
    }

    private func selectionBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { viewModel.selection.contains(id) },
            set: { selected in
                if selected {
                    viewModel.selection.insert(id)
                } else {
                    viewModel.selection.remove(id)
                }
            }
        )
    }
}

enum LargeFilesSortOrder: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case dateDescending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: return NSLocalizedString("sort.size_desc", comment: "")
        case .sizeAscending: return NSLocalizedString("sort.size_asc", comment: "")
        case .nameAscending: return NSLocalizedString("sort.name_asc", comment: "")
        case .dateDescending: return NSLocalizedString("sort.date_desc", comment: "")
        }
    }
}
