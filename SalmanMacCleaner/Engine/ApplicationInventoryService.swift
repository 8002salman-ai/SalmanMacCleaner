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
import CoreServices
import Security

public enum ApplicationInventoryService {

    /// Roots searched, in order. The first matching bundle path wins the
    /// canonical slot; duplicates are dropped.
    public static func discoveryRoots(homeOverride: URL? = nil) -> [URL] {
        let home = homeOverride ?? PathSafety.userHome
        return [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true)
        ]
    }

    /// Discover all installed applications. System apps are included in the
    /// inventory but marked `isSystemApp` (never offered for uninstall).
    public static func discoverApplications() -> [AppRecord] {
        var records: [AppRecord] = []
        var seenPaths: Set<String> = []
        var seenBundleIDs: Set<String> = []

        var candidates: [(url: URL, root: URL)] = []
        for root in discoveryRoots() {
            candidates.append(contentsOf: appBundles(at: root, maxDepth: 3).map { ($0, root) })
        }
        // A development build can run from DerivedData or a user-selected
        // folder. Include the actual running bundle in the inventory so the
        // general Applications view never silently omits the cleaner.
        let runningBundle = Bundle.main.bundleURL
        if runningBundle.pathExtension.lowercased() == "app" {
            candidates.append((runningBundle, runningBundle.deletingLastPathComponent()))
        }

        for (appURL, root) in candidates {
            guard let record = makeRecord(appURL: appURL, root: root) else { continue }
            let canonical = record.bundlePath
            if seenPaths.contains(canonical) { continue }
            if let bundleID = record.bundleID {
                if seenBundleIDs.contains(bundleID) && !record.isCurrentApp { continue }
                if record.isCurrentApp {
                    // Prefer the running bundle over another copy with the
                    // same identifier so the cleaner is always explicitly
                    // represented as protected in the inventory.
                    records.removeAll { $0.bundleID == bundleID && !$0.isCurrentApp }
                }
                seenBundleIDs.insert(bundleID)
            }
            seenPaths.insert(canonical)
            records.append(record)
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

        for (index, entry) in entries.enumerated() {
            guard index < 10_000, !Task.isCancelled else { break }
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
        let displayName = displayValue ?? nameValue ?? appURL.deletingPathExtension().lastPathComponent
        let publisher = publisherName(from: bundle?.infoDictionary)
        let executableName = bundle?.infoDictionary?["CFBundleExecutable"] as? String
        let executablePath = executableName.map { path + "/Contents/MacOS/" + $0 }
        let architectures = executablePath.map { MachOArchitecture.architectures(ofBinaryAt: $0) } ?? []

        let currentBundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let isCurrentApp = path == currentBundlePath
        let isSystemApp = path == "/System" || path.hasPrefix("/System/")
            || root.path == "/System/Applications"
            || root.path == "/System/Library/CoreServices/Applications"
        let isUserOwned = !isSystemApp && PathSafety.isOwnedByCurrentUser(path)
        let isRunning = CleanupEngine.isAppRunning(bundlePath: path)
        let isQuarantined = QuarantineSupport.hasQuarantineAttribute(path)
        let isCodeSigned = codeSigningStatus(path)
        let bundleSize = bundleSize(at: path)

        // Last opened from Spotlight metadata where reliably available.
        var lastOpened: Date?
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
            lastOpened: lastOpened,
            vendorName: publisher,
            isCurrentApp: isCurrentApp
        )
    }

    /// Prefer the publisher metadata macOS bundles commonly carry. This is
    /// displayed as evidence only; it is never used to infer ownership.
    private static func publisherName(from info: [String: Any]?) -> String? {
        guard let info else { return nil }
        if let value = info["CFBundleGetInfoString"] as? String,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let copyright = info["NSHumanReadableCopyright"] as? String {
            let cleaned = copyright
                .replacingOccurrences(of: "©", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let withoutYear = cleaned.replacingOccurrences(
                of: #"^\s*\d{4}(?:[-–]\d{4})?\s*"#,
                with: "",
                options: .regularExpression
            )
            return withoutYear.isEmpty ? nil : withoutYear
        }
        return nil
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
            options: [],
            errorHandler: { _, _ in false }
        ) else { return 0 }

        var total: Int64 = 0
        var entries = 0
        for case let url as URL in enumerator {
            entries += 1
            guard entries <= 250_000, !Task.isCancelled else { break }
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .fileSizeKey]) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total = CleanupAccounting.adding(total, Int64(values.fileAllocatedSize ?? values.fileSize ?? 0))
            }
        }
        return total
    }
}
