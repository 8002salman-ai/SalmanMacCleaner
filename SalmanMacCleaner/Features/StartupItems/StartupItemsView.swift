//
//  StartupItemsView.swift
//  SalmanMacCleaner
//
//  Read-only Startup Manager. Version 1 deliberately does not modify startup
//  items; this view only lists what the app can see without elevated
//  privileges and explains why modification is disabled.
//

import SwiftUI

struct StartupItemsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var items: [StartupItem] = []
    @State private var isLoading = false
    @State private var searchText = ""
    @State private var sourceFilter: StartupItem.Source?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PermissionBannerView(
                message: StartupManager.readOnlyExplanation,
                systemImage: "eye.slash"
            )

            HStack(spacing: 12) {
                Button {
                    load()
                } label: {
                    Label("startup.refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Picker("startup.source_filter", selection: $sourceFilter) {
                    Text("startup.filter.all").tag(StartupItem.Source?.none)
                    ForEach([StartupItem.Source.loginItem, .launchAgent, .launchDaemon], id: \.rawValue) { source in
                        Text(sourceTitle(source)).tag(StartupItem.Source?.some(source))
                    }
                }
                .frame(width: 200)
                Spacer()

                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }

            if items.isEmpty && !isLoading {
                EmptyStateView(
                    systemImage: "power",
                    title: "startup.empty.title",
                    message: "startup.empty.message"
                )
            } else {
                List(filteredItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.source == .loginItem ? "person.crop.circle" : "gearshape.2")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .lineLimit(1)
                            Text(item.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                            Text(sourceTitle(item.source))
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }
                    .help(Text(item.detail))
                }
                .listStyle(.inset)
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .navigationTitle(AppSection.startupItems.title)
        .searchable(text: $searchText, prompt: Text("search.items.prompt"))
        .onAppear {
            if items.isEmpty { load() }
        }
    }

    private var filteredItems: [StartupItem] {
        let filtered = items.filter { item in
            if let sourceFilter, item.source != sourceFilter { return false }
            if searchText.isEmpty { return true }
            return item.name.localizedCaseInsensitiveContains(searchText)
                || item.path.localizedCaseInsensitiveContains(searchText)
        }
        return filtered
    }

    private func sourceTitle(_ source: StartupItem.Source) -> String {
        switch source {
        case .loginItem: return NSLocalizedString("startup.source.login_items", comment: "")
        case .launchAgent: return NSLocalizedString("startup.source.agents", comment: "")
        case .launchDaemon: return NSLocalizedString("startup.source.daemons", comment: "")
        }
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
}
