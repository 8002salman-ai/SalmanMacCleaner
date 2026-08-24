//
//  Uninstaller.swift
//  SalmanMacCleaner
//
//  Cautious application uninstaller. Only the calling user's own .app bundles
//  are offered, every candidate gets a confidence label, running apps are
//  blocked, and support files are matched by bundle identifier / app name
//  heuristics. Removal is trash-only through CleanupEngine.
//

import Foundation
import AppKit

public enum Uninstaller {

    /// Enumerate the user's ~/Applications folder and produce candidates with
    /// confidence labels and matched support items. Read-only discovery.
    public static func discoverApplications() -> [UninstallCandidate] {
        let appsURL = PathSafety.userHome.appendingPathComponent("Applications", isDirectory: true)
        let contents = FileUtilities.safeDirectoryContents(at: appsURL, includingHidden: false)

        var candidates: [UninstallCandidate] = []
        for url in contents where url.pathExtension.lowercased() == "app" {
            if let candidate = makeCandidate(appURL: url) {
                candidates.append(candidate)
            }
        }
        candidates.sort { $0.totalSize > $1.totalSize }
        return candidates
    }

    /// Build one candidate: bundle metadata, support matches, confidence.
    public static func makeCandidate(appURL: URL) -> UninstallCandidate? {
        let path = appURL.standardizedFileURL.path
        let safe = PathSafety.validate(path: path, root: PathSafety.userHome.path, purpose: .scan, allowSymlink: false)
        guard case .success(let validated) = safe else { return nil }
        guard PathSafety.isAppBundle(validated.canonical) else { return nil }

        let bundle = Bundle(url: URL(fileURLWithPath: validated.canonical))
        let bundleID = bundle?.bundleIdentifier
        let shortVersion = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildVersion = bundle?.infoDictionary?["CFBundleVersion"] as? String
        let version = shortVersion ?? buildVersion
        let bundleName = bundle?.infoDictionary?["CFBundleName"] as? String
        let name = bundleName
            ?? (validated.canonical as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

        let isRunning = CleanupEngine.isAppRunning(bundlePath: validated.canonical)
        let isUserOwned = PathSafety.isOwnedByCurrentUser(validated.canonical)
        let size = bundleSize(at: validated.canonical)
        let supportItems = matchSupportItems(bundleID: bundleID, appName: name, appPath: validated.canonical)

        let confidence = confidenceLabel(bundleID: bundleID, hasSupportItems: !supportItems.isEmpty, isRunning: isRunning, isUserOwned: isUserOwned)

        return UninstallCandidate(
            name: name,
            bundlePath: validated.canonical,
            bundleID: bundleID,
            version: version,
            size: size,
            supportItems: supportItems,
            confidence: confidence,
            isRunning: isRunning,
            isUserOwned: isUserOwned
        )
    }

    /// Size of the bundle directory (bounded enumeration, no symlink following).
    private static func bundleSize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in false }
        ) else { return 0 }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    /// Match support files: Application Support, Caches, Preferences, Logs,
    /// Containers and saved state that reference the bundle id or app name.
    public static func matchSupportItems(bundleID: String?, appName: String, appPath: String) -> [ScannedItem] {
        let home = PathSafety.userHome.path
        let searchRoots = [
            home + "/Library/Application Support",
            home + "/Library/Caches",
            home + "/Library/Preferences",
            home + "/Library/Logs",
            home + "/Library/Containers",
            home + "/Library/Saved Application State"
        ]

        let sanitizedBundleID = bundleID ?? ""
        let appSlug = (appName as NSString).lastPathComponent
        var matches: [ScannedItem] = []

        for root in searchRoots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: URL(fileURLWithPath: root, isDirectory: true),
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                let entryPath = entry.path
                let safe = PathSafety.validate(path: entryPath, root: root, purpose: .scan, allowSymlink: false)
                guard case .success(let validated) = safe else { continue }
                guard !validated.isSymlink else { continue }

                let name = (entryPath as NSString).lastPathComponent
                guard !PathSafety.isProtectedFile(name: name, purpose: .scan) else { continue }

                let matched: Bool
                if root.hasSuffix("Preferences") || root.hasSuffix("Saved Application State") {
                    let stripped = name
                        .replacingOccurrences(of: ".plist", with: "")
                        .replacingOccurrences(of: ".savedState", with: "")
                    matched = (sanitizedBundleID.isEmpty ? false : name.contains(sanitizedBundleID))
                        || stripped == appSlug
                } else {
                    matched = name == appSlug
                        || name.contains(appSlug)
                        || (!sanitizedBundleID.isEmpty && name.contains(sanitizedBundleID))
                }

                if matched {
                    let size: Int64
                    if validated.kind == .directory {
                        size = bundleSize(at: validated.canonical)
                    } else {
                        size = FileUtilities.fileSize(atPath: validated.canonical)
                    }
                    matches.append(ScannedItem(path: validated.canonical, size: size, isDirectory: validated.kind == .directory))
                }
            }
        }
        return matches
    }

    /// Confidence label heuristics.
    public static func confidenceLabel(
        bundleID: String?,
        hasSupportItems: Bool,
        isRunning: Bool,
        isUserOwned: Bool
    ) -> UninstallConfidence {
        if !isUserOwned { return .cautious }
        if isRunning { return .cautious }
        if bundleID == nil || bundleID!.isEmpty { return .cautious }
        if hasSupportItems { return .high }
        return .medium
    }

    /// Build the cleanup items for a candidate: bundle plus matched support.
    /// Used by the uninstall view when the user confirms.
    public static func cleanupItems(for candidate: UninstallCandidate) -> [CleanupItem] {
        var items: [CleanupItem] = [CleanupItem(path: candidate.bundlePath, size: candidate.size, kind: "app")]
        items.append(contentsOf: candidate.supportItems.map {
            CleanupItem(path: $0.path, size: $0.size, kind: "support")
        })
        return items
    }
}
