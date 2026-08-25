//
//  TrashBinsView.swift
//  SalmanMacCleaner
//
//  Trash Bins: real inventory of the user Trash and per-volume trash
//  folders. macOS provides no supported third-party API to empty the Trash,
//  so the module opens the Trash in Finder and explains the recovery risk
//  honestly. Nothing here is ever deleted by the app.
//

import SwiftUI
import AppKit

public struct TrashEntry: Identifiable, Equatable {
    public var id: String { path }
    public var name: String
    public var path: String
    public var size: Int64
    public var isDirectory: Bool

    public init(name: String, path: String, size: Int64, isDirectory: Bool) {
        self.name = name
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
    }
}

struct TrashBinsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var entries: [TrashEntry] = []
    @State private var totalBytes: Int64 = 0
    @State private var isLoading = false
    @State private var heroMode = true

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .trashBins,
                    isBusy: isLoading,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: String(format: NSLocalizedString("trash.total_hint", comment: ""), totalBytes > 0 ? FileUtilities.formattedBytes(totalBytes) : "—"),
                    primaryAction: {
                        heroMode = false
                        load()
                    },
                    selectors: { EmptyView() }
                )
                .task { load() }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    PermissionBannerView(
                        message: NSLocalizedString("trash.empty_warning", comment: ""),
                        systemImage: "exclamationmark.triangle"
                    )
                    if entries.isEmpty {
                        EmptyStateView(
                            systemImage: "trash",
                            title: "trash.empty.title",
                            message: "trash.empty.message"
                        )
                    } else {
                        HStack {
                            Text(String(format: NSLocalizedString("trash.summary", comment: ""),
                                        entries.count, FileUtilities.formattedBytes(totalBytes)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash", isDirectory: true))
                            } label: {
                                Label("trash.open_finder", systemImage: "arrow.up.forward.app")
                            }
                            .buttonStyle(AuroraSecondaryButtonStyle())
                            Button {
                                load()
                            } label: {
                                Label("trash.refresh", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(AuroraSecondaryButtonStyle())
                        }
                        List(entries) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.fill")
                                    .foregroundStyle(.secondary)
                                Text(entry.name)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(FileUtilities.formattedBytes(entry.size))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contextMenu {
                                Button("results.reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                                }
                            }
                        }
                        .listStyle(.inset)
                    }
                    Spacer()
                }
                .padding(24)
            }
        }
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let trashRoots = [NSHomeDirectory() + "/.Trash"] + trashMounts()
            var found: [TrashEntry] = []
            var total: Int64 = 0
            for root in trashRoots {
                let url = URL(fileURLWithPath: root, isDirectory: true)
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for entry in contents {
                    guard let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey]) else { continue }
                    let size = Int64(values.fileAllocatedSize ?? values.fileSize ?? 0)
                    total += size
                    found.append(TrashEntry(
                        name: entry.lastPathComponent,
                        path: entry.path,
                        size: size,
                        isDirectory: values.isDirectory ?? false
                    ))
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

    private func trashMounts() -> [String] {
        VolumeDiscoveryService.discoverVolumes()
            .filter { $0.mountPoint != "/" && $0.isLocal }
            .map { $0.mountPoint + "/.Trashes" }
    }
}
