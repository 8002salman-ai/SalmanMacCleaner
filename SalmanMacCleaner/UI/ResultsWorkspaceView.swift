//
//  ResultsWorkspaceView.swift
//  SalmanMacCleaner
//
//  The premium post-scan workspace: summary header, reclaimable-space ring,
//  coverage status, summary tiles, category navigation, virtualized item
//  list, details inspector, and a sticky bottom action bar. The Preview Mode
//  control is deliberate: Clean becomes available only after the user
//  explicitly leaves Preview Mode (with confirmation).
//

import SwiftUI
import AppKit

public enum ResultsCategory: String, CaseIterable, Identifiable {
    case safe
    case review
    case protected
    case applications
    case largeFiles
    case duplicates
    case coverage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .safe: return NSLocalizedString("results.cat.safe", comment: "")
        case .review: return NSLocalizedString("results.cat.review", comment: "")
        case .protected: return NSLocalizedString("results.cat.protected", comment: "")
        case .applications: return NSLocalizedString("results.cat.apps", comment: "")
        case .largeFiles: return NSLocalizedString("results.cat.large", comment: "")
        case .duplicates: return NSLocalizedString("results.cat.duplicates", comment: "")
        case .coverage: return NSLocalizedString("results.cat.coverage", comment: "")
        }
    }

    public var systemImage: String {
        switch self {
        case .safe: return "checkmark.circle.fill"
        case .review: return "eye.fill"
        case .protected: return "lock.fill"
        case .applications: return "square.grid.2x2.fill"
        case .largeFiles: return "externaldrive.fill"
        case .duplicates: return "doc.on.doc.fill"
        case .coverage: return "shield.lefthalf.filled"
        }
    }
}

@MainActor
public final class ResultsWorkspaceModel: ObservableObject {
    @Published public var outcome: ScanOutcome?
    @Published public var items: [ClassifiedRecord] = []
    @Published public var category: ResultsCategory = .safe
    @Published public var selection: Set<String> = []
    @Published public var searchText = ""
    @Published public var showCleanConfirmation = false
    @Published public var showPreviewExitConfirmation = false
    @Published public var cleanupMessage: String?

    public let coordinator: DeepScanCoordinator

    public init(coordinator: DeepScanCoordinator = .shared) {
        self.coordinator = coordinator
    }

    public func load(outcome: ScanOutcome) {
        self.outcome = outcome
        reloadItems()
        smartSelect()
    }

    public func reloadItems() {
        guard let outcome else {
            items = []
            return
        }
        let safety: SafetyLevel? = category == .safe ? .safe : (category == .review ? .review : (category == .protected ? .protected : nil))
        Task {
            let fetched = await coordinator.indexStore.classifiedItems(
                scanID: outcome.scanID,
                safety: safety,
                category: nil,
                limit: 2_000
            )
            self.items = fetched
            self.smartSelect()
        }
    }

    /// Only SAFE items may be smart-selected; REVIEW/PROTECTED never are.
    private func smartSelect() {
        guard SettingsStore.shared.smartSelection else { return }
        let safeIDs = Set(items.filter { $0.safetyLevel == .safe }.map { $0.path })
        selection = selection.intersection(safeIDs).union(safeIDs)
    }

    public var selectedBytes: Int64 {
        items.filter { selection.contains($0.path) }.reduce(0) { $0 + $1.allocatedSize }
    }

    public var visibleItems: [ClassifiedRecord] {
        guard !searchText.isEmpty else { return items }
        return items.filter {
            $0.path.localizedCaseInsensitiveContains(searchText)
                || $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Build the plan from explicit selection with live identity capture.
    public func buildPlan(previewOnly: Bool) -> CleanupPlan {
        var records: [FileRecord] = []
        for item in items where selection.contains(item.path) {
            if let record = MetadataCollector.collect(url: URL(fileURLWithPath: item.path)) {
                records.append(record)
            }
        }
        let selected = records.map { ScannedItem(path: $0.path, size: $0.allocatedSize) }
        let root = outcome?.coverage.scannedRoots.first ?? PathSafety.userHome.path
        return CleanupPlanBuilder.build(
            selection: selected,
            records: records,
            containmentRoot: root,
            previewOnly: previewOnly,
            scanID: outcome?.scanID
        )
    }
}

public struct ResultsWorkspaceView: View {
    @StateObject private var model: ResultsWorkspaceModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    let outcome: ScanOutcome

    public init(outcome: ScanOutcome, coordinator: DeepScanCoordinator = .shared) {
        self.outcome = outcome
        _model = StateObject(wrappedValue: ResultsWorkspaceModel(coordinator: coordinator))
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryHeader
                    categoryTabs
                    itemList
                }
                .padding(28)
            }
            bottomBar
        }
        .onAppear {
            model.load(outcome: outcome)
        }
        .cleanupConfirmation(
            isPresented: $model.showCleanConfirmation,
            config: .standard(
                itemCount: model.selection.count,
                totalBytes: model.selectedBytes,
                destructive: !appState.settings.dryRun
            ),
            onConfirm: { performCleanup() }
        )
        .alert("results.exit_preview.title", isPresented: $model.showPreviewExitConfirmation) {
            Button("results.exit_preview.confirm", role: .destructive) {
                appState.settings.dryRun = false
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("results.exit_preview.message")
        }
    }

    // MARK: - Summary header

    private var summaryHeader: some View {
        HStack(alignment: .center, spacing: 28) {
            ReclaimRing(
                safeBytes: outcome.safeBytes,
                reviewBytes: outcome.reviewBytes,
                protectedBytes: outcome.protectedBytes
            )
            .frame(width: 150, height: 150)

            VStack(alignment: .leading, spacing: 10) {
                Text("results.summary.title")
                    .font(.title.weight(.bold))
                Text(String(format: NSLocalizedString("results.summary.subtitle", comment: ""),
                            FileUtilities.formattedBytes(outcome.safeBytes + outcome.reviewBytes)))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    StatusPill("results.provenance.\(outcome.provenance.rawValue)", kind: .info)
                    StatusPill("results.coverage.\(outcome.coverage.confidence.rawValue)", kind: coverageKind)
                    if outcome.coverage.limitedByPermission {
                        StatusPill("results.coverage.limited", kind: .warning)
                    }
                }
                if outcome.coverage.limitedByPermission {
                    Text(outcome.coverage.permissionReason ?? "coverage.limited.reason_not_granted")
                        .font(.caption)
                        .foregroundStyle(AuroraPalette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("results.open_permissions") {
                        PermissionService.shared.openFullDiskAccessSettings()
                    }
                    .buttonStyle(.link)
                }
                if outcome.safeBytes + outcome.reviewBytes == 0 {
                    Text("results.zero_candidates_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            summaryTiles
        }
    }

    private var coverageKind: StatusPill.Kind {
        if outcome.coverage.limitedByPermission { return .warning }
        switch outcome.coverage.confidence {
        case .complete, .mostlyComplete: return .ok
        case .partial: return .warning
        case .unknown: return .unavailable
        }
    }

    private var summaryTiles: some View {
        VStack(spacing: 10) {
            tile("results.tile.scanned", value: "\(outcome.itemsScanned)")
            tile("results.tile.apps", value: "\(outcome.applicationCount)")
            tile("results.tile.duplicates", value: "\(outcome.duplicateGroupCount)")
        }
        .frame(width: 190)
    }

    private func tile(_ title: LocalizedStringKey, value: String) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassCard()
    }

    // MARK: - Categories

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ResultsCategory.allCases) { category in
                    Button {
                        withAnimation(.easeOut(duration: accessibility.reduceMotion ? 0 : 0.2)) {
                            model.category = category
                            model.reloadItems()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: category.systemImage)
                            Text(category.title)
                        }
                        .font(.callout.weight(model.category == category ? .semibold : .regular))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            model.category == category
                                ? AnyShapeStyle(AuroraPalette.electricPurple.opacity(0.3))
                                : AnyShapeStyle(Color.white.opacity(0.06)),
                            in: Capsule()
                        )
                        .overlay {
                            Capsule().strokeBorder(
                                model.category == category
                                    ? AuroraPalette.electricPurple.opacity(0.6)
                                    : Color.white.opacity(0.08),
                                lineWidth: 1
                            )
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Items

    @ViewBuilder
    private var itemList: some View {
        switch model.category {
        case .coverage:
            coverageView
        case .applications:
            Text("results.apps_hint")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        default:
            if model.visibleItems.isEmpty {
                Text("results.empty")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(model.visibleItems) { item in
                        ResultItemRow(
                            item: item,
                            isSelected: model.selection.contains(item.path),
                            selectable: item.safetyLevel != .protected,
                            onToggle: {
                                if item.safetyLevel == .protected { return }
                                if model.selection.contains(item.path) {
                                    model.selection.remove(item.path)
                                } else {
                                    model.selection.insert(item.path)
                                }
                            }
                        )
                    }
                }
            }
        }
    }

    private var coverageView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(outcome.coverage.summaryText)
                .font(.callout)
            CoverageDetailRow(title: "coverage.scanned_roots", count: outcome.coverage.scannedRoots.count)
            CoverageDetailRow(title: "coverage.partial_roots", count: outcome.coverage.partialRoots.count)
            CoverageDetailRow(title: "coverage.denied_roots", count: outcome.coverage.deniedRoots.count)
            CoverageDetailRow(title: "coverage.not_granted_roots", count: outcome.coverage.notGrantedRoots.count)
            CoverageDetailRow(title: "coverage.sip_roots", count: outcome.coverage.sipProtectedRoots.count)
            CoverageDetailRow(title: "coverage.skipped_network", count: outcome.coverage.skippedNetworkVolumes.count)
            CoverageDetailRow(title: "coverage.skipped_timemachine", count: outcome.coverage.skippedTimeMachine.count)
            CoverageDetailRow(title: "coverage.symlinks_rejected", count: outcome.coverage.symlinksRejected)
            CoverageDetailRow(title: "coverage.errors", count: outcome.coverage.totalErrors)

            if !outcome.coverage.rootDetails.isEmpty {
                Divider().overlay(Color.white.opacity(0.08))
                Text("coverage.root_details")
                    .font(.subheadline.weight(.semibold))
                ForEach(outcome.coverage.rootDetails) { detail in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: stateIcon(detail.state))
                            .foregroundStyle(stateTint(detail.state))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(detail.root)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let reason = detail.reason {
                                Text(reason)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(stateTitle(detail.state))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func stateTitle(_ state: CoverageState) -> String {
        switch state {
        case .scanned: return NSLocalizedString("coverage.state.scanned", comment: "")
        case .partial: return NSLocalizedString("coverage.state.partial", comment: "")
        case .denied: return NSLocalizedString("coverage.state.denied", comment: "")
        case .sipProtected: return NSLocalizedString("coverage.state.sip", comment: "")
        case .skippedNotGranted: return NSLocalizedString("coverage.state.not_granted", comment: "")
        case .skippedNetwork: return NSLocalizedString("coverage.state.network", comment: "")
        case .skippedTimeMachine: return NSLocalizedString("coverage.state.time_machine", comment: "")
        case .skippedMount: return NSLocalizedString("coverage.state.mount", comment: "")
        case .missing: return NSLocalizedString("coverage.state.missing", comment: "")
        }
    }

    private func stateIcon(_ state: CoverageState) -> String {
        switch state {
        case .scanned: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .denied: return "xmark.circle.fill"
        case .sipProtected: return "lock.fill"
        case .skippedNotGranted: return "lock.open.fill"
        case .skippedNetwork: return "network.slash"
        case .skippedTimeMachine: return "clock.arrow.circlepath"
        case .skippedMount: return "externaldrive.badge.xmark"
        case .missing: return "questionmark.circle.fill"
        }
    }

    private func stateTint(_ state: CoverageState) -> Color {
        switch state {
        case .scanned: return AuroraPalette.success
        case .partial, .denied, .missing: return AuroraPalette.coral
        case .sipProtected, .skippedNotGranted: return AuroraPalette.amber
        case .skippedNetwork, .skippedTimeMachine, .skippedMount: return AuroraPalette.cyan
        }
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Label {
                Text(String(format: NSLocalizedString("results.selected", comment: ""), model.selection.count))
            } icon: {
                Image(systemName: "checkmark.circle")
            }
            Text(FileUtilities.formattedBytes(model.selectedBytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)

            Spacer()

            // Deliberate Preview Mode control — Clean is not permanently
            // disabled; the user can exit Preview Mode here with confirmation.
            Button {
                if appState.settings.dryRun {
                    model.showPreviewExitConfirmation = true
                } else {
                    appState.settings.dryRun = true
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.settings.dryRun ? "eye.fill" : "trash.fill")
                    Text(appState.settings.dryRun ? "results.preview_on" : "results.preview_off")
                }
            }
            .buttonStyle(AuroraSecondaryButtonStyle())

            Button("results.review_selected") {
                model.showCleanConfirmation = true
            }
            .buttonStyle(AuroraSecondaryButtonStyle())
            .disabled(model.selection.isEmpty)

            Button("results.clean_selected") {
                model.showCleanConfirmation = true
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .disabled(appState.settings.dryRun || model.selection.isEmpty)
            .help(appState.settings.dryRun
                  ? Text("results.clean_disabled_preview")
                  : Text("results.clean_help"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    private func performCleanup() {
        let plan = model.buildPlan(previewOnly: appState.settings.dryRun)
        guard !plan.items.isEmpty else {
            model.cleanupMessage = NSLocalizedString("results.cleanup.empty", comment: "")
            return
        }
        appState.beginActivity(.cleaning(detail: NSLocalizedString("results.cleaning", comment: "")))
        let task = Task {
            let result = await CleanupExecutor.shared.execute(
                plan: plan,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            if Task.isCancelled { return }
            appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                action: NSLocalizedString("history.action.results", comment: ""),
                category: plan.items.first?.category.rawValue ?? "unknown",
                itemCount: plan.items.count,
                bytes: result.bytesReclaimed,
                previewOnly: plan.previewOnly,
                movedCount: result.moved.count,
                failedCount: result.failedCount,
                root: plan.items.first?.containmentRoot ?? ""
            ))
            appState.endActivity(message: String(
                format: plan.previewOnly
                    ? NSLocalizedString("results.preview_done", comment: "")
                    : NSLocalizedString("results.clean_done", comment: ""),
                result.succeededCount
            ))
            model.reloadItems()
            model.selection = []
        }
        withExtendedLifetime(task) {}
    }
}

struct ResultItemRow: View {
    let item: ClassifiedRecord
    let isSelected: Bool
    let selectable: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { isSelected }, set: { _ in onToggle() }))
                .toggleStyle(.checkbox)
                .disabled(!selectable)
                .labelsHidden()

            Image(systemName: item.safetyLevel == .safe ? "doc" : "doc.text")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            SafetyBadge(level: item.safetyLevel)
            VStack(alignment: .trailing, spacing: 2) {
                Text(FileUtilities.formattedBytes(item.allocatedSize))
                    .font(.callout.monospacedDigit())
                if item.allocatedSize != item.logicalSize {
                    Text("· " + FileUtilities.formattedBytes(item.logicalSize))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 110, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.white.opacity(isSelected ? 0.05 : 0.02), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable { onToggle() }
        }
        .contextMenu {
            Button("results.quicklook") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
            Button("results.reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct CoverageDetailRow: View {
    let title: LocalizedStringKey
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .font(.callout)
    }
}
