//
//  MetadataCollector.swift
//  SalmanMacCleaner
//
//  Collects rich metadata for one filesystem entry using prefetched
//  URLResourceValues plus stat(2) for device/inode/ownership identity.
//

import Foundation
import Darwin

public enum MetadataCollector {

    /// Resource keys prefetched during enumeration.
    public static let prefetchedKeys: [URLResourceKey] = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .isPackageKey, .isHiddenKey, .fileSizeKey, .fileAllocatedSizeKey,
        .contentModificationDateKey, .creationDateKey,
        .fileResourceIdentifierKey, .isPurgeableKey
    ]

    /// Build a FileRecord for `url`. Returns nil for entries that cannot be
    /// stat'ed (disappearing files are reported by the caller).
    public static func collect(
        url: URL,
        values: URLResourceValues? = nil,
        bundleID: String? = nil
    ) -> FileRecord? {
        let path = url.standardizedFileURL.path
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }

        let resolvedValues: URLResourceValues
        if let values {
            resolvedValues = values
        } else {
            resolvedValues = (try? url.resourceValues(forKeys: Set(prefetchedKeys))) ?? URLResourceValues()
        }

        // lstat ground truth — never infer "file" from a nil resource value.
        let statKind = PathSafety.kind(of: path)
        let isDir = statKind == .directory
        let isLink = statKind == .symlinkToFile || statKind == .symlinkToDirectory
            || (resolvedValues.isSymbolicLink ?? false)
            || ((statBuffer.st_mode & S_IFMT) == S_IFLNK)
        let logical = Int64(resolvedValues.fileSize ?? 0)
        let allocated = allocatedSize(values: resolvedValues, stat: statBuffer)
        let hidden = resolvedValues.isHidden ?? path.hasPrefix(".")

        return FileRecord(
            path: path,
            parent: url.deletingLastPathComponent().path,
            name: url.lastPathComponent,
            isDirectory: isDir && !isLink,
            isPackage: resolvedValues.isPackage ?? false,
            logicalSize: logical,
            allocatedSize: allocated,
            modified: resolvedValues.contentModificationDate,
            created: resolvedValues.creationDate,
            device: Int32(clamping: statBuffer.st_dev),
            inode: UInt64(statBuffer.st_ino),
            ownerUID: UInt32(statBuffer.st_uid),
            permissions: Int32(statBuffer.st_mode & 0o7777),
            isSymlink: isLink,
            isHidden: hidden,
            isPurgeable: resolvedValues.isPurgeable ?? false,
            isQuarantined: QuarantineSupport.hasQuarantineAttribute(path),
            bundleID: bundleID,
            fileResourceID: (resolvedValues.fileResourceIdentifier as? NSObject)?.description
        )
    }

    /// Allocated on-disk size: prefer `fileAllocatedSize`, fall back to
    /// st_blocks * 512 (the value APFS reports for physical allocation).
    public static func allocatedSize(values: URLResourceValues, stat: stat) -> Int64 {
        if let allocated = values.fileAllocatedSize, allocated > 0 {
            return Int64(allocated)
        }
        let blocks = Int64(stat.st_blocks)
        return blocks * 512
    }
}

/// Quarantine (com.apple.quarantine) xattr probe — public xattr API only.
public enum QuarantineSupport {

    public static func hasQuarantineAttribute(_ path: String) -> Bool {
        let size = getxattr(path, "com.apple.quarantine", nil, 0, 0, 0)
        return size > 0
    }
}
