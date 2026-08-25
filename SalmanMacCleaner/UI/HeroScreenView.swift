//
//  HeroScreenView.swift
//  SalmanMacCleaner
//
//  The premium pre-scan hero shared by every module: original artwork on the
//  left, information column on the right (eyebrow, title, benefit, three
//  capabilities), optional scope/mode selectors, a single anchored primary
//  action, last-scan information and permission warnings.
//

import SwiftUI

public struct HeroScreenView<Selectors: View>: View {
    let module: SidebarModule
    @EnvironmentObject private var permissionService: PermissionService
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var accessibility: AccessibilityEnvironment

    var primaryAction: () -> Void
    var isBusy: Bool
    var lastScanText: String?
    var permissionWarning: String?
    var estimatedScope: String?
    @ViewBuilder var selectors: () -> Selectors

    public init(
        module: SidebarModule,
        isBusy: Bool = false,
        lastScanText: String? = nil,
        permissionWarning: String? = nil,
        estimatedScope: String? = nil,
        primaryAction: @escaping () -> Void,
        @ViewBuilder selectors: @escaping () -> Selectors
    ) {
        self.module = module
        self.isBusy = isBusy
        self.lastScanText = lastScanText
        self.permissionWarning = permissionWarning
        self.estimatedScope = estimatedScope
        self.primaryAction = primaryAction
        self.selectors = selectors
    }

    public var body: some View {
        ScrollView {
            HStack(alignment: .center, spacing: 48) {
                artworkColumn
                infoColumn
            }
            .padding(.horizontal, 56)
            .padding(.vertical, 40)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var artworkColumn: some View {
        VStack(spacing: 14) {
            ModuleArtwork(module: module, size: 340)
                .transition(accessibility.reduceMotion ? .opacity : .scale.combined(with: .opacity))
        }
        .frame(width: 380)
        .accessibilityHidden(true)
    }

    private var infoColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text(module.group.title.uppercased())
                    .font(.caption.weight(.semibold))
                    .kerning(1.4)
                    .foregroundStyle(AuroraPalette.cyan)
                    .accessibilityAddTraits(.isHeader)

                Text(module.title)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(AuroraPalette.primaryText(colorScheme, increaseContrast: false))
                    .accessibilityAddTraits(.isHeader)

                Text(module.benefit)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(module.capabilities.enumerated()), id: \.offset) { _, capability in
                    CapabilityRow(
                        icon: capability.icon,
                        title: capability.title,
                        detail: capability.detail
                    )
                }
            }

            selectors()

            HStack(alignment: .center, spacing: 20) {
                Button(action: primaryAction) {
                    if isBusy {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Label(module.primaryActionTitle, systemImage: primarySymbol)
                    }
                }
                .buttonStyle(AuroraPrimaryButtonStyle())
                .disabled(isBusy)
                .accessibilityHint(Text("hero.primary.hint"))

                VStack(alignment: .leading, spacing: 3) {
                    if let lastScanText {
                        Label(lastScanText, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let estimatedScope {
                        Text(estimatedScope)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            if let permissionWarning {
                PermissionBannerView(message: permissionWarning, systemImage: "lock.shield")
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var primarySymbol: String {
        switch module {
        case .appUpdater: return "arrow.down.circle"
        case .permissions: return "lock.open"
        case .myTools, .activityHistory, .settings: return "arrow.right"
        default: return "magnifyingglass"
        }
    }
}

/// Segmented scan-mode selector used by Smart Care / Deep Scan heroes.
public struct ScanModeSelector: View {
    @Binding var mode: ScanMode

    public init(mode: Binding<ScanMode>) {
        self._mode = mode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("hero.scan_mode")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("hero.scan_mode", selection: $mode) {
                ForEach(ScanMode.allCases) { scanMode in
                    Text(scanMode.title).tag(scanMode)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 460)
            Text(mode.summary)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
    }
}

/// Volume selector with explicit opt-in flags for Deep Scan.
public struct VolumeSelector: View {
    @Binding var selectedVolumeIDs: Set<String>
    let volumes: [VolumeInfo]
    @EnvironmentObject private var appState: AppState

    public init(selectedVolumeIDs: Binding<Set<String>>, volumes: [VolumeInfo]) {
        self._selectedVolumeIDs = selectedVolumeIDs
        self.volumes = volumes
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("hero.volumes")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(volumes) { volume in
                Toggle(isOn: binding(for: volume)) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(volume.name)
                                .font(.callout.weight(.medium))
                            Text(VolumeDiscoveryService.classification(volume))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                            if volume.requiresOptIn {
                                Text("hero.volume.optin")
                                    .font(.caption2)
                                    .foregroundStyle(AuroraPalette.amber)
                            }
                        }
                        Text(volume.mountPoint + " · " + FileUtilities.formattedBytes(volume.used) + " used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func binding(for volume: VolumeInfo) -> Binding<Bool> {
        Binding(
            get: { selectedVolumeIDs.contains(volume.mountPoint) },
            set: { on in
                if on { selectedVolumeIDs.insert(volume.mountPoint) }
                else { selectedVolumeIDs.remove(volume.mountPoint) }
            }
        )
    }
}
