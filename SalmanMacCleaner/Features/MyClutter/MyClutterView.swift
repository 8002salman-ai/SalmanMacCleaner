//
//  MyClutterView.swift
//  SalmanMacCleaner
//
//  My Clutter: explicit opt-in review of the personal folders. Nothing in
//  Desktop/Documents/Downloads/Pictures/Music/Movies is scanned unless the
//  user explicitly picks a specific folder. Results are preview-only by
//  default and never auto-selected.
//

import SwiftUI
import AppKit

struct MyClutterView: View {
    @EnvironmentObject private var appState: AppState
    @State private var chosenFolder: URL?
    @State private var items: [ScannedItem] = []
    @State private var isScanning = false
    @State private var selection: Set<UUID> = []
    @State private var showPicker = false
    @State private var showConfirmation = false

    var body: some View {
        Group {
            if chosenFolder == nil {
                HeroScreenView(
                    module: .myClutter,
                    isBusy: false,
                    lastScanText: nil,
                    permissionWarning: NSLocalizedString("clutter.permission_note", comment: ""),
                    estimatedScope: NSLocalizedString("hero.my_clutter.scope", comment: ""),
                    primaryAction: { showPicker = true },
                    selectors: { EmptyView() }
                )
                .sheet(isPresented: $showPicker) {
                    FolderPickerView(message: "clutter.picker.message") { url in
                        if let url {
                            chosenFolder = url
                            scan(url)
                        }
                    }
                }
            } else if isScanning {
                VStack(spacing: 16) {
                    ProgressView().controlSize(.large)
                    Text("clutter.scanning")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                results
            }
        }
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(chosenFolder?.path ?? "")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("common.clear") {
                    chosenFolder = nil
                    items = []
                    selection = []
                }
                .buttonStyle(.borderless)
                Spacer()
                Button("clutter.choose_other") { showPicker = true }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    .sheet(isPresented: $showPicker) {
                        FolderPickerView(message: "clutter.picker.message") { url in
                            if let url {
                                chosenFolder = url
                                scan(url)
                            }
                        }
                    }
            }

            if items.isEmpty {
                EmptyStateView(
                    systemImage: "shippingbox",
                    title: "clutter.empty.title",
                    message: "clutter.empty.message"
                )
            } else {
                SelectionSummaryBar(
                    selectedCount: selection.count,
                    selectedBytes: selectedBytes,
                    previewOnly: appState.settings.dryRun
                )
                List(items) { item in
                    Toggle(isOn: binding(for: item.id)) {
                        ItemRowLabel(name: item.name, detail: item.path, size: item.size)
                    }
                    .toggleStyle(.checkbox)
                    .help(Text(item.path))
                    .contextMenu {
                        Button("results.reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                        Button("results.quicklook") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        }
                    }
                }
                .listStyle(.inset)
            }
            Spacer()
        }
        .padding(24)
        .safeAreaInset(edge: .bottom) {
            if !selection.isEmpty {
                HStack {
                    Text(String(format: NSLocalizedString("results.selected", comment: ""), selection.count))
                    Spacer()
                    Button("results.preview_cleanup") { showConfirmation = true }
                        .buttonStyle(AuroraSecondaryButtonStyle())
                    Button("results.clean_selected") { showConfirmation = true }
                        .buttonStyle(AuroraPrimaryButtonStyle())
                        .disabled(appState.settings.dryRun)
                }
                .padding(14)
                .background(.ultraThinMaterial)
            }
        }
        .cleanupConfirmation(
            isPresented: $showConfirmation,
            config: .standard(itemCount: selection.count, totalBytes: selectedBytes, previewOnly: appState.settings.dryRun),
            onConfirm: { performCleanup() }
        )
    }

    private var selectedBytes: Int64 {
        items.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { on in
                if on { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }

    private func scan(_ url: URL) {
        isScanning = true
        selection = []
        items = []
        let root = url.path
        Task.detached(priority: .userInitiated) {
            var found: [ScannedItem] = []
            if let device = VolumeDiscoveryService.deviceID(ofMountPoint: root),
               let enumerator = FileManager.default.enumerator(
                   at: url,
                   includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey],
                   options: [.skipsHiddenFiles],
                   errorHandler: { _, _ in true }
               ) {
                for case let entry as URL in enumerator {
                    guard let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey]) else { continue }
                    if values.isSymbolicLink == true { continue }
                    if values.isRegularFile == true {
                        let safe = PathSafety.validate(path: entry.path, root: root, expectedDevice: dev_t(device), purpose: .scan, allowSymlink: false)
                        guard case .success(let validated) = safe else { continue }
                        found.append(ScannedItem(
                            path: validated.canonical,
                            size: Int64(values.fileSize ?? 0),
                            modificationDate: (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                        ))
                    }
                }
            }
            found.sort { $0.size > $1.size }
            await MainActor.run {
                items = Array(found.prefix(500))
                isScanning = false
            }
        }
    }

    private func performCleanup() {
        let selected = items.filter { selection.contains($0.id) }
        let cleanupItems = selected.map { CleanupItem(path: $0.path, size: $0.size, kind: "file") }
        guard let root = chosenFolder?.path, !cleanupItems.isEmpty else { return }
        let previewOnly = appState.settings.dryRun
        appState.beginActivity(.cleaning(detail: NSLocalizedString("clutter.cleaning", comment: "")))

        let task = Task {
            let result = await CleanupEngine.shared.clean(
                items: cleanupItems,
                root: root,
                previewOnly: previewOnly,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.clutter", comment: ""),
                category: "myClutter",
                itemCount: cleanupItems.count,
                bytes: result.totalBytes,
                previewOnly: previewOnly,
                movedCount: result.trashed.count,
                failedCount: result.failedCount,
                root: root
            ))
            appState.endActivity(message: String(
                format: previewOnly
                    ? NSLocalizedString("clutter.preview_done", comment: "")
                    : NSLocalizedString("clutter.clean_done", comment: ""),
                result.succeededCount
            ))
            scan(chosenFolder!)
            selection = []
        }
        withExtendedLifetime(task) {}
    }
}
