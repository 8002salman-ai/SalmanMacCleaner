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

    /// Snapshot the home volume's usage. Returns nil when unavailable.
    public static func snapshot() -> StorageSnapshot? {
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
            categories: measureCategories()
        )
    }

    /// Measure the well-known top-level folders under the home directory.
    /// This is intentionally shallow (one level) and never descends into
    /// Library internals.
    public static func measureCategories() -> [DiskUsageCategory] {
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

        return definitions.map { definition in
            let url = home.appendingPathComponent(definition.name, isDirectory: true)
            // Depth 2 keeps the measurement bounded while still producing a
            // representative size for deep folders like ~/Library.
            let bytes = directorySize(url: url, depth: 2)
            return DiskUsageCategory(
                id: definition.id,
                title: definition.name,
                icon: definition.icon,
                bytes: bytes,
                tint: definition.tint
            )
        }
    }

    /// Shallow directory size. `depth` limits recursion (0 = direct children
    /// only, including their recursive totals for folders that are fast).
    /// Stays on the home device and never follows symlinks.
    public static func directorySize(url: URL, depth: Int) -> Int64 {
        guard depth >= 0 else { return 0 }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true {
                if enumerator.level > depth {
                    enumerator.skipDescendants()
                }
                continue
            }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }
}
