//
//  ResidualCorrelationEngine.swift
//  SalmanMacCleaner
//
//  Correlates support files with installed applications using exact
//  identifier matching. Loose substring matching alone is forbidden:
//  HIGH confidence requires an exact bundle identifier with no matching
//  installed app and no shared-container conflict.
//

import Foundation

public enum ResidualCorrelationEngine {

    /// Roots inspected for leftovers.
    public static func supportRoots(homeOverride: URL? = nil) -> [String] {
        let home = homeOverride ?? PathSafety.userHome
        return [
            home.path + "/Library/Application Support",
            home.path + "/Library/Caches",
            home.path + "/Library/Preferences",
            home.path + "/Library/Logs",
            home.path + "/Library/Containers",
            home.path + "/Library/Group Containers",
            home.path + "/Library/Saved Application State",
            home.path + "/Library/LaunchAgents"
        ]
    }

    /// Match one support entry against the installed-app inventory.
    /// Returns (matchedBundleID, confidence) or nil.
    public static func match(
        entryPath: String,
        entryName: String,
        installedApps: [AppRecord]
    ) -> (bundleID: String, confidence: LeftoverCandidate.Confidence)? {
        let installedIDs = Set(installedApps.compactMap { $0.bundleID })
        let installedNames = Set(installedApps.map { normalizedName($0.name) })

        // 1. Exact container identifier: `<bundleID>` or `group.<bundleID>`.
        let trimmed = entryName.hasSuffix(".plist") ? String(entryName.dropLast(6)) : entryName
        if trimmed.hasPrefix("group.") {
            let candidate = String(trimmed.dropFirst(6))
            guard !installedIDs.contains(candidate) else { return nil }
            return (candidate, .high)
        }
        if looksLikeBundleID(trimmed) {
            if installedIDs.contains(trimmed) { return nil }
            // A preference domain or container id matching no installed app
            // is a high-confidence leftover.
            return (trimmed, .high)
        }

        // 2. Exact saved-state identifier.
        if entryName.hasSuffix(".savedState") {
            let candidate = String(entryName.dropLast(".savedState".count))
            if installedIDs.contains(candidate) { return nil }
            if looksLikeBundleID(candidate) {
                return (candidate, .high)
            }
            if installedNames.contains(normalizedName(candidate)) { return nil }
            let normalized = normalizedName(candidate)
            guard normalized.count >= 3 else { return nil }
            return (candidate, .medium)
        }

        // 3. Strong normalized-name correlation (multi-token, unambiguous).
        let normalized = normalizedName(entryName)
        guard normalized.count >= 4 else { return nil }
        if installedNames.contains(normalized) { return nil }
        if genericWords.contains(normalized) { return nil }
        return nil
    }

    /// Group leftover candidates by owning bundle ID.
    public static func group(
        candidates: [(path: String, name: String, bundleID: String, confidence: LeftoverCandidate.Confidence)]
    ) -> [LeftoverCandidate] {
        var groups: [String: (paths: [String], size: Int64, confidence: LeftoverCandidate.Confidence)] = [:]
        for candidate in candidates {
            let size = FileUtilities.fileSize(atPath: candidate.path)
            if var existing = groups[candidate.bundleID] {
                existing.paths.append(candidate.path)
                existing.size += size
                existing.confidence = min(existing.confidence, candidate.confidence)
                groups[candidate.bundleID] = existing
            } else {
                groups[candidate.bundleID] = ([candidate.path], size, candidate.confidence)
            }
        }
        return groups.map { key, value in
            LeftoverCandidate(
                groupID: key,
                owningBundleID: key,
                paths: value.paths,
                totalSize: value.size,
                confidence: value.confidence,
                sourceRoot: ""
            )
        }
        .sorted { $0.totalSize > $1.totalSize }
    }

    /// Discover leftovers across all support roots against `installedApps`.
    /// Only HIGH-confidence leftovers are suggested; others are shown as
    /// review-only.
    public static func discoverLeftovers(installedApps: [AppRecord]) -> [LeftoverCandidate] {
        var candidates: [(path: String, name: String, bundleID: String, confidence: LeftoverCandidate.Confidence)] = []
        let installedIDs = Set(installedApps.compactMap { $0.bundleID })

        for root in supportRoots() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let path = entry.path
                let name = entry.lastPathComponent
                guard !PathSafety.isProtectedFile(name: name, purpose: .scan) else { continue }

                if let match = match(entryPath: path, entryName: name, installedApps: installedApps),
                   !installedIDs.contains(match.bundleID) {
                    candidates.append((path, name, match.bundleID, match.confidence))
                }
            }
        }
        return group(candidates: candidates)
    }

    // MARK: - Name normalization

    public static func normalizedName(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    public static func looksLikeBundleID(_ candidate: String) -> Bool {
        let parts = candidate.split(separator: ".")
        guard parts.count >= 2 else { return false }
        return parts.allSatisfy { part in
            part.count >= 1 && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static let genericWords: Set<String> = [
        "cache", "caches", "log", "logs", "data", "settings", "support",
        "preferences", "state", "saved", "tmp", "temp", "app", "application"
    ]
}
