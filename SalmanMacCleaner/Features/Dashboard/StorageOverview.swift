//
//  StorageOverview.swift
//  SalmanMacCleaner
//
//  Reads volume capacity/availability through URLResourceValues and builds the
//  per-category breakdown used by the dashboard. Read-only — never mutates the
//  filesystem.
//

import Foundation

public enum StorageOverview {

    /// Snapshot the home volume's usage. Returns nil when unavailable. The
    /// optional cancellation probe keeps Health Check responsive while its
    /// bounded category measurements run.
    public static func snapshot(isCancelled: @escaping () -> Bool = { false }) -> StorageSnapshot? {
        guard !isCancelled() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let values = try? home.resourceValues(forKeys: [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]) else {
            return nil
        }
        let total = values.volumeTotalCapacity.map { Int64($0) } ?? 0
        let available = values.volumeAvailableCapacity.map { Int64($0) } ?? 0
        let purgeableBase = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? available
        let purgeable = max(available - purgeableBase, 0)
        let used = max(total - available, 0)
        let name = values.volumeName ?? NSLocalizedString("storage.volume_unknown", comment: "")

        return StorageSnapshot(
            totalCapacity: total,
            available: available,
            used: used,
            purgeable: purgeable,
            volumeName: name,
            categories: measureCategories(isCancelled: isCancelled)
        )
    }

    /// Measure the well-known top-level folders under the home directory.
    /// This is intentionally shallow (one level) and never descends into
    /// Library internals.
    public static func measureCategories(isCancelled: @escaping () -> Bool = { false }) -> [DiskUsageCategory] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let definitions: [(id: String, name: String, icon: String, tint: String)] = [
            ("library", "Library", "books.vertical.fill", "60A5FA"),
            ("applications", "Applications", "app.badge.fill", "34D399"),
            ("documents", "Documents", "doc.text.fill", "FBBF24"),
            ("downloads", "Downloads", "arrow.down.circle.fill", "F87171"),
            ("desktop", "Desktop", "desktopcomputer", "A78BFA"),
            ("pictures", "Pictures", "photo.fill", "F472B6"),
            ("movies", "Movies", "film.fill", "22D3EE"),
            ("music", "Music", "music.note", "4ADE80")
        ]

        return definitions.compactMap { definition in
            guard !isCancelled() else { return nil }
            let url = home.appendingPathComponent(definition.name, isDirectory: true)
            // Depth 2 keeps the measurement bounded while still producing a
            // representative size for deep folders like ~/Library.
            let bytes = directorySize(url: url, depth: 2, isCancelled: isCancelled)
            return DiskUsageCategory(
                id: definition.id,
                title: definition.name,
                icon: definition.icon,
                bytes: bytes,
                tint: definition.tint
            )
        }
    }

    public struct DirectoryMeasurement: Equatable {
        public var bytes: Int64
        public var entriesVisited: Int
        public var inaccessibleEntries: Int
        public var truncated: Bool

        public init(bytes: Int64 = 0,
                    entriesVisited: Int = 0,
                    inaccessibleEntries: Int = 0,
                    truncated: Bool = false) {
            self.bytes = max(bytes, 0)
            self.entriesVisited = max(entriesVisited, 0)
            self.inaccessibleEntries = max(inaccessibleEntries, 0)
            self.truncated = truncated
        }
    }

    /// Bounded directory measurement with explicit coverage signals. The
    /// legacy `directorySize` wrapper below intentionally keeps its simple
    /// byte-only API for existing dashboard callers.
    public static func directoryMeasurement(
        url: URL,
        depth: Int,
        isCancelled: @escaping () -> Bool = { false }
    ) -> DirectoryMeasurement {
        guard depth >= 0 else { return DirectoryMeasurement(truncated: true) }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
        let inaccessible = TraversalIssueCounter()
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in
                inaccessible.record()
                return true
            }
        ) else {
            return DirectoryMeasurement(inaccessibleEntries: 1)
        }

        var total: Int64 = 0
        var entriesVisited = 0
        var truncated = false
        for case let fileURL as URL in enumerator {
            entriesVisited += 1
            guard entriesVisited <= 250_000 else {
                truncated = true
                break
            }
            guard !isCancelled() else {
                truncated = true
                break
            }
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
                inaccessible.record()
                continue
            }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if enumerator.level > depth {
                    truncated = true
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isRegularFile == true {
                total = CleanupAccounting.adding(total, Int64(values.fileSize ?? 0))
            }
        }
        return DirectoryMeasurement(
            bytes: total,
            entriesVisited: entriesVisited,
            inaccessibleEntries: inaccessible.count,
            truncated: truncated
        )
    }

    /// Shallow directory size. `depth` limits recursion and symlinks are never
    /// followed.
    public static func directorySize(url: URL, depth: Int, isCancelled: @escaping () -> Bool = { false }) -> Int64 {
        directoryMeasurement(url: url, depth: depth, isCancelled: isCancelled).bytes
    }
}
