//
//  AppLeftoversView.swift
//  SalmanMacCleaner
//
//  Exact bundle-id support inventory. Human names come from installed bundle
//  metadata; an uninstalled id uses a truthful generic label. Apple services,
//  installed data, and ambiguous entries remain visible for audit but cannot
//  be selected for cleanup.
//

import SwiftUI
import AppKit

private enum LeftoverFilter: String, CaseIterable, Identifiable {
    case all, probable, installed, apple, unknown
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return NSLocalizedString("leftovers.filter.all", comment: "")
        case .probable: return NSLocalizedString("leftovers.filter.probable", comment: "")
        case .installed: return NSLocalizedString("leftovers.filter.installed", comment: "")
        case .apple: return NSLocalizedString("leftovers.filter.apple", comment: "")
        case .unknown: return NSLocalizedString("leftovers.filter.unknown", comment: "")
        }
    }
}

struct AppLeftoversView: View {
    @EnvironmentObject private var appState: AppState
    @State private var leftovers: [LeftoverCandidate] = []
    @State private var isScanning = false
    @State private var heroMode = true
    @State private var selection: Set<String> = []
    @State private var showConfirmation = false
    @State private var searchText = ""
    @State private var filter: LeftoverFilter = .all
    @State private var report: CleanupResult?
    @State private var scanTask: Task<Void, Never>?
    @State private var scanToken = UUID()

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .appLeftovers,
                    isBusy: isScanning,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.app_leftovers.scope", comment: ""),
                    primaryAction: {
                        heroMode = false
                        runScan()
                    },
                    selectors: { EmptyView() }
                )
            } else {
                workspace
            }
        }
        .searchable(text: $searchText, prompt: Text("search.items.prompt"))
        .onChange(of: appState.cancellationGeneration) { _ in
            if isScanning { cancelScan() }
        }
        .onDisappear {
            if isScanning { cancelScan() }
        }
    }

    private var visibleGroups: [LeftoverCandidate] {
        leftovers.filter { group in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .probable: matchesFilter = group.classification == .probableUninstalledAppLeftover
            case .installed: matchesFilter = group.classification == .installedAppData
            case .apple: matchesFilter = group.classification == .appleSystemService
            case .unknown: matchesFilter = group.classification == .unknownAmbiguous
            }
            guard matchesFilter else { return false }
            return searchText.isEmpty
                || group.applicationName.localizedCaseInsensitiveContains(searchText)
                || group.owningBundleID.localizedCaseInsensitiveContains(searchText)
                || group.paths.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("leftovers.title")
                        .font(.title2.weight(.semibold))
                    Text(String(format: NSLocalizedString("leftovers.summary", comment: ""), visibleGroups.count, FileUtilities.formattedBytes(totalBytes)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("leftovers.filter", selection: $filter) {
                    ForEach(LeftoverFilter.allCases) { item in Text(item.title).tag(item) }
                }
                .frame(width: 165)
                if isScanning {
                    Button {
                        cancelScan()
                    } label: {
                        Label("common.cancel", systemImage: "xmark")
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                } else {
                    Button { runScan() } label: { Label("leftovers.rescan", systemImage: "arrow.clockwise") }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                }
            }
            .padding(12)
            .glassCard()

            if isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("leftovers.scanning").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
            if let report {
                cleanupReport(report)
            }

            if visibleGroups.isEmpty && !isScanning {
                EmptyStateView(
                    systemImage: leftovers.isEmpty ? "person.crop.circle.badge.questionmark" : "checkmark.circle",
                    title: leftovers.isEmpty ? "leftovers.empty.title" : "leftovers.empty.filtered.title",
                    message: leftovers.isEmpty ? "leftovers.empty.message" : "leftovers.empty.filtered.message"
                )
            } else {
                List(visibleGroups) { group in
                    leftoverRow(group)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .padding(18)
        .safeAreaInset(edge: .bottom) { actionBar }
        .cleanupConfirmation(
            isPresented: $showConfirmation,
            config: .standard(
                itemCount: selectedItemCount,
                totalBytes: selectedBytes,
                previewOnly: appState.settings.dryRun,
                details: selectedConfirmationDetails
            ),
            onConfirm: { performCleanup() }
        )
    }

    private func leftoverRow(_ group: LeftoverCandidate) -> some View {
        DisclosureGroup {
            ForEach(group.paths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(FileUtilities.formattedBytes(FileUtilities.fileSize(atPath: path)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
                .contextMenu {
                    Button("results.reveal") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                    }
                }
            }
        } label: {
            HStack(spacing: 10) {
                Toggle("", isOn: binding(for: group.groupID))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .disabled(!canSelect(group))
                Image(systemName: icon(for: group.classification))
                    .foregroundStyle(color(for: group.classification))
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.applicationName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(group.owningBundleID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let publisher = group.publisher {
                        Text(publisher)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(group.evidence)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text(group.classification.title)
                    .font(.caption)
                    .foregroundStyle(color(for: group.classification))
                ConfidenceBadge(confidence: group.confidence)
                Text(FileUtilities.formattedBytes(group.totalSize))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
        }
        .disabled(!canSelect(group))
        .help(Text(group.evidence + "\n" + group.paths.joined(separator: "\n")))
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionBar: some View {
        if selectedItemCount > 0 {
            HStack(spacing: 10) {
                Text(String(format: NSLocalizedString("results.selected", comment: ""), selectedItemCount))
                    .font(.callout.weight(.medium))
                Text(FileUtilities.formattedBytes(selectedBytes))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.settings.dryRun {
                    Button("results.preview_cleanup") { showConfirmation = true }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                } else {
                    Button("results.clean_selected") { showConfirmation = true }
                        .buttonStyle(AuroraPrimaryButtonStyle())
                }
            }
            .padding(12)
            .background(.ultraThinMaterial)
        }
    }

    private func canSelect(_ group: LeftoverCandidate) -> Bool {
        group.classification.isSelectable && group.confidence == .high
    }

    private var totalBytes: Int64 {
        leftovers.reduce(0) { CleanupAccounting.adding($0, $1.totalSize) }
    }

    private var selectedGroups: [LeftoverCandidate] { leftovers.filter { selection.contains($0.groupID) && canSelect($0) } }
    private var selectedItemCount: Int { selectedGroups.reduce(0) { $0 + $1.paths.count } }
    private var selectedBytes: Int64 { selectedGroups.reduce(0) { CleanupAccounting.adding($0, $1.totalSize) } }

    private var selectedConfirmationDetails: [String] {
        selectedGroups
            .flatMap { group in
                group.paths.map { path in
                    ConfirmationDialogConfig.detailLine(
                        path: path,
                        category: group.classification.title,
                        size: FileUtilities.fileSize(atPath: path),
                        confidence: group.confidence.title,
                        reason: group.evidence
                    )
                }
            }
            .sorted()
    }

    private func binding(for groupID: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(groupID) },
            set: { on in
                guard let group = leftovers.first(where: { $0.groupID == groupID }), canSelect(group) else { return }
                if on { selection.insert(groupID) } else { selection.remove(groupID) }
            }
        )
    }

    private func runScan(preserveReport: Bool = false) {
        scanTask?.cancel()
        let token = UUID()
        scanToken = token
        isScanning = true
        selection.removeAll()
        if !preserveReport {
            report = nil
        }
        appState.beginActivity(.scanning(detail: NSLocalizedString("leftovers.scanning", comment: "")))
        let worker = Task.detached(priority: .userInitiated) {
            let apps = ApplicationInventoryService.discoverApplications()
            guard !Task.isCancelled else { return [LeftoverCandidate]() }
            return ResidualCorrelationEngine.discoverLeftovers(installedApps: apps)
        }
        let task = Task { @MainActor in
            let found = await withTaskCancellationHandler(operation: {
                await worker.value
            }, onCancel: {
                worker.cancel()
            })
            guard !Task.isCancelled else { return }
            guard self.scanToken == token else { return }
            leftovers = found
            isScanning = false
            scanTask = nil
            appState.endActivity(message: String(
                format: NSLocalizedString("leftovers.scan_complete", comment: ""),
                found.count,
                FileUtilities.formattedBytes(found.reduce(Int64(0)) { CleanupAccounting.adding($0, $1.totalSize) })
            ))
        }
        scanTask = task
    }

    private func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanToken = UUID()
        isScanning = false
        appState.endActivity(message: NSLocalizedString("scan.cancelled", comment: ""))
    }

    private func performCleanup() {
        let selected = selectedGroups.flatMap { group in
            group.paths.map {
                let fallback = FileUtilities.fileSize(atPath: $0)
                let identity = Crypto.inode(of: $0)
                return CleanupItem(
                    path: $0,
                    size: CleanupAccounting.currentAllocatedBytes(at: $0, fallback: fallback),
                    kind: "appLeftover",
                    device: identity.map { Int32(clamping: $0.0) } ?? 0,
                    inode: identity.map { UInt64($0.1) } ?? 0
                )
            }
        }
        guard !selected.isEmpty else { return }
        let previewOnly = appState.settings.dryRun
        let allowedRoots = ResidualCorrelationEngine.supportRoots()
        appState.beginActivity(.cleaning(detail: NSLocalizedString("leftovers.cleaning", comment: "")))
        Task {
            let result = await CleanupEngine.shared.clean(
                items: selected,
                root: PathSafety.userHome.path,
                previewOnly: previewOnly,
                allowedRoots: allowedRoots,
                progress: { fraction, detail in Task { @MainActor in appState.updateProgress(fraction, detail: detail) } },
                isCancelled: { Task.isCancelled }
            )
            report = result
            if !previewOnly {
                let moved = Set(result.trashed.map(\.path))
                leftovers = leftovers.compactMap { group in
                    var updated = group
                    updated.paths.removeAll { moved.contains($0) }
                    updated.totalSize = updated.paths.reduce(0) { CleanupAccounting.adding($0, FileUtilities.fileSize(atPath: $1)) }
                    return updated.paths.isEmpty ? nil : updated
                }
                selection.removeAll()
            }
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.leftovers", comment: ""),
                category: "appLeftovers",
                itemCount: result.succeededCount,
                bytes: previewOnly ? result.totalBytes : result.movedBytes,
                previewOnly: previewOnly,
                movedCount: result.trashed.count,
                failedCount: result.failedCount,
                root: PathSafety.userHome.path
            ))
            appState.endActivity(message: result.cancelled
                ? NSLocalizedString("cleanup.report.cancelled", comment: "")
                : (result.previewOnly
                    ? String(format: NSLocalizedString("leftovers.preview_done", comment: ""), result.previewed.count)
                    : String(format: NSLocalizedString("leftovers.clean_done", comment: ""), result.trashed.count)))
            if !previewOnly && !result.cancelled {
                // Rebuild the evidence-based inventory after movement so
                // surviving support files and their measured bytes remain
                // truthful.
                runScan(preserveReport: true)
            }
        }
    }

    private func cleanupReport(_ result: CleanupResult) -> some View {
        CleanupResultSummaryView(result: result)
            .overlay(alignment: .topTrailing) {
                Button { report = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .help(Text("common.clear"))
            }
    }

    private func icon(for classification: LeftoverClassification) -> String {
        classification == .appleSystemService ? "lock.shield.fill" : (classification == .probableUninstalledAppLeftover ? "questionmark.circle" : "lock.fill")
    }

    private func color(for classification: LeftoverClassification) -> Color {
        classification.isSelectable ? AuroraPalette.amber : AuroraPalette.tertiaryText(.dark)
    }
}
