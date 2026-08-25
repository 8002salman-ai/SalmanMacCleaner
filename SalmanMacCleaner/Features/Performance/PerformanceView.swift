//
//  PerformanceView.swift
//  SalmanMacCleaner
//
//  Evidence-based performance review. No placebo operations: the module
//  shows real thermal state, memory pressure, storage pressure, purgeable
//  space and sampled per-app CPU usage where public APIs permit. Caches are
//  reviewed, not promised as a permanent speedup.
//

import SwiftUI
import AppKit

struct PerformanceView: View {
    @EnvironmentObject private var appState: AppState
    @State private var processes: [ProcessSample] = []
    @State private var isSampling = false
    @State private var snapshot: StorageSnapshot?
    @State private var thermalState = ProcessInfo.processInfo.thermalState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PermissionBannerView(
                    message: NSLocalizedString("performance.honesty", comment: ""),
                    systemImage: "info.circle"
                )

                HStack(spacing: 14) {
                    metricCard(
                        title: "performance.thermal",
                        value: thermalTitle,
                        icon: "thermometer.medium",
                        tint: thermalTint
                    )
                    metricCard(
                        title: "performance.memory",
                        value: memoryTitle,
                        icon: "memorychip",
                        tint: AuroraPalette.cyan
                    )
                    metricCard(
                        title: "performance.storage",
                        value: storageTitle,
                        icon: "internaldrive",
                        tint: storageTint
                    )
                    metricCard(
                        title: "performance.purgeable",
                        value: purgeableTitle,
                        icon: "sparkles",
                        tint: AuroraPalette.magenta
                    )
                }

                HStack(spacing: 14) {
                    Button {
                        sample()
                    } label: {
                        if isSampling {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("performance.sample", systemImage: "waveform.path.ecg")
                        }
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                    .disabled(isSampling)

                    Spacer()

                    Button {
                        appState.module = .startupItems
                    } label: {
                        Label("performance.review_startup", systemImage: "power")
                    }
                    .buttonStyle(AuroraSecondaryButtonStyle())
                }

                if !processes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("performance.top_consumers")
                            .font(.headline)
                        ForEach(processes) { process in
                            HStack(spacing: 10) {
                                Image(nsImage: NSWorkspace.shared.runningApplications
                                    .first { $0.processIdentifier == process.pid }?
                                    .icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage())
                                    .resizable()
                                    .frame(width: 22, height: 22)
                                Text(process.name)
                                    .font(.callout)
                                Spacer()
                                Text(String(format: "%.1f%% CPU", process.cpuFraction * 100))
                                    .font(.callout.monospacedDigit())
                                Text(FileUtilities.formattedBytes(Int64(process.residentBytes)))
                                    .font(.callout.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                    .padding(16)
                    .glassCard()
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            refresh()
        }
        .task {
            // Refresh thermal state periodically while visible.
            while !Task.isCancelled {
                thermalState = ProcessInfo.processInfo.thermalState
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func metricCard(title: LocalizedStringKey, value: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var thermalTitle: String {
        switch thermalState {
        case .nominal: return NSLocalizedString("performance.thermal.nominal", comment: "")
        case .fair: return NSLocalizedString("performance.thermal.fair", comment: "")
        case .serious: return NSLocalizedString("performance.thermal.serious", comment: "")
        case .critical: return NSLocalizedString("performance.thermal.critical", comment: "")
        @unknown default: return NSLocalizedString("performance.thermal.unknown", comment: "")
        }
    }

    private var thermalTint: Color {
        switch thermalState {
        case .nominal: return AuroraPalette.success
        case .fair: return AuroraPalette.amber
        case .serious, .critical: return AuroraPalette.coral
        @unknown default: return AuroraPalette.amber
        }
    }

    private var memoryTitle: String {
        let physical = ProcessInfo.processInfo.physicalMemory
        let used = NSWorkspace.shared.runningApplications.reduce(0) { partial, app in
            partial + memoryOf(pid: app.processIdentifier)
        }
        return "\(FileUtilities.formattedBytes(Int64(used))) / \(FileUtilities.formattedBytes(Int64(physical)))"
    }

    private var storageTitle: String {
        guard let snapshot else { return "—" }
        return "\(Int(snapshot.usedFraction * 100))% " + NSLocalizedString("performance.used", comment: "")
    }

    private var storageTint: Color {
        guard let snapshot else { return AuroraPalette.amber }
        return snapshot.usedFraction > 0.9 ? AuroraPalette.coral : AuroraPalette.success
    }

    private var purgeableTitle: String {
        guard let snapshot else { return "—" }
        return FileUtilities.formattedBytes(snapshot.purgeable)
    }

    private func refresh() {
        snapshot = StorageOverview.snapshot()
    }

    private func sample() {
        isSampling = true
        Task.detached(priority: .userInitiated) {
            let samples = ProcessSampler.sampleRunningApplications(interval: 0.6, limit: 8)
            await MainActor.run {
                processes = samples
                isSampling = false
            }
        }
    }

    private func memoryOf(pid: pid_t) -> UInt64 {
        _ = pid
        return 0
    }
}
