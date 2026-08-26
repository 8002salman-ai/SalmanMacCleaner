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
//  Double-counting prevention:
//  - Canonicalizes and deduplicates selection paths.
//  - Prunes descendants: if a parent directory is selected, descendants are
//    removed from the executable plan and reported as explicit skips.
//  - Deduplicates identical file identities (device + inode).
//

import Foundation

/// A plan plus the exact accounting of the selection it came from.
public struct CleanupPlanDraft {
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

    /// Prune descendant paths so that if a parent folder is selected, its descendants
    /// are not planned or double-counted separately.
    public static func pruneDescendantPaths(_ paths: [String]) -> Set<String> {
        let canonicals = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        var nonDescendants = Set<String>()
        let sorted = canonicals.sorted { $0.count < $1.count }
        for path in sorted {
            let isDescendant = nonDescendants.contains { parent in
                path != parent && PathSafety.isPath(path, inside: parent)
            }
            if !isDescendant {
                nonDescendants.insert(path)
            }
        }
        return nonDescendants
    }

    /// Calculate unique, non-overlapping allocated bytes for a set of classified records.
    public static func uniqueBytes(for records: [ClassifiedRecord]) -> Int64 {
        CleanupAccounting.uniqueBytes(for: records.map {
            FileRecord(
                path: $0.path,
                parent: URL(fileURLWithPath: $0.path).deletingLastPathComponent().path,
                name: $0.name,
                isDirectory: $0.isDirectory,
                logicalSize: $0.logicalSize,
                allocatedSize: $0.allocatedSize,
                modified: $0.modified,
                device: $0.device,
                inode: $0.inode,
                ownerUID: $0.ownerUID,
                isSymlink: $0.isSymlink
            )
        })
    }

    /// Calculate unique, non-overlapping bytes for a set of scanned items.
    public static func uniqueBytes(for items: [ScannedItem]) -> Int64 {
        CleanupAccounting.uniqueBytes(for: items)
    }

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
        authorizedRoots: [String] = [],
        preclassified: [String: JunkVerdict] = [:]
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
            authorizedRoots: authorizedRoots,
            preclassified: preclassified
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
        authorizedRoots: [String] = [],
        preclassified: [String: JunkVerdict] = [:]
    ) -> CleanupPlanDraft {
        var recordByPath: [String: FileRecord] = [:]
        for record in records {
            let key = URL(fileURLWithPath: record.path).standardizedFileURL.path
            // Keep the first observation. Duplicate database rows must never
            // crash plan construction with Dictionary(uniqueKeysWithValues:).
            if recordByPath[key] == nil {
                recordByPath[key] = record
            }
        }

        // 1. Canonicalize selection and deduplicate identical paths
        var canonicalSelection: [ScannedItem] = []
        var seenPaths = Set<String>()
        for item in selection {
            let canonical = URL(fileURLWithPath: item.path).standardizedFileURL.path
            guard !seenPaths.contains(canonical) else { continue }
            seenPaths.insert(canonical)
            canonicalSelection.append(ScannedItem(
                id: item.id,
                path: canonical,
                size: item.size,
                isDirectory: item.isDirectory,
                modificationDate: item.modificationDate,
                detail: item.detail,
                device: item.device,
                inode: item.inode
            ))
        }

        // 2. Prune descendants if parent directory is selected. A descendant
        // is part of the parent's one physical cleanup selection, not a
        // second executable item; it is reported as an explicit coverage skip.
        let nonDescendantPaths = pruneDescendantPaths(canonicalSelection.map { $0.path })
        let prunedSelection = canonicalSelection.filter { nonDescendantPaths.contains($0.path) }

        var items: [PlannedCleanupItem] = []
        var rejections: [(path: String, reason: String, bytes: Int64)] = []
        // A selected child is not silently dropped when its parent is also
        // selected. It is an explicit skipped bucket, so selected-count
        // reconciliation remains faithful to the user's actual selection.
        for item in canonicalSelection where !nonDescendantPaths.contains(item.path) {
            rejections.append((
                item.path,
                NSLocalizedString("plan.skip.parent_selected", comment: "") + " \(item.path)",
                0
            ))
        }
        var seenInodes = Set<String>()
        let selectedCount = canonicalSelection.count
        var selectedBytes: Int64 = 0

        for item in prunedSelection {
            let canonical = item.path

            // Only SAFE and REVIEW items may enter a plan; PROTECTED items
            // are rejected by the validator, never planned. Application
            // bundles are admitted only for the explicit uninstaller flow.
            guard let record = recordByPath[canonical] else {
                selectedBytes = CleanupAccounting.adding(selectedBytes, max(item.size, 0))
                rejections.append((
                    canonical,
                    NSLocalizedString("plan.skip.no_record", comment: "") + " \(canonical)",
                    item.size
                ))
                continue
            }

            // Deduplicate identical file identities (hard links)
            if record.device != 0, record.inode != 0 {
                let identityKey = "\(record.device)-\(record.inode)"
                if seenInodes.contains(identityKey) {
                    rejections.append((
                        canonical,
                        NSLocalizedString("plan.skip.duplicate_identity", comment: "") + " \(canonical)",
                        record.allocatedSize
                    ))
                    continue
                }
                seenInodes.insert(identityKey)
            }

            // Count physical bytes once. A second hard link remains a
            // rejected selection, but contributes zero reclaimable bytes.
            selectedBytes = CleanupAccounting.adding(selectedBytes, max(record.allocatedSize, 0))

            let isBundle = PathSafety.isAppBundle(canonical)
            var verdict: JunkVerdict
            if allowBundles && isBundle {
                verdict = JunkVerdict(
                    category: .unknown,
                    safety: .review,
                    reason: NSLocalizedString("classify.reason.uninstall_bundle", comment: ""),
                    autoSelectable: false,
                    regenerable: false,
                    sourceRule: "uninstaller-bundle"
                )
            } else if let preclassifiedVerdict = preclassified[canonical] {
                // The results workspace already displays an index verdict
                // produced by the real scan. Reuse that exact verdict during
                // plan construction so a custom authorized root cannot be
                // silently reclassified by a different default-root table.
                verdict = preclassifiedVerdict
            } else {
                verdict = JunkClassifier.classify(
                    record,
                    libraryRoots: libraryRoots,
                    reviewRoots: reviewRoots
                )
            }

            // Older callers and importers can construct a plan without the
            // scan's root table. Preserve a conservative manual path for a
            // clearly cache-shaped selection: it is REVIEW-only (never
            // auto-selected) and hard protections above still win.
            if libraryRoots.isEmpty,
               verdict.sourceRule == "default",
               isCacheLikePath(canonical) {
                verdict = JunkVerdict(
                    category: .userCache,
                    safety: .review,
                    reason: NSLocalizedString("classify.reason.user_folder", comment: ""),
                    autoSelectable: false,
                    regenerable: true,
                    sourceRule: "review-inferred-cache"
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

            // Moving a directory moves every descendant with it. Do not make
            // a folder-level plan when the scan already knows it contains a
            // protected item, even if the folder itself is a review candidate.
            if record.isDirectory {
                let containsProtectedDescendant = recordByPath.values.contains { descendant in
                    guard descendant.path != canonical,
                          PathSafety.isPath(descendant.path, inside: canonical) else {
                        return false
                    }
                    let descendantVerdict = preclassified[descendant.path] ?? JunkClassifier.classify(
                        descendant,
                        libraryRoots: libraryRoots,
                        reviewRoots: reviewRoots
                    )
                    return descendantVerdict.safety == .protected
                }
                guard !containsProtectedDescendant else {
                    rejections.append((
                        canonical,
                        NSLocalizedString("plan.skip.protected", comment: "") + " " + canonical,
                        record.allocatedSize
                    ))
                    continue
                }
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

    private static func isCacheLikePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents.dropLast()
        return components.contains { $0.caseInsensitiveCompare("Caches") == .orderedSame }
    }
}
