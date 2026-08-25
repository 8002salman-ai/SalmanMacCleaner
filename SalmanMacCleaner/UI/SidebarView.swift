//
//  SidebarView.swift
//  SalmanMacCleaner
//
//  Premium Aurora sidebar: full-height glass surface, grouped modules,
//  rounded translucent capsule selection with purple inner glow, distinct
//  hover/pressed/focus states, and graceful scrolling in short windows.
//

import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    var body: some View {
        ZStack {
            sidebarSurface
            List(selection: selectionBinding) {
                ForEach(SidebarGroup.allCases) { group in
                    Section {
                        ForEach(modules(in: group)) { module in
                            SidebarRow(module: module, isSelected: appState.module == module)
                                .tag(module)
                        }
                    } header: {
                        GlassSectionHeader(LocalizedStringKey(group.title))
                            .padding(.bottom, 2)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 10)
        }
        .safeAreaInset(edge: .bottom) {
            DryRunBadge()
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var sidebarSurface: some View {
        if accessibility.reduceTransparency {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor).opacity(0.92))
        } else {
            LinearGradient(
                colors: [Color.black.opacity(colorScheme == .dark ? 0.28 : 0.05),
                         Color.white.opacity(colorScheme == .dark ? 0.04 : 0.25)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var selectionBinding: Binding<SidebarModule?> {
        Binding(
            get: { appState.module },
            set: { newValue in
                if let newValue {
                    appState.module = newValue
                }
            }
        )
    }

    private func modules(in group: SidebarGroup) -> [SidebarModule] {
        SidebarModule.ordered.filter { $0.group == group }
    }
}

/// One sidebar row with hover/pressed/focus feedback.
struct SidebarRow: View {
    let module: SidebarModule
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AuroraPalette.electricPurple.opacity(isSelected ? 0.9 : 0.35),
                                     AuroraPalette.violet.opacity(isSelected ? 0.75 : 0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 26, height: 26)
                Image(systemName: module.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: isSelected ? AuroraPalette.electricPurple.opacity(0.6) : .clear, radius: 6)

            Text(module.title)
                .font(.callout.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(AuroraPalette.primaryText(colorScheme, increaseContrast: false))
                .lineLimit(1)

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(backgroundFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? AuroraPalette.electricPurple.opacity(0.45)
                                : Color.white.opacity(isHovering ? 0.08 : 0),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: isSelected ? AuroraPalette.electricPurple.opacity(0.28) : .clear,
                    radius: 8
                )
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(Text(module.title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var backgroundFill: Color {
        if isSelected {
            return AuroraPalette.electricPurple.opacity(colorScheme == .dark ? 0.24 : 0.20)
        }
        if isHovering {
            return Color.white.opacity(colorScheme == .dark ? 0.08 : 0.14)
        }
        return .clear
    }
}

/// Compact preview-mode badge pinned under the sidebar.
struct DryRunBadge: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Button {
            appState.module = .settings
        } label: {
            HStack(spacing: 6) {
                Image(systemName: appState.settings.dryRun ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .foregroundStyle(appState.settings.dryRun ? AuroraPalette.success : AuroraPalette.amber)
                Text(LocalizedStringKey(appState.settings.dryRun ? "badge.dry_run_on" : "badge.dry_run_off"))
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(Text(LocalizedStringKey(appState.settings.dryRun ? "badge.dry_run_on.help" : "badge.dry_run_off.help")))
    }
}
