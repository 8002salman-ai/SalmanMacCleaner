//
//  LargeFileScanner.swift
//  SalmanMacCleaner
//
//  Finds large files inside user-selected folders only. Depth-limited,
//  symlink-safe, device-contained and cancellable.
//

import Foundation

public enum LargeFileScanError: LocalizedError, Equatable {
    case noRootsSelected
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .noRootsSelected: return NSLocalizedString("largefiles.error.no_roots", comment: "")
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        }
    }
}

public enum LargeFileScanner {

    /// Discover files at or above `thresholdBytes` under `roots`.
    ///
    /// - Parameters:
    ///   - roots: Explicitly selected folders (validated by FolderPicker).
    ///   - thresholdBytes: Minimum file size to report.
    ///   - maxDepth: Maximum directory depth to descend (0 = roots only).
    ///   - excludePatterns: User exclusion substrings.
    ///   - progress: (fraction, detail) callback.
    ///   - isCancelled: Polled every directory; returns early on true.
    public static func scan(
        roots: [URL],
        thresholdBytes: Int64,
        maxDepth: Int,
        excludePatterns: [String] = [],
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> ScanResult {
        guard !roots.isEmpty else { throw LargeFileScanError.noRootsSelected }

        var items: [ScannedItem] = []
        var skipped = 0
        var totalBytes: Int64 = 0
        var rootCount = 0
        let rootTotal = max(roots.count, 1)

        for root in roots {
            if isCancelled() { throw LargeFileScanError.cancelled }
            let rootPath = root.standardizedFileURL.path
            guard let device = PathSafety.deviceID(of: rootPath) else {
                skipped += 1
                continue
            }
            rootCount += 1
            progress(Double(rootCount) / Double(rootTotal), rootPath)
            enumerate(
                root: rootPath,
                device: device,
                thresholdBytes: thresholdBytes,
                maxDepth: maxDepth,
                excludePatterns: excludePatterns,
                into: &items,
                skipped: &skipped,
                totalBytes: &totalBytes,
                isCancelled: isCancelled
            )
            if isCancelled() { throw LargeFileScanError.cancelled }
        }

        items.sort { $0.size > $1.size }
        return ScanResult(
            items: items,
            roots: roots.map { $0.path },
            totalBytes: totalBytes,
            completed: !isCancelled(),
            skippedCount: skipped
        )
    }

    private static func enumerate(
        root: String,
        device: dev_t,
        thresholdBytes: Int64,
        maxDepth: Int,
        excludePatterns: [String],
        into items: inout [ScannedItem],
        skipped: inout Int,
        totalBytes: inout Int64,
        isCancelled: @escaping () -> Bool
    ) {
        var stack: [(path: String, depth: Int)] = [(root, 0)]
        var directoriesVisited = 0

        while let current = stack.popLast() {
            if isCancelled() { return }
            directoriesVisited += 1
            guard directoriesVisited <= 100_000 else {
                skipped += 1
                return
            }
            if current.depth > maxDepth { continue }

            let safe = PathSafety.validate(
                path: current.path,
                root: root,
                expectedDevice: device,
                purpose: .scan,
                allowSymlink: false
            )
            guard case .success(let validated) = safe else {
                skipped += 1
                continue
            }
            guard validated.kind == .directory else { continue }
            guard !PathSafety.isPersonalDirectory(validated.canonical) else {
                skipped += 1
                continue
            }

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: validated.canonical, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                skipped += 1
                continue
            }

            var childDirs: [URL] = []
            for (entryIndex, url) in contents.enumerated() {
                guard entryIndex < 10_000 else {
                    skipped += 1
                    break
                }
                if isCancelled() { return }
                let path = url.path

                if excludePatterns.contains(where: { path.lowercased().contains($0.lowercased()) }) {
                    continue
                }

                guard let childSafe = try? PathSafety.validate(
                    path: path,
                    root: root,
                    expectedDevice: device,
                    purpose: .scan,
                    allowSymlink: false
                ).get() else {
                    skipped += 1
                    continue
                }
                guard !childSafe.isSymlink else {
                    skipped += 1
                    continue
                }

                if childSafe.kind == .directory {
                    childDirs.append(url)
                } else if childSafe.kind == .regularFile {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                          let size = values.fileSize else { continue }
                    if Int64(size) >= thresholdBytes {
                        let identity = Crypto.inode(of: childSafe.canonical)
                        items.append(ScannedItem(
                            path: childSafe.canonical,
                            size: Int64(size),
                            modificationDate: values.contentModificationDate,
                            device: identity.map { Int32(clamping: Int64($0.0)) } ?? 0,
                            inode: identity.map { UInt64($0.1) } ?? 0
                        ))
                        totalBytes = CleanupAccounting.adding(totalBytes, Int64(size))
                    }
                }
            }

            if current.depth < maxDepth {
                for child in childDirs.reversed() {
                    stack.append((child.path, current.depth + 1))
                }
            }
        }
    }
}
