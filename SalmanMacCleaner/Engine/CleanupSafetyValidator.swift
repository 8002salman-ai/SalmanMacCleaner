//
//  CleanupSafetyValidator.swift
//  SalmanMacCleaner
//
//  Per-item pre-action validation. Rechecks every guard immediately before
//  the executor acts: canonicalization, traversal, symlink changes,
//  ownership, volume, file identity, protected names, running apps and the
//  allowlist rule.
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
        }
    }
}

public enum CleanupSafetyValidator {

    /// Validate one planned item right before execution.
    public static func validate(
        item: PlannedCleanupItem,
        allowBundles: Bool,
        libraryRoots: [String] = [],
        reviewRoots: [String] = []
    ) -> Result<PlannedCleanupItem, ValidationFailure> {
        guard item.action.isAvailable else {
            return .failure(.unsafe(item.path))
        }

        // 1. Path safety (canonicalization, containment, symlink rejection).
        let result = PathSafety.validate(
            path: item.path,
            root: item.containmentRoot,
            purpose: .cleanup,
            allowSymlink: false
        )
        guard case .success(let validated) = result else {
            return .failure(.unsafe(item.path))
        }
        guard !validated.isSymlink else {
            return .failure(.pathChanged(item.path))
        }

        // 2. Recheck ownership.
        guard let owner = PathSafety.uid(of: validated.canonical),
              owner == item.expectedOwner else {
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

        // 5. Recheck protected names/suffixes.
        let name = (validated.canonical as NSString).lastPathComponent
        guard !PathSafety.isProtectedFile(name: name, purpose: .cleanup) else {
            return .failure(.protectedName(item.path))
        }

        // 6. Recheck app-bundle / running-app state.
        if PathSafety.isAppBundle(validated.canonical) {
            guard allowBundles else {
                return .failure(.protectedName(item.path))
            }
            guard !CleanupEngine.isAppRunning(bundlePath: validated.canonical) else {
                return .failure(.runningApp(item.path))
            }
        }

        // 7. Recheck the allowlist rule: the item must still classify as
        //    non-protected under the current tree state.
        guard let record = MetadataCollector.collect(url: URL(fileURLWithPath: validated.canonical, isDirectory: validated.kind == .directory)) else {
            return .failure(.missing(item.path))
        }
        let verdict = JunkClassifier.classify(record, libraryRoots: libraryRoots, reviewRoots: reviewRoots)
        guard verdict.safety != .protected else {
            return .failure(.protectedName(item.path))
        }

        return .success(item)
    }
}
