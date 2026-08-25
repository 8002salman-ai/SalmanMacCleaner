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
    /// The exact outcome of the last preview/cleanup run, or nil. Drives the
    /// report bar: counts, bytes, failure reasons and "Reveal in Trash".
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

    /// Build the plan from the *exact current selection* with live identity
    /// capture. Selections that cannot be planned are reported, never
    /// dropped: `CleanupPlanDraft.reconciles` must hold for every run.
    public func buildDraft(previewOnly: Bool,
                           libraryRoots: [String] = [],
                           reviewRoots: [String] = []) -> CleanupPlanDraft {
        let recordsByPath = Dictionary(uniqueKeysWithValues: items.map { ($0.path, $0) })
        var records: [FileRecord] = []
        var selected: [ScannedItem] = []
        var unplanned: [(path: String, reason: String, bytes: Int64)] = []

        for path in selection.sorted() {
            guard let listed = recordsByPath[path] else {
                // Selection from a previous category/scan that is no longer
                // in the current result set.
                unplanned.append((
                    path,
                    NSLocalizedString("plan.skip.not_listed", comment: "") + " \(path)",
                    0
                ))
                continue
            }
            guard let record = MetadataCollector.collect(
                url: URL(fileURLWithPath: path, isDirectory: false)
            ) else {
                unplanned.append((
                    path,
                    NSLocalizedString("plan.skip.no_record", comment: "") + " \(path)",
                    listed.allocatedSize
                ))
                continue
            }
            records.append(record)
            selected.append(ScannedItem(path: record.path, size: record.allocatedSize))
        }

        let draft = CleanupPlanBuilder.buildDetailed(
            selection: selected,
            records: records,
            containmentRoot: containmentRoot(for: Array(selection)),
            previewOnly: previewOnly,
            scanID: outcome?.scanID,
            libraryRoots: libraryRoots,
            reviewRoots: reviewRoots
        )
        return CleanupPlanDraft(
            plan: draft.plan,
            rejections: draft.rejections + unplanned,
            selectedCount: draft.selectedCount + unplanned.count,
            selectedBytes: draft.selectedBytes + unplanned.reduce(Int64(0)) { $0 + $1.bytes }
        )
    }

    /// The containment root that actually contains the selection. Picking an
    /// arbitrary scanned root here is what made cleanup reject every item
    /// when a scan covered more than one root.
    public func containmentRoot(for paths: [String]) -> String {
        let home = PathSafety.userHome.path
        guard !paths.isEmpty else { return home }
        let roots = ((outcome?.coverage.scannedRoots ?? []) + [home])
            .filter { root in paths.allSatisfy { PathSafety.isPath($0, inside: root) } }
        // Narrowest root that still contains everything selected.
        return roots.max { $0.count < $1.count } ?? home
    }

    /// Remove the items that moved to the Trash from the results and update
    /// every total the header shows. Preview runs change nothing.
    public func applyExecuted(_ result: ExecutedCleanupResult) {
        report = result
        guard !result.previewOnly else { return }

        let moved = Set(result.moved)
        guard !moved.isEmpty else { return }

        let removed = items.filter { moved.contains($0.path) }
        let removedBytes = removed.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let removedSafeBytes = removed.filter { $0.safetyLevel == .safe }.reduce(Int64(0)) { $0 + $1.allocatedSize }
        let removedReviewBytes = removed.filter { $0.safetyLevel == .review }.reduce(Int64(0)) { $0 + $1.allocatedSize }

        items.removeAll { moved.contains($0.path) }
        selection.subtract(moved)

        if var updated = outcome {
            updated.itemsScanned = max(0, updated.itemsScanned - removed.count)
            updated.bytesIndexed = max(0, updated.bytesIndexed - removedBytes)
            updated.safeBytes = max(0, updated.safeBytes - removedSafeBytes)
            updated.reviewBytes = max(0, updated.reviewBytes - removedReviewBytes)
            outcome = updated
        }

        // Evict from the index too, so a reload cannot bring them back.
        if let scanID = outcome?.scanID {
            coordinator.indexStore.deleteRecords(scanID: scanID, paths: Array(moved))
        }
    }
}

public struct ResultsWorkspaceView: View {
    @StateObject private var model: ResultsWorkspaceModel
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accessibility: AccessibilityEnvironment
    private let initialOutcome: ScanOutcome

    /// The outcome as it stands now: totals fall as items move to the Trash.
    private var outcome: ScanOutcome { model.outcome ?? initialOutcome }

    public init(outcome: ScanOutcome, coordinator: DeepScanCoordinator = .shared) {
        self.initialOutcome = outcome
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
            if model.report != nil {
                cleanupReportBar
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
                previewOnly: appState.settings.dryRun
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
            tile("results.tile.bytes", value: FileUtilities.formattedBytes(outcome.bytesIndexed))
            tile("results.tile.elapsed", value: String(format: "%.1fs", outcome.finishedAt.timeIntervalSince(outcome.startedAt)))
            tile("results.tile.apps", value: "\(outcome.applicationCount)")
            tile("results.tile.duplicates", value: "\(outcome.duplicateGroupCount)")
        }
        .frame(width: 210)
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
            Text(LocalizedStringKey(appState.settings.dryRun ? "selection.preview_only" : "selection.will_trash"))
                .font(.caption)
                .foregroundStyle(appState.settings.dryRun ? Color.green : Color.orange)

            Spacer()

            // Deliberate Preview Mode control — cleanup is not permanently
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
            .disabled(model.isCleaning)

            // One honest action. Preview Mode on → "Preview Selected", which
            // confirms with "Confirm Preview" and moves nothing. Preview Mode
            // off → "Move Selected to Trash", which revalidates every item and
            // calls FileManager.trashItem.
            Button {
                model.showCleanConfirmation = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: appState.settings.dryRun ? "eye.fill" : "trash.fill")
                    Text(appState.settings.dryRun ? "results.preview_selected" : "results.move_to_trash")
                }
            }
            .buttonStyle(AuroraPrimaryButtonStyle())
            .disabled(model.selection.isEmpty || model.isCleaning)
            .help(appState.settings.dryRun
                  ? Text("results.preview_selected.help")
                  : Text("results.clean_help"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
        }
    }

    // MARK: - Cleanup report

    /// Exact, self-reconciling report of the last run: what was selected,
    /// planned, moved or previewed, skipped, failed, the bytes involved and
    /// the reasons — plus a way to see the moved items in the Trash.
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
                    report.plannedCount,
                    report.moved.count,
                    report.previewed.count,
                    report.skippedCount,
                    report.failedCount,
                    FileUtilities.formattedBytes(report.previewOnly ? report.previewedBytes : report.movedBytes)
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

    /// Run the confirmed action. Preview Mode decides the mode; the executor
    /// revalidates every item and only ever calls FileManager.trashItem.
    private func performCleanup() {
        let previewOnly = appState.settings.dryRun
        // A new run always clears the previous report first: a stale banner
        // describing an earlier run must never sit next to new counts.
        model.report = nil
        model.cleanupMessage = nil

        let draft = model.buildDraft(previewOnly: previewOnly)
        guard draft.selectedCount > 0 else {
            model.cleanupMessage = NSLocalizedString("results.cleanup.empty", comment: "")
            return
        }

        let root = draft.plan.items.first?.containmentRoot ?? PathSafety.userHome.path
        let category = draft.plan.items.first?.category.rawValue ?? "unknown"
        appState.beginActivity(.cleaning(detail: NSLocalizedString(
            previewOnly ? "results.previewing" : "results.cleaning",
            comment: ""
        )))
        model.isCleaning = true

        Task {
            let result = await CleanupExecutor.shared.execute(
                plan: draft.plan,
                skipped: draft.rejections,
                selectedCount: draft.selectedCount,
                progress: { fraction, detail in
                    Task { @MainActor in appState.updateProgress(fraction, detail: detail) }
                },
                isCancelled: { Task.isCancelled }
            )
            model.isCleaning = false
            // Removes moved items from the results and updates the totals.
            model.applyExecuted(result)

            // Exact history: only what was really processed, moved, refused.
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
            // Always finish the activity — including on cancellation — so the
            // toolbar never keeps showing a run that is no longer happening.
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
