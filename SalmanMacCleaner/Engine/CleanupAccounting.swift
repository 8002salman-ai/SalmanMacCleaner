//
//  CleanupAccounting.swift
//  SalmanMacCleaner
//
//  Pure filesystem accounting helpers shared by scan results and cleanup.
//  The UI must never add raw category totals: nested selections and hard links
//  represent the same physical bytes and are counted once here.
//

import Foundation

public struct CleanupByteBreakdown: Equatable, Codable {
    public var candidateBytes: Int64
    public var selectedBytes: Int64
    public var movedBytes: Int64
    public var failedBytes: Int64
    public var remainingBytes: Int64

    public init(candidateBytes: Int64 = 0,
                selectedBytes: Int64 = 0,
                movedBytes: Int64 = 0,
                failedBytes: Int64 = 0,
                remainingBytes: Int64 = 0) {
        self.candidateBytes = max(candidateBytes, 0)
        self.selectedBytes = max(selectedBytes, 0)
        self.movedBytes = max(movedBytes, 0)
        self.failedBytes = max(failedBytes, 0)
        self.remainingBytes = max(remainingBytes, 0)
    }
}

public enum CleanupAccounting {

    public static func currentAllocatedBytes(at path: String, fallback: Int64) -> Int64 {
        guard PathSafety.kind(of: path) != .symlinkToFile,
              PathSafety.kind(of: path) != .symlinkToDirectory else {
            return max(fallback, 0)
        }
        if PathSafety.kind(of: path) == .directory {
            // A directory's own stat size is only its directory record, not
            // the contents the user saw in the scan. Re-measure it without
            // following links; an incomplete bounded walk falls back to the
            // scanner's last complete measurement rather than inventing 4 KB.
            return measureDirectory(at: path) ?? max(fallback, 0)
        }
        guard let record = MetadataCollector.collect(url: URL(fileURLWithPath: path, isDirectory: false)),
              record.allocatedSize >= 0 else { return max(fallback, 0) }
        return record.allocatedSize > 0 ? record.allocatedSize : max(fallback, 0)
    }

    private static func measureDirectory(at path: String) -> Int64? {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else { return nil }
        var total: Int64 = 0
        var visited = Set<String>()
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= 250_000 else { return nil }
            let childPath = url.standardizedFileURL.path
            guard visited.insert(childPath).inserted else { continue }
            switch PathSafety.kind(of: childPath) {
            case .symlinkToFile, .symlinkToDirectory:
                enumerator.skipDescendants()
            case .directory:
                if enumerator.level > 64 { enumerator.skipDescendants() }
            case .regularFile:
                guard let values = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey, .fileSizeKey]) else { continue }
                total = adding(total, Int64(values.fileAllocatedSize ?? values.fileSize ?? 0))
            case .missing, .other, .volumeMount:
                enumerator.skipDescendants()
            }
        }
        return total
    }

    /// Add bytes without allowing a corrupt filesystem value to wrap Int64.
    public static func adding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard rhs > 0 else { return max(lhs, 0) }
        let (value, overflowed) = max(lhs, 0).addingReportingOverflow(rhs)
        return overflowed ? Int64.max : value
    }

    /// Stable lexical paths used for containment checks. This does not resolve
    /// the leaf symlink, so a link can never be mistaken for its target.
    public static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Remove duplicate paths and descendants. If a selected directory owns a
    /// child, selecting that child adds no bytes and it must not be executed a
    /// second time.
    public static func nonOverlappingPaths(_ paths: [String]) -> [String] {
        let unique = Set(paths.map(standardizedPath))
        var result: [String] = []
        for path in unique.sorted(by: { ($0 as NSString).pathComponents.count < ($1 as NSString).pathComponents.count || ($0 as NSString).pathComponents.count == ($1 as NSString).pathComponents.count && $0 < $1 }) {
            guard !result.contains(where: { $0 != path && PathSafety.isPath(path, inside: $0) }) else { continue }
            result.append(path)
        }
        return result
    }

    /// Deduplicate physical files when stat identity is available. A hard
    /// link is one inode and therefore cannot be reported as reclaimable bytes
    /// twice. Missing identity falls back to the canonical path.
    public static func uniqueBytes(for records: [FileRecord]) -> Int64 {
        let nonOverlapping = nonOverlappingPaths(records.map(\.path))
        let byPath = Dictionary(records.map { (standardizedPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var identities = Set<String>()
        var total: Int64 = 0
        for path in nonOverlapping {
            guard let record = byPath[path], !record.isSymlink else { continue }
            let identity = record.device == 0 || record.inode == 0
                ? "path:\(path)"
                : "inode:\(record.device):\(record.inode)"
            guard identities.insert(identity).inserted else { continue }
            total = adding(total, max(record.allocatedSize, 0))
        }
        return total
    }

    public static func uniqueBytes(for items: [ScannedItem]) -> Int64 {
        let nonOverlapping = nonOverlappingPaths(items.map(\.path))
        let byPath = Dictionary(items.map { (standardizedPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var identities = Set<String>()
        var total: Int64 = 0
        for path in nonOverlapping {
            guard let item = byPath[path] else { continue }
            let identity = item.device == 0 || item.inode == 0
                ? "path:\(path)"
                : "inode:\(item.device):\(item.inode)"
            guard identities.insert(identity).inserted else { continue }
            total = adding(total, max(item.size, 0))
        }
        return total
    }

    public static func uniqueBytes(for cleanupItems: [CleanupItem]) -> Int64 {
        let nonOverlapping = nonOverlappingPaths(cleanupItems.map(\.path))
        let byPath = Dictionary(cleanupItems.map { (standardizedPath($0.path), $0) }, uniquingKeysWith: { first, _ in first })
        var identities = Set<String>()
        var total: Int64 = 0
        for path in nonOverlapping {
            guard let item = byPath[path] else { continue }
            let identity = item.device == 0 || item.inode == 0
                ? "path:\(path)"
                : "inode:\(item.device):\(item.inode)"
            guard identities.insert(identity).inserted else { continue }
            total = adding(total, max(item.size, 0))
        }
        return total
    }

    /// Reconcile a result against a fresh list of paths. A moved path is not
    /// remaining; a failed path is remaining only when it still exists.
    public static func reconcile(selected: [CleanupItem],
                                 moved: [String],
                                 failed: [(path: String, reason: String)],
                                 sizeOverrides: [String: Int64] = [:]) -> CleanupByteBreakdown {
        let candidate = uniqueBytes(for: selected)
        let movedSet = Set(moved.map(standardizedPath))
        let failedSet = Set(failed.map { standardizedPath($0.path) })
        let selectedSet = Set(nonOverlappingPaths(selected.map(\.path)))
        struct PhysicalState {
            var bytes: Int64
            var moved = false
            var failed = false
            var remains = false
        }
        var states: [String: PhysicalState] = [:]
        for item in selected {
            let path = standardizedPath(item.path)
            guard selectedSet.contains(path) else { continue }
            let identity = item.device == 0 || item.inode == 0
                ? "path:\(path)"
                : "inode:\(item.device):\(item.inode)"
            let bytes = max(sizeOverrides[path] ?? item.size, 0)
            if var state = states[identity] {
                // Hard-link aliases are one physical allocation. Prefer the
                // freshest/nonzero measurement and combine statuses before
                // summing, so iteration order cannot hide a moved alias behind
                // a failed alias.
                state.bytes = max(state.bytes, bytes)
                state.moved = state.moved || movedSet.contains(path)
                state.failed = state.failed || failedSet.contains(path)
                state.remains = state.remains || FileManager.default.fileExists(atPath: path)
                states[identity] = state
            } else {
                states[identity] = PhysicalState(
                    bytes: bytes,
                    moved: movedSet.contains(path),
                    failed: failedSet.contains(path),
                    remains: FileManager.default.fileExists(atPath: path)
                )
            }
        }
        var movedBytes: Int64 = 0
        var failedBytes: Int64 = 0
        var remainingBytes: Int64 = 0
        for state in states.values {
            // A successful Trash mover is the authoritative movement result;
            // SystemTrashMover has already verified the destination. Keep a
            // separate remaining-byte diagnostic if a test double or a
            // concurrent filesystem change leaves the source visible, rather
            // than silently converting a successful mover result to failure.
            if state.moved {
                movedBytes = adding(movedBytes, state.bytes)
            }
            if state.failed {
                failedBytes = adding(failedBytes, state.bytes)
            }
            if state.remains {
                remainingBytes = adding(remainingBytes, state.bytes)
            }
        }
        return CleanupByteBreakdown(
            candidateBytes: candidate,
            selectedBytes: candidate,
            movedBytes: movedBytes,
            failedBytes: failedBytes,
            remainingBytes: remainingBytes
        )
    }
}
