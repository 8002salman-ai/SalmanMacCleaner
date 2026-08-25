//
//  CleanupExecutor.swift
//  SalmanMacCleaner
//
//  Executes an immutable cleanup plan. Trash-only: items move to the Trash
//  via FileManager.trashItem after the CleanupSafetyValidator rechecks every
//  guard. No permanent deletion, no Trash emptying, no privileged actions.
//
//  Accounting is exact by construction. Every item the user selected ends up
//  in exactly one bucket:
//
//      selected == skipped + moved + previewed + failed + notProcessed
//
//  `skipped` are selections that never entered the plan (reported by
//  CleanupPlanBuilder), `failed` are planned items the validator or the
//  Trash refused (with the exact reason), and `notProcessed` are planned
//  items the run never reached because the user cancelled.
//

import Foundation

// MARK: - Trash mover

/// Moves exactly one item to the macOS Trash and reports where it landed.
///
/// The production implementation is `SystemTrashMover`, which calls
/// `FileManager.trashItem(at:resultingItemURL:)` — the only removal API the
/// app is allowed to use. Tests inject a mock so the Preview-OFF code path
/// can be exercised without touching the user's real Trash.
public protocol TrashMover {
    /// Move `path` to the Trash. Returns the resulting Trash path.
    /// Throws when the system refused the move; the caller records the
    /// reason and continues with the next item.
    func moveToTrash(_ path: String) throws -> String
}

/// Production mover: `FileManager.trashItem`. Never deletes permanently and
/// never empties the Trash — the file stays restorable.
public struct SystemTrashMover: TrashMover {

    public init() {}

    public func moveToTrash(_ path: String) throws -> String {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: path),
            resultingItemURL: &resultingURL
        )
        guard let destination = (resultingURL as URL?),
              FileManager.default.fileExists(atPath: destination.path) else {
            throw CleanupMoveError.destinationNotVerified(path)
        }
        return destination.path
    }
}

public enum CleanupMoveError: LocalizedError, Equatable {
    case destinationNotVerified(String)

    public var errorDescription: String? {
        switch self {
        case .destinationNotVerified(let path):
            return NSLocalizedString("cleanup.error.destination_not_verified", comment: "") + " \(path)"
        }
    }
}

// MARK: - Result

public struct ExecutedCleanupResult {

    /// Planned items successfully moved to the Trash.
    public var moved: [String]
    /// Planned items inspected during a preview run (nothing was touched).
    public var previewed: [String]
    /// Planned items refused, with the exact reason.
    public var failures: [(path: String, reason: String)]
    /// Selections that never entered the plan, with the exact reason and the
    /// bytes they represented.
    public var skipped: [(path: String, reason: String, bytes: Int64)]
    /// Bytes accounted for the items that moved or were previewed.
    public var bytesReclaimed: Int64
    /// Bytes of the items that actually moved to the Trash.
    public var movedBytes: Int64
    /// Bytes of the items a preview run inspected.
    public var previewedBytes: Int64
    /// Bytes attached to skipped selections.
    public var skippedBytes: Int64
    /// Bytes associated with items the mover or validator refused.
    public var failedBytes: Int64
    /// Bytes that still exist after reconciliation (failed or untouched).
    public var remainingBytes: Int64
    /// Unique selected bytes captured when the run started.
    public var selectedBytes: Int64
    public var previewOnly: Bool
    /// True when the user cancelled mid-run.
    public var cancelled: Bool
    /// Planned items the run never reached (cancellation only).
    public var notProcessed: Int
    /// Source path → destination inside the Trash (for "Reveal in Trash").
    public var trashDestinations: [String: String]
    /// Number of items the UI had selected when the run started.
    public var selectedCount: Int

    public init(moved: [String] = [],
                previewed: [String] = [],
                failures: [(path: String, reason: String)] = [],
                skipped: [(path: String, reason: String, bytes: Int64)] = [],
                bytesReclaimed: Int64 = 0,
                movedBytes: Int64 = 0,
                previewedBytes: Int64 = 0,
                skippedBytes: Int64 = 0,
                failedBytes: Int64 = 0,
                remainingBytes: Int64 = 0,
                selectedBytes: Int64 = 0,
                previewOnly: Bool,
                cancelled: Bool = false,
                notProcessed: Int = 0,
                trashDestinations: [String: String] = [:],
                selectedCount: Int = 0) {
        self.moved = moved
        self.previewed = previewed
        self.failures = failures
        self.skipped = skipped
        self.bytesReclaimed = bytesReclaimed
        self.movedBytes = movedBytes
        self.previewedBytes = previewedBytes
        self.skippedBytes = skippedBytes
        self.failedBytes = failedBytes
        self.remainingBytes = remainingBytes
        self.selectedBytes = selectedBytes
        self.previewOnly = previewOnly
        self.cancelled = cancelled
        self.notProcessed = notProcessed
        self.trashDestinations = trashDestinations
        self.selectedCount = selectedCount
    }

    public var succeededCount: Int { moved.count + previewed.count }
    public var failedCount: Int { failures.count }
    public var skippedCount: Int { skipped.count }
    public var plannedCount: Int { moved.count + previewed.count + failures.count + notProcessed }

    /// Whether the reported buckets add up to the selection exactly. A UI
    /// that shows counts derived from anywhere else can drift; this check
    /// is asserted by the regression tests.
    public var reconciles: Bool {
        selectedCount == skippedCount + succeededCount + failedCount + notProcessed
    }

    /// Every failure/skip reason, de-duplicated and ordered, capped.
    public func reasons(limit: Int = 5) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let allReasons = failures.map { $0.reason } + skipped.map { $0.reason }
        for reason in allReasons {
            guard !seen.contains(reason) else { continue }
            seen.insert(reason)
            out.append(reason)
            if out.count >= limit { break }
        }
        return out
    }

    /// One-line, exact summary for the completion banner.
    public var summary: String {
        if previewOnly {
            var text = String(
                format: NSLocalizedString("cleanup.report.previewed", comment: ""),
                previewed.count,
                FileUtilities.formattedBytes(previewedBytes)
            )
            if failedCount > 0 {
                text += " " + String(
                    format: NSLocalizedString("cleanup.report.failed", comment: ""),
                    failedCount
                )
            }
            if skippedCount > 0 {
                text += " " + String(
                    format: NSLocalizedString("cleanup.report.skipped", comment: ""),
                    skippedCount
                )
            }
            if cancelled {
                text += " " + NSLocalizedString("cleanup.report.cancelled", comment: "")
            }
            return text
        }
        var text = String(
            format: NSLocalizedString("cleanup.report.moved", comment: ""),
            moved.count,
            FileUtilities.formattedBytes(movedBytes)
        )
        if failedCount > 0 {
            text += " " + String(
                format: NSLocalizedString("cleanup.report.failed", comment: ""),
                failedCount
            )
        }
        if skippedCount > 0 {
            text += " " + String(
                format: NSLocalizedString("cleanup.report.skipped", comment: ""),
                skippedCount
            )
        }
        if cancelled {
            text += " " + NSLocalizedString("cleanup.report.cancelled", comment: "")
        }
        return text
    }
}

public enum CleanupExecutorError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

@MainActor
public final class CleanupExecutor: ObservableObject {

    @Published public private(set) var isRunning = false
    @Published public private(set) var currentItem: String?

    public static let shared = CleanupExecutor()

    private let trashMover: TrashMover
    private var cancellationRequested = false

    public init(trashMover: TrashMover = SystemTrashMover()) {
        self.trashMover = trashMover
    }

    /// Request cancellation between cleanup items. The current Trash API call
    /// is allowed to finish; no later item is touched.
    public func cancel() {
        cancellationRequested = true
    }

    /// Execute a plan. `previewOnly` plans touch nothing; otherwise each item
    /// is revalidated immediately before `trashItem`.
    ///
    /// - Parameters:
    ///   - skipped: selections that never entered the plan, with reasons.
    ///     Passed through so the reported totals always reconcile with the
    ///     number of items the user had selected.
    ///   - selectedCount: the UI's selection size when the run started.
    ///   - authorizedRoots: roots the user explicitly authorized (the
    ///     uninstaller's bundle grant). Forwarded to the validator.
    public func execute(
        plan: CleanupPlan,
        allowBundles: Bool = false,
        libraryRoots: [String] = [],
        reviewRoots: [String] = [],
        authorizedRoots: [String] = [],
        skipped: [(path: String, reason: String, bytes: Int64)] = [],
        selectedCount: Int? = nil,
        selectedBytes: Int64? = nil,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) async -> ExecutedCleanupResult {
        cancellationRequested = false
        isRunning = true
        defer {
            isRunning = false
            currentItem = nil
        }

        var result = ExecutedCleanupResult(previewOnly: plan.previewOnly)
        result.skipped = skipped
        let skippedItems = skipped.map {
            CleanupItem(path: $0.path, size: $0.bytes, kind: "skipped")
        }
        result.skippedBytes = CleanupAccounting.uniqueBytes(for: skippedItems)
        result.selectedCount = selectedCount ?? (plan.items.count + skipped.count)
        let plannedItems = plan.items.map {
            CleanupItem(
                path: $0.path,
                size: $0.expectedSize,
                kind: $0.category.rawValue,
                device: $0.expectedDevice,
                inode: $0.expectedInode
            )
        }
        let selectedItems = plannedItems + skippedItems
        result.selectedBytes = selectedBytes.map { max($0, 0) } ?? CleanupAccounting.uniqueBytes(for: selectedItems)
        result.notProcessed = plan.items.count

        let total = max(plan.items.count, 1)
        var measuredSizes: [String: Int64] = [:]
        func reconcile() async {
            let moved = result.moved
            let failed = result.failures
            let sizes = measuredSizes
            let breakdown = await Task.detached(priority: .utility) {
                CleanupAccounting.reconcile(
                    selected: selectedItems,
                    moved: moved,
                    failed: failed,
                    sizeOverrides: sizes
                )
            }.value
            result.selectedBytes = selectedBytes.map { max($0, 0) } ?? breakdown.selectedBytes
            result.movedBytes = breakdown.movedBytes
            result.failedBytes = breakdown.failedBytes
            result.remainingBytes = breakdown.remainingBytes
            if plan.previewOnly {
                let previewedPaths = Set(result.previewed.map(CleanupAccounting.standardizedPath))
                let previewItems = selectedItems.compactMap { item -> CleanupItem? in
                    let path = CleanupAccounting.standardizedPath(item.path)
                    guard previewedPaths.contains(path) else { return nil }
                    return CleanupItem(
                        path: path,
                        size: sizes[path] ?? item.size,
                        kind: item.kind,
                        device: item.device,
                        inode: item.inode
                    )
                }
                result.previewedBytes = CleanupAccounting.uniqueBytes(for: previewItems)
            }
            result.bytesReclaimed = plan.previewOnly ? result.previewedBytes : result.movedBytes
        }

        for (index, item) in plan.items.enumerated() {
            if isCancelled() || cancellationRequested {
                result.cancelled = true
                result.notProcessed = plan.items.count - index
                await reconcile()
                progress(1, nil)
                return result
            }
            result.notProcessed = plan.items.count - index
            progress(Double(index) / Double(total), item.path)

            let validation = await Task.detached(priority: .utility) {
                CleanupSafetyValidator.validate(
                    item: item,
                    allowBundles: allowBundles,
                    libraryRoots: libraryRoots,
                    reviewRoots: reviewRoots,
                    authorizedRoots: authorizedRoots
                )
            }.value
            switch validation {
            case .failure(let failure):
                result.failures.append((item.path, failure.localizedDescription))
                result.failedBytes = CleanupAccounting.adding(result.failedBytes, max(item.expectedSize, 0))
            case .success(let validated):
                currentItem = validated.path
                // Capture the freshest size immediately before the action. A
                // scan's estimate is only a fallback if metadata disappeared.
                let currentBytes = await Task.detached(priority: .utility) {
                    CleanupAccounting.currentAllocatedBytes(at: validated.path, fallback: validated.expectedSize)
                }.value
                measuredSizes[validated.path] = currentBytes
                if plan.previewOnly {
                    // Preview never reaches the mover: this branch performs
                    // no filesystem mutation at all.
                    result.previewed.append(validated.path)
                    result.previewedBytes = CleanupAccounting.adding(result.previewedBytes, currentBytes)
                    result.bytesReclaimed = CleanupAccounting.adding(result.bytesReclaimed, currentBytes)
                } else {
                    do {
                        let mover = trashMover
                        let destination = try await Task.detached(priority: .userInitiated) {
                            try mover.moveToTrash(validated.path)
                        }.value
                        result.moved.append(validated.path)
                        result.movedBytes = CleanupAccounting.adding(result.movedBytes, currentBytes)
                        result.bytesReclaimed = CleanupAccounting.adding(result.bytesReclaimed, currentBytes)
                        if !destination.isEmpty {
                            result.trashDestinations[validated.path] = destination
                        }
                    } catch {
                        result.failures.append((validated.path, error.localizedDescription))
                        result.failedBytes = CleanupAccounting.adding(result.failedBytes, currentBytes)
                    }
                }
            }
            // Let the main actor process a cancellation request between items.
            await Task.yield()
        }
        result.notProcessed = 0
        await reconcile()
        progress(1, nil)
        return result
    }
}
