//
//  FileInventoryScanner.swift
//  SalmanMacCleaner
//
//  Depth-bounded directory enumeration with prefetched resource keys.
//  Streams records to the ScanIndexStore in batches; never holds the whole
//  tree in memory. Cooperative cancellation, pause/resume via ScanGate,
//  graceful handling of files that disappear mid-scan.
//
//  Correctness guarantees (regressions fixed here):
//  - The DirectoryEnumerator yields the scan root itself first; the root
//    item is never recorded as a file and never pruned the whole scan via
//    skipDescendants().
//  - isDirectory comes from lstat ground truth, not a nil-defaulting
//    URLResourceValues lookup.
//  - Each root returns an honest outcome (scanned / partial / denied with a
//    reason); the caller builds coverage from these, never optimistically.
//

import Foundation

public struct InventoryCounts: Codable, Equatable {
    public var files: Int = 0
    public var folders: Int = 0
    public var bytesIndexed: Int64 = 0
    public var denied: Int = 0
    public var errors: Int = 0
    public var symlinksRejected: Int = 0
    public var changedDuringScan: Int = 0
    /// Number of bounded/depth-limited portions not fully traversed.
    public var truncated: Int = 0

    public init() {}

    public mutating func merge(_ other: InventoryCounts) {
        files += other.files
        folders += other.folders
        bytesIndexed = CleanupAccounting.adding(bytesIndexed, other.bytesIndexed)
        denied += other.denied
        errors += other.errors
        symlinksRejected += other.symlinksRejected
        changedDuringScan += other.changedDuringScan
        truncated += other.truncated
    }
}

public enum InventoryScannerError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

/// The honest per-root result of one root traversal.
public struct RootScanResult: Equatable {
    public var root: String
    public var outcome: RootOutcome
    public var counts: InventoryCounts

    public init(root: String, outcome: RootOutcome, counts: InventoryCounts) {
        self.root = root
        self.outcome = outcome
        self.counts = counts
    }
}

/// Scans a set of roots, streaming `FileRecord`s to a sink.
public struct FileInventoryScanner {

    public typealias RecordSink = (FileRecord) -> Void
    public typealias RootedRecordSink = (FileRecord, ScanRoot) -> Void
    public typealias CountSink = (InventoryCounts, String?) -> Void

    /// - Parameters:
    ///   - roots: Granted scan roots (not-granted roots must be excluded by
    ///     the caller and reported separately in the coverage report).
    ///   - includeHidden: Whether dot-files are recorded.
    ///   - includePackageContents: Whether package internals are traversed.
    ///   - minFileSize: Files below this size are still traversed but not recorded.
    ///   - sink: Batched record consumer (e.g. the index store).
    ///   - counts: Periodic counter callback.
    ///   - gate: Pause/resume control.
    ///   - isCancelled: Polled frequently.
    public static func scan(
        roots: [ScanRoot],
        includeHidden: Bool,
        includePackageContents: Bool,
        minFileSize: Int64,
        sink: @escaping RootedRecordSink,
        counts: @escaping CountSink,
        gate: ScanGate,
        isCancelled: @escaping () -> Bool
    ) async throws -> [RootScanResult] {
        var totals = InventoryCounts()
        var results: [RootScanResult] = []
        let batchSize = 250

        for root in roots {
            if isCancelled() { throw InventoryScannerError.cancelled }
            await gate.waitIfPaused()
            let rootPath = root.url.standardizedFileURL.path

            // Not-granted roots are never scanned here; they are reported
            // by the coordinator's coverage layer.
            guard root.granted else {
                results.append(RootScanResult(
                    root: rootPath,
                    outcome: .skippedNotGranted(root.notGrantedReason ?? NSLocalizedString("coverage.root.not_granted", comment: "")),
                    counts: InventoryCounts()
                ))
                continue
            }

            // Honest probe before claiming anything.
            let probe = TraversalPolicy.probeRoot(root)
            guard probe.readable else {
                results.append(RootScanResult(
                    root: rootPath,
                    outcome: .denied(probe.reason ?? NSLocalizedString("coverage.root.unreadable", comment: "")),
                    counts: InventoryCounts()
                ))
                continue
            }

            let enumerationErrors = TraversalIssueCounter()
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: rootPath, isDirectory: true),
                includingPropertiesForKeys: MetadataCollector.prefetchedKeys,
                options: [],
                errorHandler: { _, _ in
                    // Permission errors are counted; the scan continues.
                    enumerationErrors.record()
                    return true
                }
            ) else {
                results.append(RootScanResult(
                    root: rootPath,
                    outcome: .denied(NSLocalizedString("coverage.root.unreadable", comment: "")),
                    counts: InventoryCounts()
                ))
                continue
            }

            var rootCounts = InventoryCounts()
            var rootTotals = InventoryCounts()
            var pendingRecords: [FileRecord] = []
            var entriesVisited = 0

            for case let url as URL in enumerator {
                entriesVisited += 1
                guard entriesVisited <= 250_000 else {
                    rootCounts.truncated += 1
                    break
                }
                if isCancelled() { throw InventoryScannerError.cancelled }
                if await gate.isPaused() {
                    await gate.waitIfPaused()
                }
                if enumerator.level > TraversalPolicy.maximumTraversalDepth {
                    rootCounts.truncated += 1
                    enumerator.skipDescendants()
                    continue
                }

                let path = url.standardizedFileURL.path

                // The enumerator yields the scan root itself first. The root
                // is never a candidate file and must never prune the scan.
                if path == rootPath {
                    continue
                }

                guard let values = try? url.resourceValues(forKeys: Set(MetadataCollector.prefetchedKeys)) else {
                    rootCounts.changedDuringScan += 1
                    continue
                }

                let isSymlink = values.isSymbolicLink ?? false
                // lstat ground truth; never treat "unknown" as a file.
                let kind = PathSafety.kind(of: path)
                let isDirectory = kind == .directory

                if isSymlink {
                    rootCounts.symlinksRejected += 1
                    enumerator.skipDescendants()
                    continue
                }

                if isDirectory {
                    rootCounts.folders += 1
                    let decision = TraversalPolicy.shouldEnterDirectory(
                        url: url,
                        root: root,
                        includeHidden: includeHidden,
                        includePackageContents: includePackageContents,
                        scope: ScanScope(mode: .deep)
                    )
                    switch decision {
                    case .include:
                        continue
                    case .skip(let reason):
                        if reason == .suspiciousLink { rootCounts.symlinksRejected += 1 }
                        if reason == .denied || reason == .otherUserFile || reason == .protectedLocation {
                            rootCounts.denied += 1
                        }
                        enumerator.skipDescendants()
                        continue
                    }
                }

                guard let record = MetadataCollector.collect(url: url, values: values) else {
                    rootCounts.changedDuringScan += 1
                    continue
                }
                guard record.isDirectory == false else { continue }

                let decision = TraversalPolicy.shouldRecordFile(
                    url: url,
                    root: root,
                    includeHidden: includeHidden,
                    minSize: minFileSize
                )
                switch decision {
                case .skip(let reason):
                    if reason == .denied || reason == .otherUserFile || reason == .protectedLocation {
                        rootCounts.denied += 1
                    }
                    continue
                case .include:
                    break
                }

                rootCounts.files += 1
                rootCounts.bytesIndexed += record.logicalSize
                pendingRecords.append(record)

                if pendingRecords.count >= batchSize {
                    flush(&pendingRecords, sink: sink, root: root)
                    totals.merge(rootCounts)
                    rootTotals.merge(rootCounts)
                    rootCounts = InventoryCounts()
                    counts(totals, path)
                    await Task.yield()
                }
            }

            if !pendingRecords.isEmpty {
                flush(&pendingRecords, sink: sink, root: root)
            }
            totals.merge(rootCounts)
            rootTotals.merge(rootCounts)
            rootTotals.errors += enumerationErrors.count
            counts(totals, rootPath)

            let outcome: RootOutcome = rootTotals.denied > 0
                || rootTotals.errors > 0
                || rootTotals.truncated > 0
                ? .partial(deniedPaths: rootTotals.denied, errors: rootTotals.errors + rootTotals.truncated)
                : .scanned
            results.append(RootScanResult(root: rootPath, outcome: outcome, counts: rootTotals))
        }
        return results
    }

    /// Compatibility wrapper for callers with plain URL roots (tests,
    /// folder-scoped flows). URLs are treated as granted authorized folders.
    public static func scan(
        roots: [URL],
        includeHidden: Bool,
        includePackageContents: Bool,
        minFileSize: Int64,
        sink: @escaping RecordSink,
        counts: @escaping CountSink,
        gate: ScanGate,
        isCancelled: @escaping () -> Bool
    ) async throws -> InventoryCounts {
        let scanRoots = roots.map { ScanPolicy.authorizedFolderRoot($0) }
        let results = try await scan(
            roots: scanRoots,
            includeHidden: includeHidden,
            includePackageContents: includePackageContents,
            minFileSize: minFileSize,
            sink: { record, _ in sink(record) },
            counts: counts,
            gate: gate,
            isCancelled: isCancelled
        )
        var totals = InventoryCounts()
        for result in results {
            totals.merge(result.counts)
        }
        return totals
    }

    private static func flush(_ batch: inout [FileRecord], sink: RootedRecordSink, root: ScanRoot) {
        for record in batch {
            sink(record, root)
        }
        batch.removeAll(keepingCapacity: true)
    }
}
