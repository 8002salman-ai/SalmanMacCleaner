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

public enum DuplicateFinder {

    /// Minimum file size considered for duplicate analysis (skips trivially
    /// small files that dominate result sets).
    public static let minimumByteSize: Int64 = 1_024

    /// Streaming chunk size used while hashing candidates.
    public static let hashChunkSize = Crypto.chunkSize

    /// Scan `roots` for duplicates. Progress phases:
    ///  0.0 … 0.4 enumeration, 0.4 … 0.95 hashing, 0.95 … 1.0 grouping.
    public static func scan(
        roots: [URL],
        maxDepth: Int,
        minimumSize: Int64 = DuplicateFinder.minimumByteSize,
        progress: @escaping (Double, String?) -> Void,
        isCancelled: @escaping () -> Bool
    ) throws -> [DuplicateGroup] {
        guard !roots.isEmpty else { throw DuplicateScanError.noRootsSelected }

        // Phase 1: enumerate candidates with size.
        var candidates: [ScannedItem] = []
        for root in roots {
            if isCancelled() { throw DuplicateScanError.cancelled }
            let rootPath = root.standardizedFileURL.path
            guard let device = PathSafety.deviceID(of: rootPath) else { continue }
            enumerateCandidates(
                root: rootPath,
                device: device,
                maxDepth: maxDepth,
                minimumSize: minimumSize,
                into: &candidates,
                isCancelled: isCancelled
            )
            progress(0.2, NSLocalizedString("duplicates.phase.enumerate", comment: ""))
        }

        // Phase 2: group by exact size.
        var bySize: [Int64: [ScannedItem]] = [:]
        for item in candidates {
            bySize[item.size, default: []].append(item)
        }
        let hashCandidates = bySize.values.filter { $0.count > 1 }.flatMap { $0 }
        let hashTotal = max(hashCandidates.count, 1)
        var hashed = 0

        // Phase 3: streaming SHA-256 per candidate.
        var byHash: [String: [ScannedItem]] = [:]
        for item in hashCandidates {
            if isCancelled() { throw DuplicateScanError.cancelled }
            hashed += 1
            progress(0.2 + 0.75 * (Double(hashed) / Double(hashTotal)), item.path)

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
            let representatives = identitySets.compactMap { $0.first }
            let hardLinked = identitySets.contains { $0.count > 1 }
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
        return groups
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

    /// Depth-limited enumeration of regular files under `root`. Only the
    /// calling user's files, never symlinks, never other devices.
    private static func enumerateCandidates(
        root: String,
        device: dev_t,
        maxDepth: Int,
        minimumSize: Int64,
        into candidates: inout [ScannedItem],
        isCancelled: @escaping () -> Bool
    ) {
        var stack: [(path: String, depth: Int)] = [(root, 0)]

        while let current = stack.popLast() {
            if isCancelled() { return }
            if current.depth > maxDepth { continue }

            let safe = PathSafety.validate(path: current.path, root: root, expectedDevice: device, purpose: .scan, allowSymlink: false)
            guard case .success(let validated) = safe else { continue }
            guard validated.kind == .directory else { continue }
            guard !PathSafety.isPersonalDirectory(validated.canonical) else { continue }

            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: validated.canonical, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            var childDirs: [URL] = []
            for url in contents {
                if isCancelled() { return }
                let childSafe = PathSafety.validate(
                    path: url.path,
                    root: root,
                    expectedDevice: device,
                    purpose: .scan,
                    allowSymlink: false
                )
                guard case .success(let validatedChild) = childSafe else { continue }
                guard !validatedChild.isSymlink else { continue }

                if validatedChild.kind == .directory {
                    childDirs.append(url)
                } else if validatedChild.kind == .regularFile {
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize,
                          Int64(size) >= minimumSize else { continue }
                    candidates.append(ScannedItem(path: validatedChild.canonical, size: Int64(size)))
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
