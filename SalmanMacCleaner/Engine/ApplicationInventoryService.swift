//
//  ApplicationInventoryService.swift
//  SalmanMacCleaner
//
//  Discovers installed applications from /Applications, ~/Applications,
//  /System/Applications (read-only inventory) and valid nested application
//  directories. Fixes the previous bug where only ~/Applications was
//  enumerated. Deduplicates by canonical bundle path and bundle identifier.
//

import Foundation
import AppKit
import Security

public enum ApplicationInventoryService {

    /// Roots searched, in order. The first matching bundle path wins the
    /// canonical slot; duplicates are dropped.
    public static func discoveryRoots(homeOverride: URL? = nil) -> [URL] {
        let home = homeOverride ?? PathSafety.userHome
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]
    }

    /// Discover all installed applications. System apps are included in the
    /// inventory but marked `isSystemApp` (never offered for uninstall).
    public static func discoverApplications() -> [AppRecord] {
        var records: [AppRecord] = []
        var seenPaths: Set<String> = []
        var seenBundleIDs: Set<String> = []

        for root in discoveryRoots() {
            let apps = appBundles(at: root, maxDepth: 2)
            for appURL in apps {
                guard let record = makeRecord(appURL: appURL, root: root) else { continue }
                let canonical = record.bundlePath
                if seenPaths.contains(canonical) { continue }
                if let bundleID = record.bundleID {
                    if seenBundleIDs.contains(bundleID) { continue }
                    seenBundleIDs.insert(bundleID)
                }
                seenPaths.insert(canonical)
                records.append(record)
            }
        }

        records.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return records
    }

    /// Find .app bundles under `root` up to `maxDepth` levels.
    public static func appBundles(at root: URL, maxDepth: Int) -> [URL] {
        guard maxDepth >= 0 else { return [] }
        var results: [URL] = []

        if root.pathExtension.lowercased() == "app" {
            return [root]
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)) else { continue }
            if values.isSymbolicLink == true { continue }
            let isPackage = values.isPackage ?? false
            let isDirectory = values.isDirectory ?? false
            if entry.pathExtension.lowercased() == "app" && isDirectory {
                results.append(entry)
            } else if isPackage == false && isDirectory && maxDepth > 0 {
                results.append(contentsOf: appBundles(at: entry, maxDepth: maxDepth - 1))
            }
        }
        return results
    }

    /// Build one AppRecord from a bundle URL.
    public static func makeRecord(appURL: URL, root: URL) -> AppRecord? {
        let path = appURL.standardizedFileURL.path
        guard PathSafety.isAppBundle(path) else { return nil }

        let bundle = Bundle(url: URL(fileURLWithPath: path))
        let bundleID = bundle?.bundleIdentifier
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        let build = bundle?.infoDictionary?["CFBundleVersion"] as? String
        let displayValue = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
        let nameValue = bundle?.infoDictionary?["CFBundleName"] as? String
        let displayName = displayValue ?? nameValue ?? appURL.deletingLastPathComponent().lastPathComponent
        let executableName = bundle?.infoDictionary?["CFBundleExecutable"] as? String
        let executablePath = executableName.map { path + "/Contents/MacOS/" + $0 }
        let architectures = executablePath.map { MachOArchitecture.architectures(ofBinaryAt: $0) } ?? []

        let isSystemApp = root.path.hasPrefix("/System/") || root.path == "/System/Applications"
        let isUserOwned = PathSafety.isOwnedByCurrentUser(path)
        let isRunning = CleanupEngine.isAppRunning(bundlePath: path)
        let isQuarantined = QuarantineSupport.hasQuarantineAttribute(path)
        let isCodeSigned = codeSigningStatus(path)
        let bundleSize = bundleSize(at: path)

        // Last opened from LaunchServices metadata where reliably available.
        var lastOpened: Date?
        if let metadata = try? NSWorkspace.shared.urlForApplication(toOpen: appURL) {
            _ = metadata
        }
        let mdItem = MDItemCreate(kCFAllocatorDefault, path as CFString)
        if let mdItem,
           let value = MDItemCopyAttribute(mdItem, kMDItemLastUsedDate) as? Date {
            lastOpened = value
        }

        return AppRecord(
            name: displayName,
            bundlePath: path,
            bundleID: bundleID,
            version: version,
            build: build,
            architectures: architectures,
            isCodeSigned: isCodeSigned,
            isQuarantined: isQuarantined,
            isSystemApp: isSystemApp,
            isUserOwned: isUserOwned,
            isRunning: isRunning,
            bundleSize: bundleSize,
            lastOpened: lastOpened
        )
    }

    /// Code-signing validity via SecStaticCode — read-only, no entitlements.
    public static func codeSigningStatus(_ path: String) -> Bool? {
        var staticCode: SecStaticCode?
        let status = SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &staticCode)
        guard status == errSecSuccess, let code = staticCode else { return nil }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), nil) == errSecSuccess
    }

    /// Bounded bundle size walk (no symlink following).
    public static func bundleSize(at path: String) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey],
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
}
