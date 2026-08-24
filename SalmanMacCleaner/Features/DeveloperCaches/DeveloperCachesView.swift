//
//  DeveloperCachesView.swift
//  SalmanMacCleaner
//
//  Developer cache scanner UI: category filters, preview-first entry list and
//  trash-only cleanup for selected entries.
//

import SwiftUI

struct DeveloperCachesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DeveloperCachesViewModel()

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SafetyNoteView(text: "devcaches.safety_note")

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(DeveloperCacheCategory.allCases) { category in
                    Toggle(isOn: binding(for: category)) {
                        Label(category.title, systemImage: category.systemImage)
                            .font(.callout)
                    }
                    .toggleStyle(.button)
                    .tint(appState.settings.defaultScannerCategory == category.rawValue ? .accentColor : .secondary)
                    .help(Text(DeveloperCacheScanner.safetyNote(for: category)))
                }
            }

            HStack(spacing: 12) {
                Button {
                    viewModel.startScan(settings: appState.settings, coordinator: ScanCoordinator.shared, activity: appState)
                } label: {
                    if viewModel.isScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("devcaches.scan", systemImage: "magnifyingglass")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.isScanning)

                if viewModel.isScanning {
                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(.linear)
                    Text(viewModel.detail ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if let error = viewModel.errorMessage {
                PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
            }

            if !viewModel.entries.isEmpty {
                entriesList()
            } else if viewModel.hasRun && !viewModel.isScanning {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: "devcaches.empty.title",
                    message: "devcaches.empty.message"
                )
            } else if !viewModel.isScanning {
                EmptyStateView(
                    systemImage: "hammer",
                    title: "devcaches.prompt.title",
                    message: "devcaches.prompt.message"
                )
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle(AppSection.developerCaches.title)
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
    }

    private func binding(for category: DeveloperCacheCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedCategories.contains(category) },
            set: { on in
                if on { viewModel.selectedCategories.insert(category) }
                else { viewModel.selectedCategories.remove(category) }
            }
        )
    }

    @ViewBuilder
    private func entriesList() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: NSLocalizedString("devcaches.results.summary", comment: ""),
                            viewModel.filteredEntries.count, FileUtilities.formattedBytes(viewModel.filteredBytes)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Picker("devcaches.group_by", selection: $viewModel.groupByCategory) {
                        Text("devcaches.group.category").tag(true)
                        Text("devcaches.group.size").tag(false)
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

            if viewModel.groupByCategory {
                List {
                    ForEach(viewModel.entriesByCategory) { group in
                        Section {
                            ForEach(group.entries) { entry in
                                entryRow(entry)
                            }
                        } header: {
                            Text(group.title)
                        }
                    }
                }
                .listStyle(.inset)
            } else {
                List(viewModel.filteredEntries) { entry in
                    entryRow(entry)
                }
                .listStyle(.inset)
            }
        }
    }

    private func entryRow(_ entry: DeveloperCacheEntry) -> some View {
        Toggle(isOn: binding(for: entry.id)) {
            ItemRowLabel(
                name: entry.name,
                detail: DeveloperCacheCategory(rawValue: entry.category)?.title,
                size: entry.size
            )
        }
        .toggleStyle(.checkbox)
        .help(Text(entry.path))
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { viewModel.selection.contains(id) },
            set: { selected in
                if selected { viewModel.selection.insert(id) } else { viewModel.selection.remove(id) }
            }
        )
    }
}
