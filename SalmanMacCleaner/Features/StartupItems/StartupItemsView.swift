//
//  StartupItemsView.swift
//  SalmanMacCleaner
//
//  Startup & Background Items inventory: public-API discovery (SMAppService
//  status for this app, launch agents/daemons from supported locations),
//  broken-reference detection and impact explanation. Version 1 never
//  disables or removes anything automatically.
//

import SwiftUI
import ServiceManagement

struct StartupItemsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [StartupItemDetail] = []
    @State private var isLoading = false
    @State private var heroMode = true
    @State private var searchText = ""
    @State private var sourceFilter: StartupItemSource?

    var body: some View {
        Group {
            if heroMode {
                HeroScreenView(
                    module: .startupItems,
                    isBusy: isLoading,
                    lastScanText: nil,
                    permissionWarning: nil,
                    estimatedScope: NSLocalizedString("hero.startup.scope", comment: ""),
                    primaryAction: {
                        heroMode = false
                        load()
                    },
                    selectors: { EmptyView() }
                )
                .task { load() }
            } else {
                workspace
            }
        }
    }

    private var workspace: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button {
                    appState.module = .smartCare
                } label: {
                    Label("Back to Smart Care", systemImage: "chevron.left")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                .help("Return to the Smart Care dashboard")

                Text("Startup & Background Items")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }

            PermissionBannerView(
                message: StartupManager.readOnlyExplanation,
                systemImage: "eye.slash"
            )

            if let status = StartupManager.ownLoginItemStatus {
                HStack(spacing: 10) {
                    Text("startup.self_status")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(statusTitle(status))
                        .font(.callout.weight(.semibold))
                }
            }

            HStack(spacing: 12) {
                Button {
                    load()
                } label: {
                    Label("startup.refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
                .disabled(isLoading)

                Picker("startup.source_filter", selection: $sourceFilter) {
                    Text("startup.filter.all").tag(StartupItemSource?.none)
                    ForEach(StartupItemSource.allCases) { source in
                        Text(source.title).tag(StartupItemSource?.some(source))
                    }
                }
                .frame(width: 200)

                Spacer()
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if filteredItems.isEmpty && !isLoading {
                EmptyStateView(
                    systemImage: "power",
                    title: "startup.empty.title",
                    message: "startup.empty.message"
                )
            } else {
                List(filteredItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.source == .loginItems ? "person.crop.circle" : "gearshape.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)
                            if let executable = item.executable {
                                Text(executable)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        Spacer()
                        if item.isBroken {
                            StatusPill("startup.broken", kind: .warning)
                        }
                        if let isEnabled = item.isEnabled {
                            Text(isEnabled ? "startup.enabled" : "startup.disabled")
                                .font(.caption2)
                                .foregroundStyle(isEnabled ? AuroraPalette.success : AuroraPalette.amber)
                        }
                        Text(item.source.title)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .help(Text(item.detail))
                    .accessibilityElement(children: .combine)
                }
                .listStyle(.inset)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .searchable(text: $searchText, prompt: Text("search.items.prompt"))
    }

    private var filteredItems: [StartupItemDetail] {
        let filtered = items.filter { item in
            if let sourceFilter, item.source != sourceFilter { return false }
            if searchText.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(searchText)
                || (item.executable?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
        return filtered
    }

    private func load() {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let discovered = StartupManager.discover()
            await MainActor.run {
                items = discovered
                isLoading = false
            }
        }
    }

    private func statusTitle(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return NSLocalizedString("startup.self.enabled", comment: "")
        case .notRegistered: return NSLocalizedString("startup.self.not_registered", comment: "")
        case .requiresApproval: return NSLocalizedString("startup.self.requires_approval", comment: "")
        case .notFound: return NSLocalizedString("startup.self.not_found", comment: "")
        @unknown default: return NSLocalizedString("startup.self.unknown", comment: "")
        }
    }
}
