//
//  TraversalPolicy.swift
//  SalmanMacCleaner
//
//  Filesystem traversal rules for every scan engine. Builds on the central
//  PathSafety policy and adds volume, package, hidden-file and FSEvents
//  boundaries. Protections are only ever added here — never removed.
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
        root: String,
        rootDevice: Int32,
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

        let safe = PathSafety.validate(path: path, root: root, expectedDevice: dev_t(rootDevice), purpose: .scan, allowSymlink: false)
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
            // Never descend into a second mounted volume reached through the tree.
            if let actualDevice = PathSafety.deviceID(of: validated.canonical),
               Int32(clamping: actualDevice) != rootDevice {
                return .skip(reason: .crossVolumeMount)
            }
            return .include
        }
    }

    /// Decide whether a file entry is recorded in inventory.
    public static func shouldRecordFile(
        url: URL,
        root: String,
        rootDevice: Int32,
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

        let safe = PathSafety.validate(path: path, root: root, expectedDevice: dev_t(rootDevice), purpose: .scan, allowSymlink: false)
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

    /// Whether a scan root itself is eligible (volume-level checks).
    public static func validateRoot(url: URL) -> Result<URL, TraversalSkipReason> {
        let path = url.standardizedFileURL.path
        guard FileManager.default.fileExists(atPath: path) else {
            return .failure(.missingFile)
        }
        guard PathSafety.isProtectedRootLocation(path) == false else {
            return .failure(.protectedLocation)
        }
        // Volume roots are permitted for Deep Scan (with explicit opt-in for
        // external volumes handled by the caller).
        return .success(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Maximum depth guard for pathological trees. The file inventory itself
    /// is bounded by this to protect the scanner.
    public static let maximumTraversalDepth = 64
}
