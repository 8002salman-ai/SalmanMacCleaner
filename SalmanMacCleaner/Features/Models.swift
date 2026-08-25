//
//  Models.swift
//  SalmanMacCleaner
//
//  Shared result models for the scan-based features.
//

import Foundation

/// A single discovered item (file, folder or cache entry).
public struct ScannedItem: Identifiable, Equatable, Hashable {
    public let id: UUID
    public var path: String
    public var size: Int64
    public var isDirectory: Bool
    public var modificationDate: Date?
    public var detail: String?
    /// Optional filesystem identity captured by a scanner. Zero means the
    /// scanner could not safely obtain an inode and path identity is used.
    public var device: Int32
    public var inode: UInt64

    public init(id: UUID = UUID(),
                path: String,
                size: Int64,
                isDirectory: Bool = false,
                modificationDate: Date? = nil,
                detail: String? = nil,
                device: Int32 = 0,
                inode: UInt64 = 0) {
        self.id = id
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.modificationDate = modificationDate
        self.detail = detail
        self.device = device
        self.inode = inode
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// A scanned result set that also carries its scanning roots so cleanup can
/// revalidate against the same containment boundary.
public struct ScanResult: Equatable {
    public var items: [ScannedItem]
    public var roots: [String]
    public var totalBytes: Int64
    public var completed: Bool
    public var skippedCount: Int
    public var errorMessage: String?

    public init(items: [ScannedItem] = [],
                roots: [String] = [],
                totalBytes: Int64 = 0,
                completed: Bool = true,
                skippedCount: Int = 0,
                errorMessage: String? = nil) {
        self.items = items
        self.roots = roots
        self.totalBytes = totalBytes
        self.completed = completed
        self.skippedCount = skippedCount
        self.errorMessage = errorMessage
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// A group of duplicate candidates. Grouping pipeline:
/// exact size → full streaming SHA-256 → device+inode identity (hard links).
/// Files in a group are one representative per distinct inode, so hard links
/// to the same data are never counted as separate reclaimable copies.
public struct DuplicateGroup: Identifiable, Equatable {
    public let id: UUID
    public var files: [ScannedItem]
    public var size: Int64
    public var hash: String
    public var containsHardLinks: Bool

    public init(id: UUID = UUID(),
                files: [ScannedItem],
                size: Int64,
                hash: String,
                containsHardLinks: Bool = false) {
        self.id = id
        self.files = files
        self.size = size
        self.hash = hash
        self.containsHardLinks = containsHardLinks
    }

    /// Bytes that could be reclaimed by removing all but one copy.
    public var reclaimableBytes: Int64 {
        guard files.count > 1 else { return 0 }
        let (value, overflowed) = max(size, 0).multipliedReportingOverflow(by: Int64(files.count - 1))
        return overflowed ? Int64.max : value
    }

    /// Kept file (shortest path wins; lexical order breaks ties).
    public var keeper: ScannedItem? {
        if containsHardLinks {
            // DuplicateFinder orders the representative of the multi-link
            // identity first. Keeping it ensures the cleanup target is the
            // distinct inode, not one alias whose data would remain reachable.
            return files.first
        }
        return files.min {
            if $0.path.count == $1.path.count { return $0.path < $1.path }
            return $0.path.count < $1.path.count
        }
    }

    /// The files the engine may offer for selection (all but the deterministic
    /// keeper, never simply the first hash result).
    public var removableFiles: [ScannedItem] {
        guard let keeper else { return [] }
        return files.filter { $0.id != keeper.id }
    }
}

/// One entry in the developer cache scanner, grouped by tool category.
public struct DeveloperCacheEntry: Identifiable, Equatable {
    public let id: UUID
    public let category: String
    public let name: String
    public let path: String
    public let size: Int64
    public let modified: Date?
    public let isDirectory: Bool
    public let confidence: SafetyLevel
    public let reason: String
    public let device: Int32
    public let inode: UInt64

    public init(id: UUID = UUID(),
                category: String,
                name: String,
                path: String,
                size: Int64,
                modified: Date? = nil,
                isDirectory: Bool = true,
                confidence: SafetyLevel = .review,
                reason: String = "",
                device: Int32 = 0,
                inode: UInt64 = 0) {
        self.id = id
        self.category = category
        self.name = name
        self.path = path
        self.size = size
        self.modified = modified
        self.isDirectory = isDirectory
        self.confidence = confidence
        self.reason = reason
        self.device = device
        self.inode = inode
    }
}

/// Confidence label for uninstaller candidates.
public enum UninstallConfidence: String, Equatable {
    case high
    case medium
    case cautious

    public var title: String {
        switch self {
        case .high: return NSLocalizedString("confidence.high", comment: "")
        case .medium: return NSLocalizedString("confidence.medium", comment: "")
        case .cautious: return NSLocalizedString("confidence.cautious", comment: "")
        }
    }

    public var colorHex: String {
        switch self {
        case .high: return "22C55E"
        case .medium: return "F59E0B"
        case .cautious: return "EF4444"
        }
    }
}

/// A per-category disk usage entry for the dashboard.
public struct DiskUsageCategory: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let icon: String
    public let bytes: Int64
    public let tint: String

    public init(id: String, title: String, icon: String, bytes: Int64, tint: String) {
        self.id = id
        self.title = title
        self.icon = icon
        self.bytes = bytes
        self.tint = tint
    }
}

/// Storage overview snapshot shown on the dashboard.
public struct StorageSnapshot: Equatable {
    public var totalCapacity: Int64
    public var available: Int64
    public var used: Int64
    public var purgeable: Int64
    public var volumeName: String
    public var categories: [DiskUsageCategory]

    public init(totalCapacity: Int64,
                available: Int64,
                used: Int64,
                purgeable: Int64,
                volumeName: String,
                categories: [DiskUsageCategory]) {
        self.totalCapacity = totalCapacity
        self.available = available
        self.used = used
        self.purgeable = purgeable
        self.volumeName = volumeName
        self.categories = categories
    }

    public var usedFraction: Double {
        guard totalCapacity > 0 else { return 0 }
        return min(max(Double(used) / Double(totalCapacity), 0), 1)
    }

    public var availableFraction: Double {
        max(1 - usedFraction, 0)
    }
}
