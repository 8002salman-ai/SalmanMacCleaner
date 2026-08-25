//
//  TraversalPolicy.swift
//  SalmanMacCleaner
//
//  Filesystem traversal rules for every scan engine. Builds on the central
//  PathSafety policy and adds volume, package, hidden-file and FSEvents
//  boundaries. Protections are only ever added here — never removed.
//
//  Design notes (fixes for the "one item scanned" defect):
//  - DirectoryEnumerator yields the scan root itself first; the root item is
//    never counted as a file and never pruned via skipDescendants().
//  - Volume roots are granted only with Full Disk Access (or explicit
//    opt-in); the APFS system + data volume pair is treated as one device
//    group so "/" scans can see the data volume.
//  - Authorized folders (security-scoped bookmarks) may live outside the
//    user home and are the only outside-home roots that are scanned.
//

import Foundation

public enum TraversalDecision: Equatable {
    case include
    case skip(reason: TraversalSkipReason)
}

public enum TraversalSkipReason: String, Equatable, Codable {
    case protectedLocation
    case personalDirectory
    case otherUserFile
    case suspiciousLink
    case crossVolumeMount
    case networkVolume
    case timeMachine
    case fseventsInternal
    case hiddenFile
    case packageContent
    case specialFile
    case missingFile
    case denied
    case tooDeep

    /// Localized explanation surfaced in the coverage report.
    public var explanation: String {
        switch self {
        case .protectedLocation: return NSLocalizedString("traversal.skip.protected", comment: "")
        case .personalDirectory: return NSLocalizedString("traversal.skip.personal", comment: "")
        case .otherUserFile: return NSLocalizedString("traversal.skip.other_user", comment: "")
        case .suspiciousLink: return NSLocalizedString("traversal.skip.symlink", comment: "")
        case .crossVolumeMount: return NSLocalizedString("traversal.skip.cross_volume", comment: "")
        case .networkVolume: return NSLocalizedString("traversal.skip.network", comment: "")
        case .timeMachine: return NSLocalizedString("traversal.skip.time_machine", comment: "")
        case .fseventsInternal: return NSLocalizedString("traversal.skip.fsevents", comment: "")
        case .hiddenFile: return NSLocalizedString("traversal.skip.hidden", comment: "")
        case .packageContent: return NSLocalizedString("traversal.skip.package", comment: "")
        case .specialFile: return NSLocalizedString("traversal.skip.special", comment: "")
        case .missingFile: return NSLocalizedString("traversal.skip.missing", comment: "")
        case .denied: return NSLocalizedString("traversal.skip.denied", comment: "")
        case .tooDeep: return NSLocalizedString("traversal.skip.too_deep", comment: "")
        }
    }
}

public enum TraversalPolicy {

    /// Paths that are always invisible to scanners regardless of settings.
    /// This covers Apple-internal bookkeeping — never user data.
    public static let alwaysSkippedDirectoryNames: Set<String> = [
        ".fseventsd", ".Spotlight-V100", ".TemporaryItems", ".Trashes",
        "Backups.backupdb"
    ]

    /// Decide whether a directory may be entered during traversal.
    public static func shouldEnterDirectory(
        url: URL,
        root: ScanRoot,
        includeHidden: Bool,
        includePackageContents: Bool,
        scope: ScanScope
    ) -> TraversalDecision {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        if alwaysSkippedDirectoryNames.contains(name) {
            return .skip(reason: .fseventsInternal)
        }
        if name == ".TimeMachine" || name == "Backups.backupdb" {
            return .skip(reason: .timeMachine)
        }
        if !includeHidden && name.hasPrefix(".") {
            return .skip(reason: .hiddenFile)
        }

        // Packages are app bundles, frameworks, docs, etc. Never descend
        // unless the user explicitly asks for package-content scanning.
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
        if isPackage && !includePackageContents {
            return .skip(reason: .packageContent)
        }

        // App bundles are never descended into by the inventory scanner,
        // even with package-content enabled (bundles are protected).
        if PathSafety.isAppBundle(path) {
            return .skip(reason: .packageContent)
        }

        let safe = PathSafety.validate(
            path: path,
            root: root.url.path,
            expectedDevice: dev_t(root.expectedDevices.first ?? 0),
            additionalDevices: Set(root.expectedDevices.dropFirst().map { dev_t($0) }),
            purpose: .scan,
            allowSymlink: false,
            allowOutsideHome: root.allowsOutsideHome,
            allowProtectedRoot: root.allowProtectedRoot
        )
        switch safe {
        case .failure(let error):
            switch error {
            case .protectedLocation, .outsideUserHome:
                return .skip(reason: .protectedLocation)
            case .ownershipMismatch, .otherUserFile:
                return .skip(reason: .otherUserFile)
            case .suspiciousLink:
                return .skip(reason: .suspiciousLink)
            case .crossVolumeMount:
                return .skip(reason: .crossVolumeMount)
            case .traversalDetected:
                return .skip(reason: .suspiciousLink)
            case .missingPath:
                return .skip(reason: .missingFile)
            default:
                return .skip(reason: .denied)
            }
        case .success(let validated):
            guard validated.kind == .directory else { return .skip(reason: .specialFile) }
            return .include
        }
    }

    /// Decide whether a file entry is recorded in inventory.
    public static func shouldRecordFile(
        url: URL,
        root: ScanRoot,
        includeHidden: Bool,
        minSize: Int64
    ) -> TraversalDecision {
        let path = url.standardizedFileURL.path
        let name = url.lastPathComponent

        if !includeHidden && name.hasPrefix(".") {
            return .skip(reason: .hiddenFile)
        }
        if name == ".DS_Store" {
            return .skip(reason: .hiddenFile)
        }

        let safe = PathSafety.validate(
            path: path,
            root: root.url.path,
            expectedDevice: dev_t(root.expectedDevices.first ?? 0),
            additionalDevices: Set(root.expectedDevices.dropFirst().map { dev_t($0) }),
            purpose: .scan,
            allowSymlink: false,
            allowOutsideHome: root.allowsOutsideHome,
            allowProtectedRoot: root.allowProtectedRoot
        )
        switch safe {
        case .failure(let error):
            switch error {
            case .ownershipMismatch, .otherUserFile:
                return .skip(reason: .otherUserFile)
            case .suspiciousLink, .traversalDetected:
                return .skip(reason: .suspiciousLink)
            case .crossVolumeMount:
                return .skip(reason: .crossVolumeMount)
            case .missingPath:
                return .skip(reason: .missingFile)
            case .protectedLocation, .outsideUserHome:
                return .skip(reason: .protectedLocation)
            default:
                return .skip(reason: .denied)
            }
        case .success(let validated):
            guard validated.kind == .regularFile else { return .skip(reason: .specialFile) }
            if minSize > 0 {
                let size = FileUtilities.fileSize(atPath: validated.canonical)
                if size < minSize {
                    return .skip(reason: .tooDeep) // reused bucket: below size floor
                }
            }
            return .include
        }
    }

    /// Whether a root is readable at all (used to produce honest coverage
    /// outcomes instead of "scanned" defaults).
    public static func probeRoot(_ root: ScanRoot) -> (readable: Bool, reason: String?) {
        let path = root.url.path
        guard FileManager.default.fileExists(atPath: path) else {
            return (false, NSLocalizedString("coverage.root.missing", comment: ""))
        }
        guard root.granted else {
            return (false, root.notGrantedReason ?? NSLocalizedString("coverage.root.not_granted", comment: ""))
        }
        // A cheap, safe readability probe: list one level. Failures here
        // mean the root must be reported as denied, never as scanned.
        guard let _ = try? FileManager.default.contentsOfDirectory(
            atPath: path
        ) else {
            return (false, NSLocalizedString("coverage.root.unreadable", comment: ""))
        }
        return (true, nil)
    }

    /// Maximum depth guard for pathological trees. The file inventory itself
    /// is bounded by this to protect the scanner.
    public static let maximumTraversalDepth = 64
}
