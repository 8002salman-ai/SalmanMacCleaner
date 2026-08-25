//
//  ResidualCorrelationEngine.swift
//  SalmanMacCleaner
//
//  Correlates support entries with bundle metadata using exact identifiers.
//  Loose name matching is intentionally not used: an uninstalled leftover
//  needs a concrete bundle-id evidence trail, while installed apps and Apple
//  services are retained as protected audit groups.
//

import Foundation

public enum ResidualCorrelationEngine {

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

    /// Compatibility matcher used by tests and callers that only need to know
    /// whether an entry is a probable uninstalled application's data.
    public static func match(
        entryPath: String,
        entryName: String,
        installedApps: [AppRecord]
    ) -> (bundleID: String, confidence: LeftoverCandidate.Confidence)? {
        _ = entryPath
        guard let id = exactBundleID(from: entryName),
              !isAppleService(id),
              !installedApps.contains(where: { $0.bundleID == id }) else { return nil }
        return (id, .high)
    }

    /// Return groups for all exact-id support entries, including protected
    /// installed-app and Apple-service groups for a transparent audit.
    public static func discoverLeftovers(
        installedApps: [AppRecord],
        homeOverride: URL? = nil
    ) -> [LeftoverCandidate] {
        let installedByID = Dictionary(
            installedApps.compactMap { app in app.bundleID.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        var candidates: [(path: String, bundleID: String, confidence: LeftoverCandidate.Confidence, classification: LeftoverClassification, appName: String, publisher: String?, evidence: String)] = []
        var seenPaths = Set<String>()

        for root in supportRoots(homeOverride: homeOverride) {
            guard !Task.isCancelled else { break }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                guard !Task.isCancelled else { break }
                let path = entry.standardizedFileURL.path
                guard seenPaths.insert(path).inserted,
                      case .success(let validated) = PathSafety.validate(
                          path: path,
                          root: (homeOverride ?? PathSafety.userHome).path,
                          purpose: .scan,
                          allowSymlink: false
                      ),
                      validated.kind == .directory || validated.kind == .regularFile,
                      !validated.isSymlink,
                      !PathSafety.isProtectedFile(name: entry.lastPathComponent, purpose: .scan),
                      let bundleID = exactBundleID(from: entry.lastPathComponent) else { continue }

                if let app = installedByID[bundleID] {
                    candidates.append((
                        path, bundleID, .cautious, .installedAppData, app.name,
                        app.vendorName,
                        NSLocalizedString("leftovers.evidence.installed", comment: "")
                    ))
                } else if isAppleService(bundleID) {
                    candidates.append((
                        path, bundleID, .cautious, .appleSystemService, "Apple system service", nil,
                        NSLocalizedString("leftovers.evidence.apple", comment: "")
                    ))
                } else {
                    candidates.append((
                        path, bundleID, .high, .probableUninstalledAppLeftover,
                        NSLocalizedString("leftovers.uninstalled_name", comment: ""), nil,
                        NSLocalizedString("leftovers.evidence.exact_id", comment: "")
                    ))
                }
            }
        }
        return groupDetailed(candidates)
    }

    /// Group only caller-supplied probable candidates (legacy API).
    public static func group(
        candidates: [(path: String, name: String, bundleID: String, confidence: LeftoverCandidate.Confidence)]
    ) -> [LeftoverCandidate] {
        groupDetailed(candidates.map {
            ($0.path, $0.bundleID, $0.confidence, .probableUninstalledAppLeftover,
             NSLocalizedString("leftovers.uninstalled_name", comment: ""), nil,
             NSLocalizedString("leftovers.evidence.exact_id", comment: ""))
        })
    }

    private static func groupDetailed(
        _ candidates: [(path: String, bundleID: String, confidence: LeftoverCandidate.Confidence, classification: LeftoverClassification, appName: String, publisher: String?, evidence: String)]
    ) -> [LeftoverCandidate] {
        var groups: [String: (paths: [String], size: Int64, confidence: LeftoverCandidate.Confidence, classification: LeftoverClassification, appName: String, publisher: String?, evidence: String)] = [:]
        var seenPhysical = Set<String>()
        var seenIdentitiesByBundle: [String: Set<String>] = [:]
        for candidate in candidates {
            let path = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard seenPhysical.insert(path).inserted,
                  PathSafety.kind(of: path) == .directory || PathSafety.kind(of: path) == .regularFile else { continue }
            let identity: String
            if let inode = Crypto.inode(of: path) {
                identity = "inode:\(inode.0):\(inode.1)"
            } else {
                identity = "path:\(path)"
            }
            let isNewPhysicalAllocation = seenIdentitiesByBundle[candidate.bundleID, default: []].insert(identity).inserted
            let size = isNewPhysicalAllocation ? measuredSize(at: path) : 0
            if var existing = groups[candidate.bundleID] {
                existing.paths.append(path)
                existing.size = CleanupAccounting.adding(existing.size, size)
                existing.confidence = min(existing.confidence, candidate.confidence)
                // The most restrictive classification wins.
                if existing.classification == .probableUninstalledAppLeftover && candidate.classification != existing.classification {
                    existing.classification = candidate.classification
                }
                groups[candidate.bundleID] = existing
            } else {
                groups[candidate.bundleID] = ([path], size, candidate.confidence, candidate.classification, candidate.appName, candidate.publisher, candidate.evidence)
            }
        }

        return groups.map { bundleID, value in
            LeftoverCandidate(
                groupID: bundleID,
                owningBundleID: bundleID,
                paths: value.paths.sorted(),
                totalSize: value.size,
                confidence: value.confidence,
                sourceRoot: value.paths.first.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path } ?? "",
                applicationName: value.appName,
                publisher: value.publisher,
                classification: value.classification,
                evidence: value.evidence
            )
        }
        .sorted {
            if $0.totalSize == $1.totalSize { return $0.applicationName < $1.applicationName }
            return $0.totalSize > $1.totalSize
        }
    }

    /// Recognise only concrete bundle-id-shaped names or saved-state names.
    /// The path is accepted as an argument for API clarity and future root
    /// checks; the identifier itself must still come from the final component.
    public static func exactBundleID(from entryName: String) -> String? {
        let trimmed: String
        if entryName.hasSuffix(".plist") { trimmed = String(entryName.dropLast(6)) }
        else if entryName.hasSuffix(".savedState") { trimmed = String(entryName.dropLast(".savedState".count)) }
        else { trimmed = entryName }
        let candidate = trimmed.hasPrefix("group.") ? String(trimmed.dropFirst(6)) : trimmed
        guard looksLikeBundleID(candidate),
              !genericWords.contains(candidate.lowercased()) else { return nil }
        return candidate
    }

    public static func isAppleService(_ bundleID: String) -> Bool {
        bundleID == "com.apple" || bundleID.hasPrefix("com.apple.")
    }

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
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    private static func measuredSize(at path: String) -> Int64 {
        guard let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]),
              values.isDirectory == true else {
            return FileUtilities.fileSize(atPath: path)
        }
        var total: Int64 = 0
        var stack = [path]
        var visited = Set<String>()
        var directoriesVisited = 0
        var entriesVisited = 0
        while let current = stack.popLast() {
            if Task.isCancelled || directoriesVisited >= 100_000 || entriesVisited >= 250_000 { break }
            directoriesVisited += 1
            guard visited.insert(current).inserted else { continue }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: current, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for entry in entries {
                entriesVisited += 1
                if Task.isCancelled || entriesVisited > 250_000 { break }
                guard let child = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]), child.isSymbolicLink != true else { continue }
                if child.isRegularFile == true { total = CleanupAccounting.adding(total, Int64(child.fileSize ?? 0)) }
                else if child.isDirectory == true { stack.append(entry.path) }
            }
        }
        return total
    }

    private static let genericWords: Set<String> = [
        "cache", "caches", "log", "logs", "data", "settings", "support",
        "preferences", "state", "saved", "tmp", "temp", "app", "application"
    ]
}
