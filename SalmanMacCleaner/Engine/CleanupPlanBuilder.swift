//
//  CleanupPlanBuilder.swift
//  SalmanMacCleaner
//
//  Builds the immutable cleanup plan from the user's explicit selection.
//  Every planned item captures expected identity so the executor can detect
//  files that changed after the scan.
//

import Foundation

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
        allowBundles: Bool = false
    ) -> CleanupPlan {
        let selectedPaths = Set(selection.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        let recordByPath = Dictionary(uniqueKeysWithValues: records.map { ($0.path, $0) })

        var items: [PlannedCleanupItem] = []
        for item in selection {
            let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.path
            guard selectedPaths.contains(canonical) else { continue }
            let record = recordByPath[canonical]

            // Only SAFE and REVIEW items may enter a plan; PROTECTED items
            // are rejected by the validator, never planned. Application
            // bundles are admitted only for the explicit uninstaller flow.
            let verdict: JunkVerdict
            if allowBundles && PathSafety.isAppBundle(canonical) {
                verdict = JunkVerdict(
                    category: .unknown,
                    safety: .review,
                    reason: NSLocalizedString("classify.reason.uninstall_bundle", comment: ""),
                    autoSelectable: false,
                    regenerable: false,
                    sourceRule: "uninstaller-bundle"
                )
            } else {
                verdict = record.map {
                    JunkClassifier.classify($0, libraryRoots: libraryRoots, reviewRoots: reviewRoots)
                } ?? JunkVerdict(
                    category: .unknown,
                    safety: .review,
                    reason: NSLocalizedString("classify.reason.no_record", comment: ""),
                    autoSelectable: false,
                    regenerable: false,
                    sourceRule: "selection"
                )
            }
            guard verdict.safety != .protected else { continue }

            items.append(PlannedCleanupItem(
                path: canonical,
                expectedSize: record?.allocatedSize ?? item.size,
                expectedModified: record?.modified,
                expectedOwner: record?.ownerUID ?? 0,
                expectedDevice: record?.device ?? 0,
                expectedInode: record?.inode ?? 0,
                category: verdict.category,
                safety: verdict.safety,
                containmentRoot: containmentRoot,
                action: .moveToTrash
            ))
        }
        return CleanupPlan(items: items, previewOnly: previewOnly, scanID: scanID)
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
