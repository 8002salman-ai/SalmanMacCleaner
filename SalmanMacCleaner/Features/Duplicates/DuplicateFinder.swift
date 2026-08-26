//
//  DuplicateFinder.swift
//  SalmanMacCleaner
//
//  Streaming duplicate detection for explicitly selected folders.
//
//  Pipeline:
//   1. Enumerate regular files (depth-limited, symlink-safe, device-contained).
//   2. Group by exact size (quick elimination).
//   3. Hash candidates with a streaming SHA-256 (bounded chunk reads).
//   4. Group by digest; within a group, split hard-link sets via
//      (device, inode) identity so two names for the same data are never
//      reported as separate reclaimable copies.
//

import Foundation

public enum DuplicateScanError: LocalizedError, Equatable {
    case noRootsSelected
    case cancelled
    case hashFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noRootsSelected: return NSLocalizedString("duplicates.error.no_roots", comment: "")
        case .cancelled: return NSLocalizedString("scan.error.cancelled", comment: "")
        case .hashFailed(let path): return NSLocalizedString("duplicates.error.hash", comment: "") + " \(path)"
        }
    }
}

public struct DuplicateScanReport: Equatable {
    public var groups: [DuplicateGroup]
    public var filesConsidered: Int
    public var directoriesVisited: Int
    public var deniedPaths: Int
    public var truncated: Bool

    public init(groups: [DuplicateGroup] = [],
                filesConsidered: Int = 0,
                directoriesVisited: Int = 0,
                deniedPaths: Int = 0,
                truncated: Bool = false) {
        self.groups = groups
        self.filesConsidered = filesConsidered
        self.directoriesVisited = directoriesVisited
        self.deniedPaths = deniedPaths
        self.truncated = truncated
    }

    public var isPartial: Bool { truncated || deniedPaths > 0 }
}

public enum DuplicateFinder {

    /// Backwards-compatible convenience that returns only groups. Use
    /// `scanReport` when the UI must display partial-coverage evidence.
    public static func scan(
        roots: [URL],
        maxDepth: Int,
        minimumSize: Int64 = DuplicateFinder.minimumByteSize,
        allowOutsideHome: Bool = false,
        authorizedRoots: [String] = [],
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> [DuplicateGroup] {
        try scanReport(
            roots: roots,
            maxDepth: maxDepth,
            minimumSize: minimumSize,
            allowOutsideHome: allowOutsideHome,
            authorizedRoots: authorizedRoots,
            progress: progress,
            isCancelled: isCancelled
        ).groups
    }

    /// Minimum file size considered for duplicate analysis (skips trivially
    /// small files that dominate result sets).
    public static let minimumByteSize: Int64 = 1_024

    /// Streaming chunk size used while hashing candidates.
    public static let hashChunkSize = Crypto.chunkSize

    /// Scan `roots` for duplicates and return measured coverage metadata.
    /// Progress phases:
    ///  0.0 … 0.4 enumeration, 0.4 … 0.95 hashing, 0.95 … 1.0 grouping.
    public static func scanReport(
        roots: [URL],
        maxDepth: Int,
        minimumSize: Int64 = DuplicateFinder.minimumByteSize,
        allowOutsideHome: Bool = false,
        authorizedRoots: [String] = [],
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> DuplicateScanReport {
        guard !roots.isEmpty else { throw DuplicateScanError.noRootsSelected }

        // Phase 1: enumerate candidates with size.
        var candidates: [ScannedItem] = []
        var seenRoots = Set<String>()
        var enumeration = EnumerationStats()
        for root in roots {
            if isCancelled() { throw DuplicateScanError.cancelled }
            let rootPath = root.standardizedFileURL.path
            guard seenRoots.insert(rootPath).inserted else { continue }
            let rootIsOutsideHome = !PathSafety.isInsideUserHome(rootPath)
            let rootIsAuthorized = !rootIsOutsideHome
                || (allowOutsideHome && authorizedRoots.contains(rootPath))
            guard rootIsAuthorized else {
                enumeration.deniedPaths += 1
                continue
            }
            guard let device = PathSafety.deviceID(of: rootPath) else {
                enumeration.deniedPaths += 1
                continue
            }
            let stats = try enumerateCandidates(
                root: rootPath,
                device: device,
                maxDepth: max(0, maxDepth),
                minimumSize: max(0, minimumSize),
                allowOutsideHome: rootIsOutsideHome && allowOutsideHome,
                into: &candidates,
                isCancelled: isCancelled
            )
            enumeration.directoriesVisited += stats.directoriesVisited
            enumeration.deniedPaths += stats.deniedPaths
            enumeration.truncated = enumeration.truncated || stats.truncated
            progress(0.2, NSLocalizedString("duplicates.phase.enumerate", comment: ""))
        }

        // Phase 2: group by exact size.
        var bySize: [Int64: [ScannedItem]] = [:]
        for item in candidates {
            bySize[item.size, default: []].append(item)
        }
        let hashCandidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }

        // Phase 3: a cheap first/last sample hash prunes same-size files
        // before any full-file read. The sample is still streamed through a
        // bounded handle and never treated as proof of equality.
        var bySample: [String: [ScannedItem]] = [:]
        let sampleTotal = max(hashCandidates.count, 1)
        for (index, item) in hashCandidates.enumerated() {
            if isCancelled() { throw DuplicateScanError.cancelled }
            progress(0.2 + 0.25 * (Double(index + 1) / Double(sampleTotal)), item.path)
            if let sample = DuplicatePipeline.sampleHash(item.path, size: item.size) {
                bySample[sample, default: []].append(item)
            }
        }
        let fullCandidates = bySample.values.filter { $0.count > 1 }.flatMap { $0 }
        let hashTotal = max(fullCandidates.count, 1)
        var hashed = 0

        // Phase 4: streaming SHA-256 only for surviving sample groups.
        var byHash: [String: [ScannedItem]] = [:]
        for item in fullCandidates {
            if isCancelled() { throw DuplicateScanError.cancelled }
            hashed += 1
            progress(0.45 + 0.50 * (Double(hashed) / Double(hashTotal)), item.path)

            switch Crypto.sha256(ofFileAt: item.path, isCancelled: isCancelled) {
            case .success(let digest):
                byHash[digest, default: []].append(item)
            case .failure(let error):
                switch error {
                case .cancelled:
                    throw DuplicateScanError.cancelled
                case .openFailed, .unreadable:
                    continue
                }
            }
        }

        // Phase 4: build groups. Files are first split by (device, inode)
        // identity; a group is only formed when at least two *distinct*
        // inodes share the same digest. Hard links to one file are collapsed
        // to a single representative so removing a link is never counted as
        // reclaimable space.
        var groups: [DuplicateGroup] = []
        for (digest, files) in byHash where files.count > 1 {
            let identitySets = splitHardLinkSets(files)
            guard identitySets.count > 1 else { continue }
            let hardLinked = identitySets.contains { $0.count > 1 }
            let orderedIdentitySets = identitySets.sorted { lhs, rhs in
                // Keep the identity with multiple directory entries first.
                // DuplicateGroup uses that stable representative as the
                // keeper, ensuring cleanup removes the distinct inode rather
                // than one name of a hard-linked file.
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return (lhs.first?.path ?? "") < (rhs.first?.path ?? "")
            }
            let representatives = orderedIdentitySets.compactMap { set in
                set.min { lhs, rhs in
                    lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
                }
            }
            guard let first = representatives.first else { continue }
            groups.append(DuplicateGroup(
                files: representatives,
                size: first.size,
                hash: digest,
                containsHardLinks: hardLinked
            ))
        }

        groups.sort { $0.reclaimableBytes > $1.reclaimableBytes }
        progress(1, NSLocalizedString("duplicates.phase.done", comment: ""))
        return DuplicateScanReport(
            groups: groups,
            filesConsidered: candidates.count,
            directoriesVisited: enumeration.directoriesVisited,
            deniedPaths: enumeration.deniedPaths,
            truncated: enumeration.truncated
        )
    }

    /// Group files by (device, inode). Hard links to the same data land in
    /// the same set.
    private static func splitHardLinkSets(_ files: [ScannedItem]) -> [[ScannedItem]] {
        var identityGroups: [String: [ScannedItem]] = [:]
        for file in files {
            let key: String
            if let identity = Crypto.inode(of: file.path) {
                key = "\(identity.0)-\(identity.1)"
            } else {
                key = "missing-\(file.path)"
            }
            identityGroups[key, default: []].append(file)
        }
        return Array(identityGroups.values)
    }

    private struct EnumerationStats {
        var directoriesVisited = 0
        var deniedPaths = 0
        var truncated = false
    }

    /// Depth-limited enumeration of regular files under `root`. Only the
    /// calling user's files, never symlinks, never other devices.
    private static func enumerateCandidates(
        root: String,
        device: dev_t,
        maxDepth: Int,
        minimumSize: Int64,
        allowOutsideHome: Bool,
        into candidates: inout [ScannedItem],
        isCancelled: @escaping () -> Bool
    ) throws -> EnumerationStats {
        var stack: [(path: String, depth: Int)] = [(root, 0)]
        var stats = EnumerationStats()

        while let current = stack.popLast() {
            if isCancelled() { throw DuplicateScanError.cancelled }
            stats.directoriesVisited += 1
            guard stats.directoriesVisited <= 100_000 else {
                stats.truncated = true
                break
            }
            if current.depth > maxDepth {
                stats.truncated = true
                continue
            }

            let safe = PathSafety.validate(
                path: current.path,
                root: root,
                expectedDevice: device,
                purpose: .scan,
                allowSymlink: false,
                allowOutsideHome: allowOutsideHome
            )
            guard case .success(let validated) = safe else { continue }
            guard validated.kind == .directory else { continue }
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: validated.canonical, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                stats.deniedPaths += 1
                continue
            }

            var childDirs: [URL] = []
            for (entryIndex, url) in contents.enumerated() {
                guard entryIndex < 10_000 else {
                    stats.truncated = true
                    break
                }
                if isCancelled() { throw DuplicateScanError.cancelled }
                let childSafe = PathSafety.validate(
                    path: url.path,
                    root: root,
                    expectedDevice: device,
                    purpose: .scan,
                    allowSymlink: false,
                    allowOutsideHome: allowOutsideHome
                )
                guard case .success(let validatedChild) = childSafe else { continue }
                guard !validatedChild.isSymlink else { continue }

                if validatedChild.kind == .directory {
                    childDirs.append(url)
                } else if validatedChild.kind == .regularFile {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize,
                          Int64(size) >= minimumSize else { continue }
                    let identity = Crypto.inode(of: validatedChild.canonical)
                    candidates.append(ScannedItem(
                        path: validatedChild.canonical,
                        size: Int64(size),
                        device: identity.map { Int32(clamping: Int64($0.0)) } ?? 0,
                        inode: identity.map { UInt64($0.1) } ?? 0
                    ))
                }
            }

            if current.depth < maxDepth {
                for child in childDirs.reversed() {
                    stack.append((child.path, current.depth + 1))
                }
            } else if !childDirs.isEmpty {
                // We inspected the current directory but intentionally did
                // not descend into its child directories because the caller's
                // depth bound was reached. Surface that as partial coverage.
                stats.truncated = true
            }
        }
        return stats
    }
}
