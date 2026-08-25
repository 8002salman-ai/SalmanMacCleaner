//
//  FileInventoryScanner.swift
//  SalmanMacCleaner
//
//  Depth-bounded directory enumeration with prefetched resource keys.
//  Streams records to the ScanIndexStore in batches; never holds the whole
//  tree in memory. Cooperative cancellation, pause/resume via ScanGate,
//  graceful handling of files that disappear mid-scan.
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

    public init() {}
}

public enum InventoryScannerError: LocalizedError, Equatable {
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

/// Scans a set of roots, streaming `FileRecord`s to a sink.
public struct FileInventoryScanner {

    public typealias RecordSink = (FileRecord) -> Void
    public typealias CountSink = (InventoryCounts, String?) -> Void

    /// - Parameters:
    ///   - roots: Validated scan roots.
    ///   - includeHidden: Whether dot-files are recorded.
    ///   - includePackageContents: Whether package internals are traversed.
    ///   - minFileSize: Files below this size are still traversed but not recorded.
    ///   - sink: Batched record consumer (e.g. the index store).
    ///   - counts: Periodic counter callback.
    ///   - gate: Pause/resume control.
    ///   - isCancelled: Polled frequently.
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
        var totals = InventoryCounts()
        let batchSize = 250

        for root in roots {
            if isCancelled() { throw InventoryScannerError.cancelled }
            await gate.waitIfPaused()
            let rootPath = root.standardizedFileURL.path
            guard let device = VolumeDiscoveryService.deviceID(ofMountPoint: rootPath) else {
                totals.errors += 1
                continue
            }

            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: rootPath, isDirectory: true),
                includingPropertiesForKeys: MetadataCollector.prefetchedKeys,
                options: [],
                errorHandler: { _, _ in
                    // Permission errors are counted; the scan continues.
                    return true
                }
            ) else {
                totals.denied += 1
                continue
            }

            var pendingRecords: [FileRecord] = []

            for case let url as URL in enumerator {
                if isCancelled() { throw InventoryScannerError.cancelled }
                if await gate.isPaused() {
                    await gate.waitIfPaused()
                }
                if enumerator.level > TraversalPolicy.maximumTraversalDepth {
                    enumerator.skipDescendants()
                    continue
                }

                let path = url.standardizedFileURL.path
                guard let values = try? url.resourceValues(forKeys: Set(MetadataCollector.prefetchedKeys)) else {
                    totals.changedDuringScan += 1
                    continue
                }

                let isDirectory = values.isDirectory ?? false
                let isSymlink = values.isSymbolicLink ?? false

                if isDirectory && !isSymlink {
                    totals.folders += 1
                    let decision = TraversalPolicy.shouldEnterDirectory(
                        url: url,
                        root: rootPath,
                        rootDevice: device,
                        includeHidden: includeHidden,
                        includePackageContents: includePackageContents,
                        scope: ScanScope(mode: .deep)
                    )
                    switch decision {
                    case .include:
                        continue
                    case .skip(let reason):
                        if reason == .suspiciousLink { totals.symlinksRejected += 1 }
                        enumerator.skipDescendants()
                        continue
                    }
                }

                if isSymlink {
                    totals.symlinksRejected += 1
                    continue
                }

                guard let record = MetadataCollector.collect(url: url, values: values) else {
                    totals.changedDuringScan += 1
                    continue
                }

                if record.logicalSize < minFileSize && !record.isDirectory {
                    continue
                }

                totals.files += 1
                totals.bytesIndexed += record.logicalSize
                pendingRecords.append(record)

                if pendingRecords.count >= batchSize {
                    flush(&pendingRecords, sink: sink)
                    counts(totals, path)
                    await Task.yield()
                }
            }

            if !pendingRecords.isEmpty {
                flush(&pendingRecords, sink: sink)
                counts(totals, rootPath)
            }
        }
        return totals
    }

    private static func flush(_ batch: inout [FileRecord], sink: RecordSink) {
        for record in batch {
            sink(record)
        }
        batch.removeAll(keepingCapacity: true)
    }
}
