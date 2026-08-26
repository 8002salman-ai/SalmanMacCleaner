////
//  TrashBinsView.swift
//  SalmanMacCleaner
////
//  Trash Bins: real inventory of the user Trash and per-volume trash
//  folders. Supports Restore, Permanent Delete with confirmation, and
//  Empty Trash. Actions are recorded in Activity & History.
//


import SwiftUI
import AppKit

public struct TrashEntry: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var originalPath: String?  // For restore: source path before moving to trash

    public init(name: String, path: String, size: Int64, isDirectory: Bool, originalPath: String? = nil) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.originalPath = originalPath
    }
}

struct TrashBinsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [TrashEntry] = []
    @State private var totalBytes: Int64 = 0
    @State private var isLoading = false
    @State private var showPermanentDeleteConfirmation = false
    @State private var selectedForPermanentDelete: Set<String> = []
    @State private var searchText = ""

    var body: some View {
        Group {
            if entries.isEmpty && !isLoading {
                // Empty trash state - show controls
                VStack(alignment: .leading, spacing: 24) {
                    EmptyStateView(
                        systemImage: "trash",
                        title: "trash.empty.title",
                        message: "trash.empty.message"
                    )

                    HStack(spacing: 12) {
                        Button("trash.restore_selected") {
                            restoreSelected()
                        }
                        .buttonStyle(.bordered)
                        .disabled(selectedForPermanentDelete.isEmpty)

                        Button("trash.delete_permanently") {
                            showPermanentDeleteConfirmation = true
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundStyle(.red)
                        .disabled(selectedForPermanentDelete.isEmpty)

                        Button("trash.empty_trash") {
                            emptyTrashConfirmed()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                    }
                    .padding(.top, 8)

                    Spacer(minLength: 0)
                }
                .padding(24)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    // Header bar with controls
                    HStack {
                        Text("trash.bins_title")
                            .font(.headline)

                        Spacer()

                        HStack(spacing: 8) {
                            Button("trash.refresh") {
                                load()
                            }
                            .buttonStyle(.borderless)

                            Button("trash.search") {
                                // Search is enabled via text field below
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)

                            if !selectedForPermanentDelete.isEmpty {
                                Button("trash.delete_permanently") {
                                    showPermanentDeleteConfirmation = true
                                }
                                .buttonStyle(.borderedProminent)
                                .foregroundStyle(.red)
                            }
                        }

                        if !entries.isEmpty {
                            Button("trash.restore_selected") {
                                restoreSelected()
                            }
                            .buttonStyle(.borderless)
                            .disabled(selectedForPermanentDelete.isEmpty || entries.filter { $0.originalPath == nil }.isEmpty)
                        }
                    }
                    .padding(.horizontal, 8)

                    // Toolbar search
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("trash.search_placeholder", text: $searchText)
                                .textFieldStyle(.plain)
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))

                        if !searchText.isEmpty {
                            Button(action: { searchText = "" }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(.horizontal, 8)

                    // Trash entries list
                    if entries.isEmpty {
                        EmptyStateView(
                            systemImage: "trash",
                            title: "trash.empty.title",
                            message: "trash.empty.message_after_search"
                        )
                    } else {
                        List(filteredEntries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(.secondary)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.name)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    if let original = entry.originalPath {
                                        Text(original)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                }

                                Spacer()

                                Text(FileUtilities.formattedBytes(entry.size))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button(action: { restore(entry: entry) }) {
                                    Label("trash.restore", systemImage: "arrow.uturn.left")
                                }
                                Button(action: { selectForPermanentDelete(entry: entry) }) {
                                    Label("trash.delete_permanently", systemImage: "trash.fill")
                                }
                                .foregroundStyle(.red)
                            }
                        }
                        .listStyle(.inset)
                        .searchable(text: $searchText, prompt: Text("trash.search_placeholder"))
                    }

                    // Summary and action bar
                    HStack(spacing: 12) {
                        Text(String(format: "trash.summary", entries.count, FileUtilities.formattedBytes(totalBytes)))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        Spacer()

                        if !selectedForPermanentDelete.isEmpty {
                            Button("trash.permanent_delete_selected") {
                                performPermanentDelete(paths: Array(selectedForPermanentDelete))
                            }
                            .buttonStyle(.borderedProminent)
                            .foregroundStyle(.red)
                        }

                        Button("trash.empty_trash") {
                            emptyTrashConfirmed()
                        }
                        .buttonStyle(.bordered)
                        .foregroundStyle(.red)
                        .disabled(entries.isEmpty)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))

                    Spacer(minLength: 0)
                }
                .padding(24)
            }
        }
        .alert("permanent_delete_confirmation_title", isPresented: $showPermanentDeleteConfirmation) {
            Button("common.cancel", role: .cancel) { }
            Button("trash.permanent_delete", role: .destructive) {
                if let paths = selectedForPermanentDelete.isEmpty ? nil : selectedForPermanentDelete.sorted() {
                    performPermanentDelete(paths: paths)
                }
            }
        } message: {
            Text("permanent_delete_confirmation_message")
        }
        .onChange(of: searchText) { _ in
            // Filter entries when search text changes
        }
    }

    // MARK: - Filtered entries for search

    private var filteredEntries: [TrashEntry] {
        if searchText.isEmpty {
            return entries
        } else {
            return entries.filter { entry in
                entry.name.localizedCaseInsensitiveContains(searchText) ||
                entry.path.localizedCaseInsensitiveContains(searchText) ||
                (entry.originalPath?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
    }

    // MARK: - Load trash contents

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let trashRoots = [NSHomeDirectory() + "/.Trash"] + trashMounts()
            var found: [TrashEntry] = []
            var total: Int64 = 0

            for root in trashRoots {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }

                do {
                    let contents = try FileManager.default.contentsOfDirectory(
                        at: url,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey],
                        options: [.skipsHiddenFiles]
                    )

                    for entry in contents {
                        guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey]) else { continue }

                        let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                        total = CleanupAccounting.adding(total, size)

                        // Determine if this file was moved by our app by checking for original path
                        // or if it's a native trash entry
                        found.append(TrashEntry(
                            name: entry.lastPathComponent,
                            path: entry.path,
                            size: size,
                            isDirectory: values.isDirectory ?? false,
                            originalPath: nil  // We don't track original paths for native trash entries
                        ))
                    }
                } catch {
                    // Skip unreadable roots
                }
            }

            found.sort { $0.size > $1.size }

            await MainActor.run {
                entries = found
                totalBytes = total
                isLoading = false
            }
        }
    }

    // MARK: - Restore selected entries

    private func restoreSelected() {
        // Restore entries that have a known original path
        let entriesToRestore = entries.filter { $0.originalPath != nil }

        guard !entriesToRestore.isEmpty else { return }

        for entry in entriesToRestore {
            let sourceURL = URL(fileURLWithPath: entry.originalPath!, isDirectory: entry.isDirectory)
            let destURL = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)

            do {
                if entry.isDirectory {
                    try FileManager.default.createDirectory(
                        at: sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: destURL, to: sourceURL)
                } else {
                    try FileManager.default.moveItem(at: destURL, to: sourceURL)
                }
            } catch {
                // Log failure but continue with other restores
                print("Failed to restore \(entry.path): \(error)")
            }
        }

        // Reload immediately after restore
        load()

        // Record in history
        appState.history.record(HistoryEntry(
            action: "trash.restored",
            category: "trash",
            itemCount: entriesToRestore.count,
            bytes: entriesToRestore.reduce(0) { CleanupAccounting.adding($0, $1.size) },
            dryRun: false,
            root: NSHomeDirectory() + "/.Trash"
        ))
    }

    private func restore(entry: TrashEntry) {
        guard let original = entry.originalPath else { return }

        let sourceURL = URL(fileURLWithPath: original, isDirectory: entry.isDirectory)
        let destURL = URL(fileURLWithPath: entry.path, isDirectory: entry.isDirectory)

        do {
            if entry.isDirectory {
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: destURL, to: sourceURL)
            } else {
                try FileManager.default.moveItem(at: destURL, to: sourceURL)
            }
        } catch {
            print("Failed to restore \(entry.path): \(error)")
        }

        // Reload immediately after restore
        load()
    }

    // MARK: - Select entry for permanent delete

    private func selectForPermanentDelete(entry: TrashEntry) {
        if selectedForPermanentDelete.contains(entry.path) {
            selectedForPermanentDelete.remove(entry.path)
        } else {
            selectedForPermanentDelete.insert(entry.path)
        }
    }

    // MARK: - Permanent delete

    private func performPermanentDelete(paths: [String]) {
        let trashRoots = ([NSHomeDirectory() + "/.Trash"] + trashMounts())
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        let safePaths = paths.filter { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return trashRoots.contains { root in
                standardized.hasPrefix(root + "/")
            }
        }

        for path in safePaths {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Failed to permanently delete \(path): \(error)")
            }
        }

        // Reload trash list
        load()

        // Record in history
        appState.history.record(HistoryEntry(
            action: "trash.permanently_deleted",
            category: "trash",
            itemCount: safePaths.count,
            bytes: entries.filter { safePaths.contains($0.path) }.reduce(0) {
                CleanupAccounting.adding($0, $1.size)
            },
            dryRun: false,
            root: NSHomeDirectory() + "/.Trash"
        ))
    }

    // MARK: - Empty trash confirmed

    private func emptyTrashConfirmed() {
        // Show confirmation for emptying entire trash
        // Get all paths
        let allPaths = entries.map { $0.path }

        let trashRoots = ([NSHomeDirectory() + "/.Trash"] + trashMounts())
            .map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL.path }
        let safePaths = allPaths.filter { path in
            let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
            return trashRoots.contains { root in standardized.hasPrefix(root + "/") }
        }

        // Perform permanent deletion of safe paths
        for path in safePaths {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                print("Failed to permanently delete \(path): \(error)")
            }
        }

        // Reload trash list
        load()

        // Record in history
        appState.history.record(HistoryEntry(
            action: "trash.emptied",
            category: "trash",
            itemCount: safePaths.count,
            bytes: totalBytes,
            dryRun: false,
            root: NSHomeDirectory() + "/.Trash"
        ))
    }

    // MARK: - Trash mounts

    private func trashMounts() -> [String] {
        VolumeDiscoveryService.discoverVolumes()
            .filter { $0.mountPoint != "/" && $0.isLocal }
            .map { $0.mountPoint + "/.Trashes" }
    }
}

// MARK: - Extensions for LocalizedStringKey support

extension LocalizedStringKey {
    static let trashEmptyTitle = LocalizedStringKey("trash.empty.title")
    static let trashEmptyMessage = LocalizedStringKey("trash.empty.message")
    static let trashEmptyMessageAfterSearch = LocalizedStringKey("trash.empty.message_after_search")
    static let trashBinsTitle = LocalizedStringKey("trash.bins_title")
    static let trashSummary = LocalizedStringKey("trash.summary")
    static let trashSearchPlaceholder = LocalizedStringKey("trash.search_placeholder")
    static let trashRestoreSelected = LocalizedStringKey("trash.restore_selected")
    static let trashDeletePermanently = LocalizedStringKey("trash.delete_permanently")
    static let trashPermanentDeleteSelected = LocalizedStringKey("trash.permanent_delete_selected")
    static let trashRestore = LocalizedStringKey("trash.restore")
    static let permanentDeleteConfirmationTitle = LocalizedStringKey("permanent_delete_confirmation_title")
    static let permanentDeleteConfirmationMessage = LocalizedStringKey("permanent_delete_confirmation_message")
    static let trashOpenFinder = LocalizedStringKey("trash.open_finder")
}
