//
//  CleanupPlanBuilder.swift
//  SalmanMacCleaner
//
//  Builds the immutable cleanup plan from the user's explicit selection.
//  Every planned item captures expected identity so the executor can detect
//  files that changed after the scan.
//
//  Selections that cannot be planned are never dropped silently: they are
//  returned as rejections with the exact reason and their byte size, so the
//  UI can report "N selected → M planned, K skipped (why)" instead of a
//  count that no longer matches the selection bar.
//

import Foundation

/// A plan plus the exact accounting of the selection it came from.
public struct CleanupPlanDraft: Equatable {
    public var plan: CleanupPlan
    /// Selections that never entered the plan, with the exact reason.
    public var rejections: [(path: String, reason: String, bytes: Int64)]
    /// Number of unique selections the draft was built from.
    public var selectedCount: Int
    /// Bytes represented by those selections.
    public var selectedBytes: Int64

    public init(plan: CleanupPlan,
                rejections: [(path: String, reason: String, bytes: Int64)] = [],
                selectedCount: Int = 0,
                selectedBytes: Int64 = 0) {
        self.plan = plan
        self.rejections = rejections
        self.selectedCount = selectedCount
        self.selectedBytes = selectedBytes
    }

    /// planned + rejected always equals the selection.
    public var reconciles: Bool {
        selectedCount == plan.items.count + rejections.count
    }
}

public enum CleanupPlanBuilder {

    /// Build a plan from explicitly selected scan results.
    public static func build(
        selection: [ScannedItem],
        records: [FileRecord],
        containmentRoot: String,
        previewOnly: Bool,
        scanID: Int64? = nil,
        libraryRoots: [String] = [],
        reviewRoots: [String] = [],
        allowBundles: Bool = false,
        authorizedRoots: [String] = []
    ) -> CleanupPlan {
        buildDetailed(
            selection: selection,
            records: records,
            containmentRoot: containmentRoot,
            previewOnly: previewOnly,
            scanID: scanID,
            libraryRoots: libraryRoots,
            reviewRoots: reviewRoots,
            allowBundles: allowBundles,
            authorizedRoots: authorizedRoots
        ).plan
    }

    /// Build a plan *and* the exact reason every unplanned selection was
    /// left out. The plan itself is identical to `build(...)`'s.
    public static func buildDetailed(
        selection: [ScannedItem],
        records: [FileRecord],
        containmentRoot: String,
        previewOnly: Bool,
        scanID: Int64? = nil,
        libraryRoots: [String] = [],
        reviewRoots: [String] = [],
        allowBundles: Bool = false,
        authorizedRoots: [String] = []
    ) -> CleanupPlanDraft {
        let recordByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })

        var items: [PlannedCleanupItem] = []
        var rejections: [(path: String, reason: String, bytes: Int64)] = []
        var seen = Set<String>()
        var selectedCount = 0
        var selectedBytes: Int64 = 0

        for item in selection {
            let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.path
            // A selection is a set of paths; repeats are the same item.
            guard !seen.contains(canonical) else { continue }
            seen.insert(canonical)
            selectedCount += 1
            selectedBytes += item.size

            // Only SAFE and REVIEW items may enter a plan; PROTECTED items
            // are rejected by the validator, never planned. Application
            // bundles are admitted only for the explicit uninstaller flow.
            guard let record = recordByPath[canonical] ?? recordByPath[item.path] else {
                rejections.append((
                    canonical,
                    NSLocalizedString("plan.skip.no_record", comment: "") + " \(canonical)",
                    item.size
                ))
                continue
            }

            let isBundle = PathSafety.isAppBundle(canonical)
            let verdict: JunkVerdict
            if allowBundles && isBundle {
                verdict = JunkVerdict(
                    category: .unknown,
                    safety: .review,
                    reason: NSLocalizedString("classify.reason.uninstall_bundle", comment: ""),
                    autoSelectable: false,
                    regenerable: false,
                    sourceRule: "uninstaller-bundle"
                )
            } else {
                verdict = JunkClassifier.classify(
                    record,
                    libraryRoots: libraryRoots,
                    reviewRoots: reviewRoots
                )
            }

            guard verdict.safety != .protected else {
                rejections.append((
                    canonical,
                    NSLocalizedString("plan.skip.protected", comment: "") + " \(canonical)",
                    record.allocatedSize
                ))
                continue
            }

            guard !record.isSymlink else {
                rejections.append((
                    canonical,
                    NSLocalizedString("cleanup.error.symlink", comment: "") + " \(canonical)",
                    record.allocatedSize
                ))
                continue
            }

            // An explicitly authorized root is the narrowest containment
            // boundary for that item (the uninstaller grants exactly the
            // bundle the user picked); everything else stays inside the
            // scan's containment root.
            let itemRoot = authorizedRoots.first { PathSafety.isPath(canonical, inside: $0) } ?? containmentRoot

            items.append(PlannedCleanupItem(
                path: canonical,
                expectedSize: record.allocatedSize,
                expectedModified: record.modified,
                expectedOwner: record.ownerUID,
                expectedDevice: record.device,
                expectedInode: record.inode,
                category: verdict.category,
                safety: verdict.safety,
                containmentRoot: itemRoot,
                action: .moveToTrash
            ))
        }
        return CleanupPlanDraft(
            plan: CleanupPlan(items: items, previewOnly: previewOnly, scanID: scanID),
            rejections: rejections,
            selectedCount: selectedCount,
            selectedBytes: selectedBytes
        )
    }

    /// Build a plan for duplicate cleanup (selected files across groups).
    public static func buildDuplicatePlan(
        selection: [ScannedItem],
        records: [FileRecord],
        containmentRoot: String,
        previewOnly: Bool,
        scanID: Int64? = nil
    ) -> CleanupPlan {
        build(
            selection: selection,
            records: records,
            containmentRoot: containmentRoot,
            previewOnly: previewOnly,
            scanID: scanID
        )
    }
}
