//
//  ActivityHistoryView.swift
//  SalmanMacCleaner
//
//  Activity & History: persisted scan and cleanup records with search,
//  filter, export, reveal-log and clear-with-confirmation. Path redaction
//  privacy setting is honored in every presented value.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ActivityHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var filter: Filter = .all
    @State private var showClearConfirmation = false

    enum Filter: String, CaseIterable, Identifiable {
        case all
        case scans
        case cleanups

        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return NSLocalizedString("activity.filter.all", comment: "")
            case .scans: return NSLocalizedString("activity.filter.scans", comment: "")
            case .cleanups: return NSLocalizedString("activity.filter.cleanups", comment: "")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Picker("activity.filter", selection: $filter) {
                    ForEach(Filter.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .frame(width: 170)
                Spacer()
                Button("activity.export_json") { exportJSON() }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                Button("activity.export_csv") { exportCSV() }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                Button("activity.clear", role: .destructive) {
                    showClearConfirmation = true
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }

            if visibleScans.isEmpty && visibleCleanups.isEmpty {
                EmptyStateView(
                    systemImage: "clock.arrow.circlepath",
                    title: "activity.empty.title",
                    message: "activity.empty.message"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if filter != .cleanups {
                            ForEach(visibleScans) { scan in
                                scanRow(scan)
                            }
                        }
                        if filter != .scans {
                            ForEach(visibleCleanups) { cleanup in
                                cleanupRow(cleanup)
                            }
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(24)
        .searchable(text: $searchText, prompt: Text("activity.search"))
        .alert("activity.clear.title", isPresented: $showClearConfirmation) {
            Button("activity.clear.confirm", role: .destructive) {
                appState.sessionStore.clearAll()
                appState.history.clear()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("activity.clear.message")
        }
    }

    private var visibleScans: [ScanHistoryRecord] {
        let filtered = searchText.isEmpty
            ? appState.sessionStore.scans
            : appState.sessionStore.scans.filter {
                $0.mode.localizedCaseInsensitiveContains(searchText)
                    || $0.scope.localizedCaseInsensitiveContains(searchText)
            }
        return Array(filtered.prefix(200))
    }

    private var visibleCleanups: [CleanupHistoryRecord] {
        let filtered = searchText.isEmpty
            ? appState.sessionStore.cleanups
            : appState.sessionStore.cleanups.filter {
                $0.action.localizedCaseInsensitiveContains(searchText)
                    || $0.category.localizedCaseInsensitiveContains(searchText)
            }
        return Array(filtered.prefix(200))
    }

    private func scanRow(_ scan: ScanHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "viewfinder")
                .foregroundStyle(AuroraPalette.electricPurple)
            VStack(alignment: .leading, spacing: 2) {
                Text(ScanMode(rawValue: scan.mode)?.title ?? scan.mode)
                    .font(.callout.weight(.medium))
                Text(appState.sessionStore.presentablePath(scan.scope))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text("\(scan.itemsScanned) items")
                .font(.caption.monospacedDigit())
            Text("\(scan.coveragePercent)% coverage")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(scan.provenance == ScanProvenance.incremental.rawValue ? "activity.incremental" : "activity.full")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
            Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cleanupRow(_ cleanup: CleanupHistoryRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(AuroraPalette.magenta)
            VStack(alignment: .leading, spacing: 2) {
                Text(cleanup.action)
                    .font(.callout.weight(.medium))
                Text(appState.sessionStore.presentablePath(cleanup.root))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(FileUtilities.formattedBytes(cleanup.bytes))
                .font(.caption.monospacedDigit())
            if cleanup.failedCount > 0 {
                Text("\(cleanup.failedCount) failed")
                    .font(.caption)
                    .foregroundStyle(AuroraPalette.coral)
            }
            Text(cleanup.previewOnly ? "history.mode.preview" : "history.mode.trash")
                .font(.caption2)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(cleanup.previewOnly ? AuroraPalette.success.opacity(0.15) : AuroraPalette.amber.opacity(0.15), in: Capsule())
            Text(cleanup.date.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func exportJSON() {
        guard let data = appState.sessionStore.exportJSON() else { return }
        savePanel(data: data, fileName: "SalmanMacCleaner-Activity.json", contentType: .json)
    }

    private func exportCSV() {
        guard let data = appState.sessionStore.exportCSV() else { return }
        savePanel(data: data, fileName: "SalmanMacCleaner-Activity.csv", contentType: .commaSeparatedText)
    }

    private func savePanel(data: Data, fileName: String, contentType: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [contentType]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
