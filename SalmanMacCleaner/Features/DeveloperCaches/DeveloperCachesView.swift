//
//  DeveloperCachesView.swift
//  SalmanMacCleaner
//
//  Compact category-first developer-cache workspace. Detection is based on
//  real paths; manual selection remains available, but a tool name never
//  creates a cleanup candidate.
//

import SwiftUI
import AppKit

struct DeveloperCachesView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = DeveloperCachesViewModel()

    private let columns = [GridItem(.adaptive(minimum: 178, maximum: 250), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            categoryChooser
            controls
            if let error = viewModel.errorMessage {
                PermissionBannerView(message: error, systemImage: "exclamationmark.triangle.fill")
            }
            if !viewModel.deniedPaths.isEmpty {
                PermissionBannerView(
                    message: String(format: NSLocalizedString("devcaches.denied", comment: ""), viewModel.deniedPaths.count),
                    systemImage: "lock.fill"
                )
            }
            if !viewModel.truncatedPaths.isEmpty {
                PermissionBannerView(
                    message: String(format: NSLocalizedString("devcaches.truncated", comment: ""), viewModel.truncatedPaths.count),
                    systemImage: "exclamationmark.triangle.fill"
                )
            }
            if let cleanupReport = viewModel.cleanupReport {
                CleanupResultSummaryView(result: cleanupReport)
            }
            results
        }
        .padding(18)
        .navigationTitle(SidebarModule.developerCaches.title)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) { actionBar }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "hammer.fill")
                .font(.title2)
                .foregroundStyle(AuroraPalette.electricPurple)
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("devcaches.title")
                    .font(.title2.weight(.semibold))
                Text(String(format: NSLocalizedString("devcaches.detected_summary", comment: ""), viewModel.detectedCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                LocalizedStringKey(viewModel.isScanning ? "devcaches.state.scanning" : (viewModel.hasRun ? "devcaches.state.measured" : "devcaches.state.not_scanned")),
                kind: viewModel.isScanning ? .info : (viewModel.hasRun ? .ok : .unavailable)
            )
        }
        .padding(14)
        .glassCard()
    }

    private var categoryChooser: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                GlassSectionHeader("devcaches.categories", systemImage: "checklist")
                Spacer()
                Button("devcaches.select_all_detected") { viewModel.selectAllDetected() }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    .help(Text("devcaches.select_all_detected.help"))
                Button("common.clear") { viewModel.clearSelection() }
                    .buttonStyle(.borderless)
                    .help(Text("devcaches.clear.help"))
            }
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    ForEach(viewModel.descriptors) { descriptor in
                        Toggle(isOn: binding(for: descriptor.category)) {
                        HStack(spacing: 7) {
                            Image(systemName: descriptor.category.systemImage)
                                .foregroundStyle(descriptor.detected ? AuroraPalette.cyan : .secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(descriptor.category.title)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text(statusText(for: descriptor))
                                    .font(.caption2)
                                    .foregroundStyle(descriptor.detected ? AuroraPalette.success : .tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .help(Text(descriptor.existingCachePaths.joined(separator: "\n").isEmpty
                               ? NSLocalizedString("devcaches.no_path", comment: "")
                               : descriptor.existingCachePaths.joined(separator: "\n")))
                }
            }
            .frame(maxHeight: 190)
        }
        .padding(12)
        .glassCard()
    }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            Button {
                viewModel.startScan(settings: appState.settings, coordinator: ScanCoordinator.shared, activity: appState)
            } label: {
                Label("devcaches.scan", systemImage: "magnifyingglass")
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .disabled(viewModel.isScanning || viewModel.selectedCategories.isEmpty)
            .help(Text("devcaches.scan.help"))

            if viewModel.isScanning {
                Button {
                    viewModel.cancelScan(coordinator: ScanCoordinator.shared, activity: appState)
                } label: {
                    Label("common.cancel", systemImage: "xmark")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 180)
                Text(viewModel.detail ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                viewModel.refreshDetection()
            } label: {
                Label("devcaches.refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .disabled(viewModel.isScanning)
            .help(Text("devcaches.refresh.help"))
        }
    }

    @ViewBuilder
    private var results: some View {
        if !viewModel.hasRun && viewModel.entries.isEmpty {
            EmptyStateView(systemImage: "hammer", title: "devcaches.prompt.title", message: "devcaches.prompt.message")
                .frame(minHeight: 120)
        } else if viewModel.entries.isEmpty && !viewModel.isScanning {
            EmptyStateView(systemImage: "checkmark.circle", title: "devcaches.empty.title", message: "devcaches.empty.message")
                .frame(minHeight: 120)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(String(format: NSLocalizedString("devcaches.results.summary", comment: ""), viewModel.filteredEntries.count, FileUtilities.formattedBytes(viewModel.filteredBytes)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Picker("devcaches.category_filter", selection: $viewModel.categoryFilter) {
                        Text("devcaches.filter.all").tag(DeveloperCacheCategory?.none)
                        ForEach(DeveloperCacheCategory.allCases) { category in
                            Text(category.title).tag(DeveloperCacheCategory?.some(category))
                        }
                    }
                    .frame(width: 160)
                    Picker("common.sort", selection: $viewModel.sortOption) {
                        ForEach(DeveloperCacheSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .frame(width: 145)
                    Toggle("devcaches.group_by_category", isOn: $viewModel.groupByCategory)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                }
                SelectionSummaryBar(selectedCount: viewModel.selection.count, selectedBytes: viewModel.selectedBytes, previewOnly: appState.settings.dryRun)
                if viewModel.groupByCategory {
                    List {
                        ForEach(viewModel.entriesByCategory) { group in
                            Section(header: Text(group.title)) {
                                ForEach(group.entries) { entry in
                                    resultRow(entry)
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                } else {
                    List(viewModel.filteredEntries) { entry in
                        resultRow(entry)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            Button { viewModel.refreshDetection() } label: { Image(systemName: "arrow.clockwise") }
                .help(Text("devcaches.refresh.help"))
        }
    }

    @ViewBuilder
    private var actionBar: some View {
        if !viewModel.selection.isEmpty {
            HStack(spacing: 12) {
                Text(String(format: NSLocalizedString("results.selected", comment: ""), viewModel.selection.count))
                    .font(.callout.weight(.medium))
                Text(FileUtilities.formattedBytes(viewModel.selectedBytes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.settings.dryRun {
                    Button("common.preview_cleanup") { viewModel.showConfirmation = true }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                } else {
                    Button("common.trash_selected") { viewModel.showConfirmation = true }
                        .buttonStyle(AuroraPrimaryButtonStyle())
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
            .overlay(alignment: .top) { Divider().opacity(0.25) }
            .cleanupConfirmation(
                isPresented: $viewModel.showConfirmation,
                config: .standard(
                    itemCount: viewModel.selection.count,
                    totalBytes: viewModel.selectedBytes,
                    previewOnly: appState.settings.dryRun,
                    details: viewModel.selectedConfirmationDetails
                ),
                onConfirm: { viewModel.performCleanup(settings: appState.settings, history: appState.history, activity: appState) }
            )
        }
    }

    private func resultRow(_ entry: DeveloperCacheEntry) -> some View {
        DeveloperCacheResultRow(entry: entry, isSelected: viewModel.selection.contains(entry.id), toggle: {
            if viewModel.selection.contains(entry.id) { viewModel.selection.remove(entry.id) }
            else { viewModel.selection.insert(entry.id) }
        })
    }

    private func binding(for category: DeveloperCacheCategory) -> Binding<Bool> {
        Binding(
            get: { viewModel.selectedCategories.contains(category) },
            set: { selected in
                if selected { viewModel.selectedCategories.insert(category) }
                else { viewModel.selectedCategories.remove(category) }
            }
        )
    }

    private func statusText(for descriptor: DeveloperCacheDescriptor) -> String {
        if descriptor.detected { return String(format: NSLocalizedString("devcaches.detected_path_count", comment: ""), descriptor.existingCachePaths.count) }
        if descriptor.isToolOnly { return NSLocalizedString("devcaches.tool_only", comment: "") }
        return NSLocalizedString("devcaches.not_found", comment: "")
    }
}

private struct DeveloperCacheResultRow: View {
    let entry: DeveloperCacheEntry
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? AuroraPalette.electricPurple : .secondary)
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                    .foregroundStyle(AuroraPalette.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(entry.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(FileUtilities.formattedBytes(entry.size))
                        .font(.callout.monospacedDigit())
                    Text(entry.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                SafetyBadge(level: entry.confidence)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Text(entry.path))
        .accessibilityLabel(Text("\(entry.name), \(FileUtilities.formattedBytes(entry.size))"))
        .contextMenu {
            Button("results.reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
            }
        }
    }
}
