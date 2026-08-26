//
//  ResultsWorkspaceView.swift
//  SalmanMacCleaner
//
//  Compact native SwiftUI glass workspace (min 980x680): compact top summary
//  header, collapsible category rail, search/sort toolbar, virtualized item
//  list with checkbox, tooltip, source, size, safety badge, and a sticky
//  bottom glass action bar.
//
//  Strictly no page-level scrolling: only the result list container scrolls.
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

public enum ResultsSortOption: String, CaseIterable, Identifiable {
    case sizeDescending
    case sizeAscending
    case nameAscending
    case nameDescending
    case dateDescending

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sizeDescending: return NSLocalizedString("results.sort.size_desc", comment: "")
        case .sizeAscending: return NSLocalizedString("results.sort.size_asc", comment: "")
        case .nameAscending: return NSLocalizedString("results.sort.name_asc", comment: "")
        case .nameDescending: return NSLocalizedString("results.sort.name_desc", comment: "")
        case .dateDescending: return NSLocalizedString("results.sort.date_desc", comment: "")
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
    @Published public var sortOption: ResultsSortOption = .sizeDescending
    @Published public var isRailCollapsed = false
    @Published public var showCleanConfirmation = false
    @Published public var showPreviewExitConfirmation = false
    @Published public var cleanupMessage: String?
    /// The exact outcome of the last preview/cleanup run, or nil.
    @Published public var report: ExecutedCleanupResult?
    @Published public var isCleaning = false

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
        let safety: SafetyLevel?
        switch category {
        case .safe: safety = .safe
        case .review: safety = .review
        case .protected: safety = .protected
        default: safety = nil
        }

        Task {
            let fetched = await coordinator.indexStore.classifiedItems(
                scanID: outcome.scanID,
                safety: safety,
                category: nil,
                limit: 5_000
            )
            self.items = fetched
            self.smartSelect()
        }
    }

    /// Only SAFE items may be smart-selected; REVIEW/PROTECTED never are.
    public func smartSelect() {
        guard SettingsStore.shared.smartSelection else { return }
        let safeIDs = Set(items.filter { $0.safetyLevel == .safe }.map { $0.path })
        selection = selection.intersection(safeIDs).union(safeIDs)
    }

    public func selectAllVisible() {
        let selectable = visibleItems.filter { $0.safetyLevel != .protected }.map { $0.path }
        selection.formUnion(selectable)
    }

    public func deselectAll() {
        selection.removeAll()
    }

    /// Calculate unique selected bytes without parent/descendant double-counting.
    public var selectedBytes: Int64 {
        let selectedRecords = items.filter { selection.contains($0.path) }
        return CleanupPlanBuilder.uniqueBytes(for: selectedRecords)
    }

    public var selectedConfirmationDetails: [String] {
        items
            .filter { selection.contains($0.path) }
            .sorted { $0.path < $1.path }
            .map {
                ConfirmationDialogConfig.detailLine(
                    path: $0.path,
                    category: $0.junkCategory.title,
                    size: $0.allocatedSize,
                    confidence: $0.safetyLevel.title,
                    reason: $0.reason
                )
            }
    }

    public var visibleItems: [ClassifiedRecord] {
        var list = items
        if !searchText.isEmpty {
            list = list.filter {
                $0.path.localizedCaseInsensitiveContains(searchText)
                    || $0.name.localizedCaseInsensitiveContains(searchText)
                    || $0.reason.localizedCaseInsensitiveContains(searchText)
            }
        }
        switch sortOption {
        case .sizeDescending:
            list.sort { $0.allocatedSize > $1.allocatedSize }
        case .sizeAscending:
            list.sort { $0.allocatedSize < $1.allocatedSize }
        case .nameAscending:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .nameDescending:
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedDescending }
        case .dateDescending:
            list.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        }
        return list
    }

    /// Build the plan from the exact current selection with live identity capture
    /// and descendant pruning.
    public func buildDraft(previewOnly: Bool,
                           libraryRoots: [String] = [],
                           reviewRoots: [String] = []) -> CleanupPlanDraft {
        var recordsByPath: [String: ClassifiedRecord] = [:]
        for item in items {
            let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.path
            if recordsByPath[canonical] == nil {
                recordsByPath[canonical] = item
            }
        }
        var records: [FileRecord] = []
        var selected: [ScannedItem] = []
        var preclassified: [String: JunkVerdict] = [:]
        var unplanned: [(path: String, reason: String, bytes: Int64)] = []

        for path in selection.sorted() {
            let canonicalSelectionPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard let listed = recordsByPath[canonicalSelectionPath] else {
                unplanned.append((
                    canonicalSelectionPath,
                    NSLocalizedString("plan.skip.not_listed", comment: "") + " \(canonicalSelectionPath)",
                    0
                ))
                continue
            }
            guard let record = MetadataCollector.collect(
                url: URL(fileURLWithPath: canonicalSelectionPath, isDirectory: false)
            ) else {
                unplanned.append((
                    canonicalSelectionPath,
                    NSLocalizedString("plan.skip.no_record", comment: "") + " \(canonicalSelectionPath)",
                    listed.allocatedSize
                ))
                continue
            }
            records.append(record)
            preclassified[record.path] = JunkVerdict(
                category: listed.junkCategory,
                safety: listed.safetyLevel,
                reason: listed.reason,
                autoSelectable: listed.safetyLevel == .safe,
                regenerable: listed.safetyLevel != .protected,
                sourceRule: "scan-index"
            )
            selected.append(ScannedItem(
                path: record.path,
                size: record.allocatedSize,
                isDirectory: record.isDirectory,
                device: record.device,
                inode: record.inode
            ))
        }

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selected,
            records: records,
            containmentRoot: containmentRoot(for: Array(selection)),
            previewOnly: previewOnly,
            scanID: outcome?.scanID,
            libraryRoots: libraryRoots,
            reviewRoots: reviewRoots,
            preclassified: preclassified
        )
        return CleanupPlanDraft(
            plan: draft.plan,
            rejections: draft.rejections + unplanned,
            selectedCount: draft.selectedCount + unplanned.count,
            selectedBytes: CleanupAccounting.adding(
                draft.selectedBytes,
                unplanned.reduce(Int64(0)) { CleanupAccounting.adding($0, $1.bytes) }
            )
        )
    }

    public func containmentRoot(for paths: [String]) -> String {
        let home = PathSafety.userHome.path
        guard !paths.isEmpty else { return home }
        let roots = ((outcome?.coverage.scannedRoots ?? []) + [home])
            .filter { root in paths.allSatisfy { PathSafety.isPath($0, inside: root) } }
        return roots.max { $0.count < $1.count } ?? home
    }

    /// Remove the items that moved to the Trash from the results and update totals.
    public func applyExecuted(_ result: ExecutedCleanupResult, appState: AppState? = nil) {
        report = result
        guard !result.previewOnly else { return }

        let moved = Set(result.moved)
        guard !moved.isEmpty else { return }

        // Remove moved items and descendants from memory
        items.removeAll { item in
            moved.contains(item.path) || moved.contains(where: { parent in PathSafety.isPath(item.path, inside: parent) })
        }
        selection.subtract(moved)

        // Reflect confirmed Trash movement immediately. The index update is
        // asynchronous and must not leave the results screen showing stale
        // counts while it completes.
        if var updated = outcome {
            let removedBytes = result.movedBytes
            updated.itemsScanned = max(0, updated.itemsScanned - moved.count)
            updated.bytesIndexed = max(0, updated.bytesIndexed - removedBytes)
            updated.safeBytes = max(0, updated.safeBytes - removedBytes)
            outcome = updated
            appState?.lastOutcome = updated
        }

        if let scanID = outcome?.scanID {
            Task {
                await coordinator.indexStore.deleteRecordsAndDescendants(scanID: scanID, paths: Array(moved))
                let totals = await coordinator.indexStore.recalculateTotals(scanID: scanID)
                await MainActor.run {
                    if var updated = self.outcome {
                        updated.itemsScanned = totals.itemsScanned
                        updated.bytesIndexed = totals.bytesIndexed
                        updated.safeBytes = totals.safeBytes
                        updated.reviewBytes = totals.reviewBytes
                        updated.protectedBytes = totals.protectedBytes
                        self.outcome = updated
                        appState?.lastOutcome = updated
                    }
                }
            }
        }
    }
}

public struct ResultsWorkspaceView: View {
    @StateObject private var model: ResultsWorkspaceModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    private let initialOutcome: ScanOutcome

    private var outcome: ScanOutcome { model.outcome ?? initialOutcome }

    public init(outcome: ScanOutcome, coordinator: DeepScanCoordinator = .shared) {
        self.initialOutcome = outcome
        _model = StateObject(wrappedValue: ResultsWorkspaceModel(coordinator: coordinator))
    }

    public var body: some View {
        VStack(spacing: 0) {
            topSummaryBar
            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 0) {
                if !model.isRailCollapsed {
                    collapsibleRail
                        .frame(width: 220)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Divider().overlay(Color.white.opacity(0.08))
                }

                VStack(spacing: 0) {
                    listToolbar
                    Divider().overlay(Color.white.opacity(0.05))

                    // Strictly no page-level scrolling: only this list view scrolls
                    itemScrollView
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            if model.report != nil {
                cleanupReportBar
            }

            bottomActionBar
        }
        .frame(minWidth: 980, minHeight: 680)
        .background {
            AuroraBackground { EmptyView() }
        }
        .onAppear {
            model.load(outcome: outcome)
        }
        .cleanupConfirmation(
            isPresented: $model.showCleanConfirmation,
            config: .standard(
                itemCount: model.selection.count,
                totalBytes: model.selectedBytes,
                previewOnly: appState.settings.dryRun,
                details: model.selectedConfirmationDetails
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

    // MARK: - Top Summary Bar

    private var topSummaryBar: some View {
        HStack(alignment: .center, spacing: 20) {
            ReclaimRing(
                safeBytes: outcome.safeBytes,
                reviewBytes: outcome.reviewBytes,
                protectedBytes: outcome.protectedBytes
            )
            .frame(width: 76, height: 76)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("results.summary.title")
                        .font(.headline.weight(.bold))
                    StatusPill("results.provenance.\(outcome.provenance.rawValue)", kind: .info)
                    StatusPill("results.coverage.\(outcome.coverage.confidence.rawValue)", kind: coverageKind)
                    if outcome.coverage.limitedByPermission {
                        StatusPill("results.coverage.limited", kind: .warning)
                    }
                }
                Text(String(format: NSLocalizedString("results.summary.subtitle", comment: ""),
                            FileUtilities.formattedBytes(outcome.safeBytes + outcome.reviewBytes)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if outcome.coverage.limitedByPermission {
                    HStack(spacing: 6) {
                        Text(outcome.coverage.permissionReason ?? "coverage.limited.reason_not_granted")
                            .font(.caption2)
                            .foregroundStyle(AuroraPalette.amber)
                        Button("results.open_permissions") {
                            PermissionService.shared.openFullDiskAccessSettings()
                        }
                        .buttonStyle(.link)
                        .font(.caption2)
                    }
                }
            }

            Spacer()

            HStack(spacing: 12) {
                summaryTile("results.tile.scanned", value: "\(outcome.itemsScanned)")
                summaryTile("results.tile.bytes", value: FileUtilities.formattedBytes(outcome.bytesIndexed))
                summaryTile("results.tile.elapsed", value: String(format: "%.1fs", outcome.finishedAt.timeIntervalSince(outcome.startedAt)))

                Button {
                    withAnimation(.easeInOut(duration: accessibility.reduceMotion ? 0 : 0.2)) {
                        model.isRailCollapsed.toggle()
                    }
                } label: {
                    Image(systemName: model.isRailCollapsed ? "sidebar.left" : "sidebar.leading")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help(NSLocalizedString("results.toggle_rail", comment: ""))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func summaryTile(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
    }

    private var coverageKind: StatusPill.Kind {
        if outcome.coverage.limitedByPermission { return .warning }
        switch outcome.coverage.confidence {
        case .complete, .mostlyComplete: return .ok
        case .partial: return .warning
        case .unknown: return .unavailable
        }
    }

    // MARK: - Collapsible Rail

    private var collapsibleRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ResultsCategory.allCases) { cat in
                Button {
                    withAnimation(.easeOut(duration: accessibility.reduceMotion ? 0 : 0.15)) {
                        model.category = cat
                        model.reloadItems()
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: cat.systemImage)
                            .font(.system(size: 13))
                            .foregroundStyle(model.category == cat ? AuroraPalette.electricPurple : .secondary)
                            .frame(width: 20)
                        Text(cat.title)
                            .font(.callout.weight(model.category == cat ? .semibold : .regular))
                            .foregroundStyle(model.category == cat ? .primary : .secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        model.category == cat
                            ? AnyShapeStyle(AuroraPalette.electricPurple.opacity(0.2))
                            : AnyShapeStyle(Color.clear),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .overlay {
                        if model.category == cat {
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(AuroraPalette.electricPurple.opacity(0.4), lineWidth: 1)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.black.opacity(0.15))
    }

    // MARK: - List Toolbar

    private var listToolbar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("results.search_placeholder", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                if !model.searchText.isEmpty {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: 280)

            Spacer()

            Picker(selection: $model.sortOption, label: Text("results.sort_label")) {
                ForEach(ResultsSortOption.allCases) { opt in
                    Text(opt.title).tag(opt)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 170)

            if model.category == .safe {
                Button(action: { model.smartSelect() }) {
                    Label("results.select_all_safe", systemImage: "checkmark.circle")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            } else if model.category == .review {
                Button(action: { model.selectAllVisible() }) {
                    Label("results.select_all", systemImage: "checkmark.square")
                }
                .buttonStyle(AuroraSecondaryButtonStyle())
            }

            if !model.selection.isEmpty {
                Button(action: { model.deselectAll() }) {
                    Text("results.deselect_all")
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.02))
    }

    // MARK: - Scrollable Items List

    @ViewBuilder
    private var itemScrollView: some View {
        ScrollView {
            switch model.category {
            case .coverage:
                coverageView
                    .padding(16)
            case .applications:
                Text("results.apps_hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(32)
                    .frame(maxWidth: .infinity)
            default:
                if model.visibleItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("results.empty")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(48)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 4) {
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
                    .padding(12)
                }
            }
        }
    }

    // MARK: - Coverage View

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

    // MARK: - Bottom Action Bar

    private var bottomActionBar: some View {
        HStack(spacing: 16) {
            Label {
                Text(String(format: NSLocalizedString("results.selected", comment: ""), model.selection.count))
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AuroraPalette.electricPurple)
            }
            Text(FileUtilities.formattedBytes(model.selectedBytes))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(LocalizedStringKey(appState.settings.dryRun ? "selection.preview_only" : "selection.will_trash"))
                .font(.caption)
                .foregroundStyle(appState.settings.dryRun ? Color.green : Color.orange)

            Spacer()

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
            .disabled(model.isCleaning)

            Button {
                model.showCleanConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.settings.dryRun ? "eye.fill" : "trash.fill")
                    Text(appState.settings.dryRun ? "results.preview_selected" : "results.move_to_trash")
                        .font(.callout.weight(.semibold))
                }
                .padding(.horizontal, 10)
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .shadow(color: AuroraPalette.electricPurple.opacity(0.35), radius: 6, x: 0, y: 2)
            .disabled(model.selection.isEmpty || model.isCleaning)
            .help(appState.settings.dryRun
                  ? Text("results.preview_selected.help")
                  : Text("results.clean_help"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Cleanup Report Bar

    private var cleanupReportBar: some View {
        let report = model.report
        let previewOnly = report?.previewOnly ?? true
        let failed = report?.failedCount ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: previewOnly ? "eye.fill" : (failed > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"))
                    .foregroundStyle(previewOnly ? AuroraPalette.cyan : (failed > 0 ? AuroraPalette.amber : AuroraPalette.success))
                Text(report?.summary ?? "")
                    .font(.callout.weight(.semibold))
                Spacer()
                if let destinations = report?.trashDestinations, !destinations.isEmpty {
                    Button("results.reveal_in_trash") {
                        revealInTrash(destinations)
                    }
                    .buttonStyle(.link)
                    .help("results.reveal_in_trash.help")
                }
                Button {
                    model.report = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("common.clear")
            }

            if let report {
                Text(String(
                    format: NSLocalizedString("cleanup.report.counts", comment: ""),
                    report.selectedCount,
                    FileUtilities.formattedBytes(report.selectedBytes),
                    report.plannedCount,
                    report.moved.count,
                    FileUtilities.formattedBytes(report.movedBytes),
                    report.previewed.count,
                    FileUtilities.formattedBytes(report.previewedBytes),
                    report.skippedCount,
                    report.failedCount,
                    report.notProcessed,
                    FileUtilities.formattedBytes(report.remainingBytes)
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            ForEach(report?.reasons(limit: 3) ?? [], id: \.self) { reason in
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AuroraPalette.amber)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }

    private func revealInTrash(_ destinations: [String: String]) {
        let urls = destinations.values.sorted().prefix(50).map { URL(fileURLWithPath: $0) }
        NSWorkspace.shared.activateFileViewerSelecting(Array(urls))
    }

    private func performCleanup() {
        let previewOnly = appState.settings.dryRun
        model.report = nil
        model.cleanupMessage = nil

        let draft = model.buildDraft(previewOnly: previewOnly)
        guard draft.selectedCount > 0 else {
            model.cleanupMessage = NSLocalizedString("results.cleanup.empty", comment: "")
            return
        }

        let root = draft.plan.items.first?.containmentRoot ?? PathSafety.userHome.path
        let category = draft.plan.items.first?.category.rawValue ?? "unknown"
        let libraryRoots = ScanPolicy.quickLibraryRoots(home: PathSafety.userHome)
        let reviewRoots = ScanPolicy.defaultReviewRoots(home: PathSafety.userHome)
            + (model.outcome?.coverage.scannedRoots ?? [])
        appState.beginActivity(.cleaning(detail: NSLocalizedString(
            previewOnly ? "results.previewing" : "results.cleaning",
            comment: ""
        )))
        model.isCleaning = true

        Task {
            let result = await CleanupExecutor.shared.execute(
                plan: draft.plan,
                libraryRoots: libraryRoots,
                reviewRoots: reviewRoots,
                skipped: draft.rejections,
                selectedCount: draft.selectedCount,
                selectedBytes: draft.selectedBytes,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            model.isCleaning = false
            model.applyExecuted(result, appState: appState)

            if !draft.plan.items.isEmpty {
                appState.sessionStore.recordCleanup(CleanupHistoryRecord(
                    action: NSLocalizedString("history.action.results", comment: ""),
                    category: category,
                    itemCount: result.succeededCount,
                    bytes: result.previewOnly ? result.previewedBytes : result.movedBytes,
                    previewOnly: result.previewOnly,
                    movedCount: result.moved.count,
                    failedCount: result.failedCount,
                    skippedCount: result.skippedCount,
                    root: root
                ))
            }
            appState.endActivity(message: result.summary)
        }
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

            Image(systemName: item.safetyLevel == .safe ? "doc.fill" : "doc.text.fill")
                .foregroundStyle(item.safetyLevel == .safe ? AuroraPalette.cyan : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.reason)
                        .font(.caption2)
                        .foregroundStyle(AuroraPalette.amber)
                        .lineLimit(1)
                    Text("•")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(item.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .help(item.path)

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
        .background(Color.white.opacity(isSelected ? 0.06 : 0.02), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if selectable { onToggle() }
        }
        .contextMenu {
            Button("results.quicklook") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            Button("results.reveal") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
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
