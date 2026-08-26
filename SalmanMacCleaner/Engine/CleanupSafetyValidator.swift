//
//  CleanupSafetyValidator.swift
//  SalmanMacCleaner
//
//  Per-item pre-action validation. Rechecks every guard immediately before
//  the executor acts: canonicalization, traversal, symlink changes,
//  ownership, volume, file identity, protected names, running apps, system
//  apps and the allowlist rule.
//
//  Authorized roots: the uninstaller flow grants exactly one path — the
//  bundle the user picked. That grant waives *only* the user-home
//  containment rule and the protected-root table entry for that path.
//  Symlink, ownership, device, identity, running-app and system-app guards
//  still apply, and nothing outside the grant is affected.
//

import Foundation
import AppKit

public enum ValidationFailure: LocalizedError, Equatable {
    case pathChanged(String)
    case ownershipChanged(String)
    case volumeChanged(String)
    case identityChanged(String)
    case protectedName(String)
    case runningApp(String)
    case missing(String)
    case unsafe(String)
    case symlink(String)
    case unsupportedKind(String)
    /// Carries the exact reason from the underlying path-safety policy.
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .pathChanged(let p): return NSLocalizedString("validate.failure.path_changed", comment: "") + " \(p)"
        case .ownershipChanged(let p): return NSLocalizedString("validate.failure.ownership", comment: "") + " \(p)"
        case .volumeChanged(let p): return NSLocalizedString("validate.failure.volume", comment: "") + " \(p)"
        case .identityChanged(let p): return NSLocalizedString("validate.failure.identity", comment: "") + " \(p)"
        case .protectedName(let p): return NSLocalizedString("validate.failure.protected", comment: "") + " \(p)"
        case .runningApp(let p): return NSLocalizedString("validate.failure.running", comment: "") + " \(p)"
        case .missing(let p): return NSLocalizedString("validate.failure.missing", comment: "") + " \(p)"
        case .unsafe(let p): return NSLocalizedString("validate.failure.unsafe", comment: "") + " \(p)"
        case .symlink(let p): return NSLocalizedString("cleanup.error.symlink", comment: "") + " \(p)"
        case .unsupportedKind(let p): return NSLocalizedString("cleanup.error.kind", comment: "") + " \(p)"
        case .rejected(let reason): return reason
        }
    }
}

public enum CleanupSafetyValidator {

    /// Bundles shipped with macOS. Never offered, never removed.
    public static func isSystemBundle(_ path: String) -> Bool {
        path == "/System" || path.hasPrefix("/System/")
    }

    /// Validate one planned item right before execution.
    ///
    /// - Parameters:
    ///   - authorizedRoots: paths the user explicitly authorized (the
    ///     uninstaller passes the selected bundle path). An item inside an
    ///     authorized root may live outside the home directory and inside a
    ///     protected-root table entry — nothing else changes.
    public static func validate(
        item: PlannedCleanupItem,
        allowBundles: Bool,
        libraryRoots: [String] = [],
        reviewRoots: [String] = [],
        authorizedRoots: [String] = []
    ) -> Result<PlannedCleanupItem, ValidationFailure> {
        guard item.action.isAvailable else {
            return .failure(.unsafe(item.path))
        }

        let candidate = URL(fileURLWithPath: item.path).standardizedFileURL.path
        let isAuthorized = authorizedRoots.contains { PathSafety.isPath(candidate, inside: $0) }

        // 1. Path safety (canonicalization, containment, symlink rejection).
        let validated: PathSafety.ValidatedPath
        switch PathSafety.validate(
            path: item.path,
            root: item.containmentRoot,
            purpose: .cleanup,
            allowSymlink: false,
            allowOutsideHome: isAuthorized,
            allowProtectedRoot: isAuthorized
        ) {
        case .failure(let error):
            return .failure(.rejected(error.errorDescription ?? item.path))
        case .success(let value):
            validated = value
        }
        guard !validated.isSymlink else {
            return .failure(.symlink(item.path))
        }
        guard validated.kind == .regularFile || validated.kind == .directory else {
            return .failure(.unsupportedKind(item.path))
        }
        if validated.kind == .regularFile,
           let linkCount = Crypto.linkCount(of: validated.canonical),
           linkCount > 1 {
            return .failure(.rejected(
                NSLocalizedString("cleanup.error.hard_link_selection", comment: "") + " \(validated.canonical)"
            ))
        }

        // 2. Recheck ownership.
        guard let owner = PathSafety.uid(of: validated.canonical),
              owner == item.expectedOwner,
              owner == PathSafety.currentUID else {
            return .failure(.ownershipChanged(item.path))
        }

        // 3. Recheck volume.
        if let device = PathSafety.deviceID(of: validated.canonical),
           item.expectedDevice != 0,
           Int32(clamping: device) != item.expectedDevice {
            return .failure(.volumeChanged(item.path))
        }

        // 4. Recheck file identity (inode).
        if item.expectedInode != 0 {
            guard let identity = Crypto.inode(of: validated.canonical) else {
                return .failure(.missing(item.path))
            }
            guard UInt64(identity.1) == item.expectedInode else {
                return .failure(.identityChanged(item.path))
            }
        }

        // 5. Recheck app-bundle / running-app / system-app state.
        let isBundle = PathSafety.isAppBundle(validated.canonical)
        // The uninstaller's narrow grant covers the bundle the user picked;
        // it never widens to bundle contents or to any other path.
        let authorizedBundle = isBundle && allowBundles && isAuthorized
        if isBundle {
            guard allowBundles else {
                return .failure(.protectedName(item.path))
            }
            guard !isSystemBundle(validated.canonical) else {
                return .failure(.protectedName(item.path))
            }
            guard !CleanupEngine.isAppRunning(bundlePath: validated.canonical) else {
                return .failure(.runningApp(item.path))
            }
        }

        // 6. Recheck protected names/suffixes. Skipped only for the bundle the
        //    user explicitly authorized for uninstall.
        if !authorizedBundle {
            let name = (validated.canonical as NSString).lastPathComponent
            guard !PathSafety.isProtectedFile(name: name, purpose: .cleanup) else {
                return .failure(.protectedName(item.path))
            }
        }

        // 7. Recheck the allowlist rule: the item must still classify as
        //    non-protected under the current tree state.
        if !authorizedBundle {
            guard let record = MetadataCollector.collect(
                url: URL(fileURLWithPath: validated.canonical, isDirectory: validated.kind == .directory)
            ) else {
                return .failure(.missing(item.path))
            }
            let verdict = JunkClassifier.classify(record, libraryRoots: libraryRoots, reviewRoots: reviewRoots)
            let preservesPlannedCacheReview = libraryRoots.isEmpty
                && verdict.safety == .protected
                && item.category == .userCache
                && item.safety != .protected
                && isCacheLikePath(validated.canonical)
            guard verdict.safety != .protected || preservesPlannedCacheReview else {
                return .failure(.protectedName(item.path))
            }
        }

        return .success(item)
    }

    private static func isCacheLikePath(_ path: String) -> Bool {
        let components = URL(fileURLWithPath: path).pathComponents.dropLast()
        return components.contains { $0.caseInsensitiveCompare("Caches") == .orderedSame }
    }
}
