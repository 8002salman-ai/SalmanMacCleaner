//
//  DashboardView.swift
//  SalmanMacCleaner
//
//  Dashboard: storage overview (volume ring + per-category bars), safety
//  posture summary, quick actions and local cleanup history.
//

import SwiftUI

struct DashboardView: View {
    @EnvironmentObject private var appState: AppState
    @State private var snapshot: StorageSnapshot?
    @State private var isRefreshing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Safety posture
                SafetyNoteView(text: appState.settings.safetySummary)
                    .accessibilityIdentifier("dashboard.safetySummary")

                // Storage overview
                GroupBox {
                    HStack(alignment: .top, spacing: 24) {
                        StorageRingView(snapshot: snapshot)
                            .frame(width: 170, height: 170)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("dashboard.storage.overview")
                                .font(.headline)
                            if let snapshot {
                                Text(snapshot.volumeName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                StorageLegendView(snapshot: snapshot)
                            } else {
                                Text("dashboard.storage.unavailable")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button {
                            refresh()
                        } label: {
                            Label("dashboard.refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshing)
                    }
                    .padding(8)

                    if let snapshot, !snapshot.categories.isEmpty {
                        Divider()
                        CategoryBarsView(categories: snapshot.categories, capacity: snapshot.totalCapacity)
                            .padding(.top, 8)
                    }
                } label: {
                    Label("dashboard.storage.title", systemImage: "internaldrive")
                }
                .accessibilityIdentifier("dashboard.storage")

                // Quick actions
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("dashboard.quick_actions")
                            .font(.headline)
                        HStack(spacing: 12) {
                            QuickActionButton(
                                title: "dashboard.action.large_files",
                                icon: "externaldrive.fill.badge.timemachine",
                                help: "dashboard.action.large_files.help"
                            ) {
                                appState.section = .largeFiles
                            }
                            QuickActionButton(
                                title: "dashboard.action.duplicates",
                                icon: "doc.on.doc.fill",
                                help: "dashboard.action.duplicates.help"
                            ) {
                                appState.section = .duplicates
                            }
                            QuickActionButton(
                                title: "dashboard.action.dev_caches",
                                icon: "hammer.fill",
                                help: "dashboard.action.dev_caches.help"
                            ) {
                                appState.section = .developerCaches
                            }
                            QuickActionButton(
                                title: "dashboard.action.startup",
                                icon: "power",
                                help: "dashboard.action.startup.help"
                            ) {
                                appState.section = .startupItems
                            }
                        }
                    }
                    .padding(8)
                } label: {
                    Label("dashboard.quick_actions.title", systemImage: "bolt")
                }

                // History preview
                HistoryView()
            }
            .padding(20)
        }
        .navigationTitle(AppSection.dashboard.title)
        .onAppear {
            if snapshot == nil { refresh() }
        }
        .task {
            if appState.settings.scanDevCachesOnLaunch && snapshot == nil {
                refresh()
            }
        }
    }

    private func refresh() {
        isRefreshing = true
        Task.detached(priority: .userInitiated) {
            let fresh = StorageOverview.snapshot()
            await MainActor.run {
                snapshot = fresh
                isRefreshing = false
            }
        }
    }
}

struct StorageRingView: View {
    let snapshot: StorageSnapshot?

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 18)
            if let snapshot, snapshot.usedFraction > 0 {
                Circle()
                    .trim(from: 0, to: snapshot.usedFraction)
                    .stroke(
                        AngularGradient(colors: [.blue, .purple, .pink], center: .center),
                        style: StrokeStyle(lineWidth: 18, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 4) {
                if let snapshot {
                    Text(FileUtilities.formattedBytes(snapshot.available))
                        .font(.headline)
                        .monospacedDigit()
                    Text("dashboard.storage.free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("dashboard.storage.ring.label"))
    }
}

struct StorageLegendView: View {
    let snapshot: StorageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LegendRow(color: .blue, title: "dashboard.storage.used", value: snapshot.used)
            LegendRow(color: .green, title: "dashboard.storage.available", value: snapshot.available)
            if snapshot.purgeable > 0 {
                LegendRow(color: .orange, title: "dashboard.storage.purgeable", value: snapshot.purgeable)
            }
            LegendRow(color: .gray, title: "dashboard.storage.capacity", value: snapshot.totalCapacity)
        }
        .font(.callout)
    }
}

struct LegendRow: View {
    let color: Color
    let title: LocalizedStringKey
    let value: Int64

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(FileUtilities.formattedBytes(value))
                .monospacedDigit()
        }
    }
}

struct CategoryBarsView: View {
    let categories: [DiskUsageCategory]
    let capacity: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(categories) { category in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Label(category.title, systemImage: category.icon)
                            .font(.callout)
                        Spacer()
                        Text(FileUtilities.formattedBytes(category.bytes))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        let fraction = capacity > 0
                            ? min(max(Double(category.bytes) / Double(capacity), 0.002), 1)
                            : 0.002
                        Capsule()
                            .fill(Color(hex: category.tint).opacity(0.85))
                            .frame(width: max(geometry.size.width * fraction, 4))
                    }
                    .frame(height: 8)
                    .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

struct QuickActionButton: View {
    let title: LocalizedStringKey
    let icon: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 26))
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(title)
    }
}
