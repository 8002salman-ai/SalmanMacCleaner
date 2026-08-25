//
//  MyToolsView.swift
//  SalmanMacCleaner
//
//  My Tools: a searchable grid of direct tools using glass cards with hover
//  and keyboard focus behavior. Every card navigates to a real module.
//

import SwiftUI

struct MyToolsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""

    private struct Tool: Identifiable {
        let id: SidebarModule
        let title: String
        let icon: String

        init(_ module: SidebarModule, title: String, icon: String) {
            self.id = module
            self.title = title
            self.icon = icon
        }
    }

    private var tools: [Tool] {
        [
            Tool(.deepScan, title: NSLocalizedString("module.deep_scan", comment: ""), icon: "viewfinder"),
            Tool(.systemJunk, title: NSLocalizedString("module.system_junk", comment: ""), icon: "sparkles"),
            Tool(.appLeftovers, title: NSLocalizedString("module.app_leftovers", comment: ""), icon: "square.stack.3d.up.slash"),
            Tool(.developerCaches, title: NSLocalizedString("module.dev_caches", comment: ""), icon: "hammer"),
            Tool(.uninstaller, title: NSLocalizedString("module.uninstaller", comment: ""), icon: "arrow.uturn.down.square"),
            Tool(.appUpdater, title: NSLocalizedString("module.app_updater", comment: ""), icon: "arrow.down.circle"),
            Tool(.largeOldFiles, title: NSLocalizedString("module.large_old", comment: ""), icon: "externaldrive.badge.timemachine"),
            Tool(.duplicates, title: NSLocalizedString("module.duplicates", comment: ""), icon: "doc.on.doc"),
            Tool(.spaceLens, title: NSLocalizedString("module.space_lens", comment: ""), icon: "circle.hexagongrid"),
            Tool(.startupItems, title: NSLocalizedString("module.startup", comment: ""), icon: "power"),
            Tool(.permissions, title: NSLocalizedString("module.permissions", comment: ""), icon: "lock.shield"),
            Tool(.activityHistory, title: NSLocalizedString("module.activity", comment: ""), icon: "clock.arrow.circlepath"),
            Tool(.settings, title: NSLocalizedString("module.settings", comment: ""), icon: "gearshape.2"),
            Tool(.appUpdater, title: NSLocalizedString("tools.check_updates", comment: ""), icon: "arrow.clockwise")
        ]
    }

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(filteredTools) { tool in
                        ToolCard(module: tool.id, title: tool.title, icon: tool.icon) {
                            appState.module = tool.id
                        }
                    }
                }
            }
            .padding(28)
        }
        .searchable(text: $searchText, prompt: Text("tools.search"))
        .navigationTitle(NSLocalizedString("module.my_tools", comment: ""))
    }

    private var filteredTools: [Tool] {
        guard !searchText.isEmpty else { return tools }
        return tools.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }
}

/// One glass tool card with hover/pressed/focus feedback.
struct ToolCard: View {
    let module: SidebarModule
    let title: String
    let icon: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [AuroraPalette.electricPurple.opacity(isHovering ? 0.5 : 0.3),
                                         AuroraPalette.violet.opacity(isHovering ? 0.3 : 0.15)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 46, height: 46)
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                }
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(isHovering ? 0.22 : 0.1), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            }
            .scaleEffect(isHovering ? 1.02 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityHint(Text("tools.card.hint"))
    }
}
