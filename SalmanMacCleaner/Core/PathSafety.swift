//
//  PathSafety.swift
//  SalmanMacCleaner
//
//  Central path-safety policy used by every scanner and by the cleanup engine.
//  Every path is validated when it is discovered and again immediately before
//  any destructive action (see CleanupEngine.revalidate before trashing).
//

import Foundation

/// Errors raised by the safety layer. Cleanup engines surface these to the UI
/// instead of touching the filesystem.
public enum PathSafetyError: LocalizedError, Equatable {
    case protectedLocation(String)
    case outsideUserHome(String)
    case missingPath(String)
    case ownershipMismatch(uid: uid_t, expected: uid_t)
    case otherUserFile(String)
    case suspiciousLink(String)
    case crossVolumeMount(String)
    case rootFileSystem
    case notRegularFile(String)
    case traversalDetected(String)
    case appBundle(String)

    public var errorDescription: String? {
        switch self {
        case .protectedLocation(let path):
            return NSLocalizedString("error.protected_location", comment: "") + " \(path)"
        case .outsideUserHome(let path):
            return NSLocalizedString("error.outside_home", comment: "") + " \(path)"
        case .missingPath(let path):
            return NSLocalizedString("error.missing_path", comment: "") + " \(path)"
        case .ownershipMismatch(let uid, let expected):
            return String(format: NSLocalizedString("error.ownership_mismatch", comment: ""), uid, expected)
        case .otherUserFile(let path):
            return NSLocalizedString("error.other_user_file", comment: "") + " \(path)"
        case .suspiciousLink(let path):
            return NSLocalizedString("error.suspicious_link", comment: "") + " \(path)"
        case .crossVolumeMount(let path):
            return NSLocalizedString("error.cross_volume", comment: "") + " \(path)"
        case .rootFileSystem:
            return NSLocalizedString("error.root_filesystem", comment: "")
        case .notRegularFile(let path):
            return NSLocalizedString("error.not_regular_file", comment: "") + " \(path)"
        case .traversalDetected(let path):
            return NSLocalizedString("error.traversal", comment: "") + " \(path)"
        case .appBundle(let path):
            return NSLocalizedString("error.app_bundle", comment: "") + " \(path)"
        }
    }
}

/// Describes what a validated path was found to be, so scanners can route
/// regular files, directories and mounts appropriately.
public enum PathKind: Equatable {
    case regularFile
    case directory
    case symlinkToDirectory
    case symlinkToFile
    case volumeMount
    case other
    case missing
}

/// Central, deterministic safety policy for SalmanMacCleaner.
///
/// Policy highlights:
/// - Nothing outside the calling user's home directory is ever touched.
/// - /System, /Library, /private, /usr, /bin, /sbin, /Applications, /Volumes,
///   /Network, /dev, /cores and everything else at the root level is protected.
/// - Desktop, Documents, Downloads, Pictures, Music and Movies are "personal
///   directories": never scanned by default and never cleaned unless the user
///   explicitly opts in to a *specific* subfolder.
/// - Symlinks are never followed during directory traversal. Only explicitly
///   selected symlinks that resolve inside an allowed root are accepted.
/// - Cross-device traversal is rejected so scans never escape onto mounted
///   volumes.
/// - Files owned by other users (including root) are rejected.
/// - App bundles, keychains, passwords, cookies, sessions, browser history,
///   email, messages, photos, personal documents, source repositories,
///   Git metadata, cloud databases, Time Machine backups and VM disks are
///   protected by name/suffix classification.
public enum PathSafety {

    /// Root-level paths that must never be scanned or modified.
    public static let protectedRoots: [String] = [
        "/System", "/Library", "/private", "/usr", "/bin", "/sbin",
        "/Applications", "/Volumes", "/Network", "/dev", "/cores",
        "/opt", "/srv", "/var", "/etc", "/tmp", "/net", "/home", "/mach_kernel"
    ]

    /// Personal directories: excluded from default scans. Explicitly selected
    /// subfolders of these directories remain allowed.
    public static let personalDirectories: [String] = [
        "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"
    ]

    /// Directory names that must never be scanned, anywhere in the tree.
    /// Also applied as path *suffix* components.
    public static let protectedDirectoryNames: Set<String> = [
        "Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies",
        "Public",
        "Library",                          // user Library contents are behind an explicit opt-in, not the default scanner
        "Backups.backupdb", ".TimeMachine", ".TemporaryItems",
        ".git", ".svn", ".hg", ".bzr", ".idea", ".vscode", ".fleet",
        ".Trash", "Trash", ".Trashes",
        ".npm", ".yarn", ".pnpm-store", ".cargo", ".rustup", ".gradle",
        ".m2", ".ivy2", ".pip", ".cache", ".ccache", ".sccache",
        ".jenv", ".nvm", ".rbenv", ".pyenv", ".go", ".sdkman",
        "node_modules", "Pods", ".build", "target", "build", "dist", "out", "coverage",
        "DerivedData", "Archives", "iOS DeviceSupport", "Watch", "tvOS", "visionOS",
        "Caches", "Logs", "Temp", "Saved Application State", "Application Support",
        "Developer", "CoreSimulator", "Carthage", "SourcePackages", "CocoaPods"
    ]

    /// Suffixes / name patterns that are never eligible for cleanup.
    public static let protectedSuffixes: Set<String> = [
        ".app", ".xip", ".pkg", ".dmg", ".sparseimage", ".sparsebundle",
        ".keychain", ".keychain-db",
        ".sqlite", ".sqlite3", ".sqlite-wal", ".sqlite-shm", ".db", ".db3", ".s3db",
        ".ldb", ".leveldb", ".wal", ".journal", "-journal", ".write-ahead-log",
        ".vmdk", ".vdi", ".vhdx", ".qcow2", ".qcow", ".raw", ".img",
        ".iso", ".ova", ".ovf", ".vmwarevm", ".pvm", ".parallels",
        ".ipsw", ".rdm", ".img3", ".dmgpart",
        ".ipa", ".apk", ".aab", ".xip", ".mpkg",
        ".maildir", ".mbox", ".eml", ".olk15", ".pst", ".ost",
        ".exe", ".bat", ".cmd", ".ps1", ".sh", ".zsh", ".bash", ".fish", ".csh", ".ksh", ".command", ".applescript", ".scpt",
        ".xcuserstate", ".xccheckout", ".xcscheme",
        ".xcodeproj", ".xcworkspace", ".playground",
        ".swiftpm", ".git", ".hg", ".svn"
    ]

    /// File names that are always protected (cookies, sessions, history, …).
    public static let protectedFileNames: Set<String> = [
        "Cookies", "Cookies.binarycookies", "Cookies-journal", "Safe Browsing Cookies",
        "History", "History-journal", "Visited Links", "Top Sites", "WebpageIcons.db",
        "Login Data", "Login Data For Account", "Login Data-journal", "Web Data",
        "Local State", "Preferences", "Bookmarks", "Bookmarks.bak", "Favicons",
        "AutofillStrikeDatabase", "WebStorage.sqlite", "Media History",
        "keychain", "login.keychain-db", "metadata.keychain-db", "identity.db",
        "session.json", "Sessions", "LastSession", "Current Session", "Current Tabs",
        "Extension Cookies", "Network Persistent State", "IndexedDB",
        "cloudkit", "CloudKit.sqlite", "cloudd",
        ".DS_Store", ".localized", "Icon\r", "icon\r",
        ".CFUserTextEncoding", ".zprofile", ".zshrc", ".bashrc", ".bash_profile",
        ".profile", ".gitconfig", ".git-credentials", ".netrc", ".ssh", ".gnupg",
        ".aws", ".azure", ".config", ".kube", ".docker", ".npmrc", ".yarnrc",
        "desktop.ini", "Thumbs.db", "NTUSER.DAT"
    ]

    /// Internal (very small) allow-list of throwaway contents that are safe to
    /// remove when the user has explicitly selected a folder. Everything else
    /// under an explicitly selected folder must match the folder's own policy
    /// (see `ValidatePolicy.purpose`).
    public static let protectedHiddenFiles: Set<String> = [
        ".DS_Store", ".localized", ".com.apple.timemachine.donotpresent", "Icon\r", "icon\r"
    ]

    /// Volume roots (filesystem boundaries) discovered during traversal.
    public static let volumeRootIndicators: Set<String> = [
        ".VolumeIcon.icns", ".hidden", ".HFS+ Private Directory Data\r"
    ]

    /// Real user home of the calling process. Tests can install a fake home.
    public static var userHome: URL {
        let base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return base.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Real user id of the calling process. Tests can install a fake uid.
    public static var currentUID: uid_t = getuid()

    // MARK: - Root classification

    /// True when `path` (resolved, standardized) is inside the user home.
    public static func isInsideUserHome(_ path: String) -> Bool {
        let home = userHome.path
        if path == home { return true }
        return path.hasPrefix(home + "/")
    }

    /// True when `path` equals or lies under one of the root-level protected locations.
    public static func isProtectedRootLocation(_ path: String) -> Bool {
        let normalized = path.hasSuffix("/") && path != "/" ? String(path.dropLast()) : path
        for root in protectedRoots {
            if normalized == root || normalized.hasPrefix(root + "/") {
                return true
            }
        }
        return false
    }

    /// True when `path` (as standardized components) contains a protected
    /// directory name anywhere in its components.
    public static func containsProtectedComponent(_ path: String) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        for component in components where component != "" {
            if protectedDirectoryNames.contains(component) { return true }
        }
        return false
    }

    /// True when the final component of `path` is one of the personal
    /// directories (Desktop, Documents, …) — i.e. the directory itself.
    public static func isPersonalDirectory(_ path: String) -> Bool {
        let last = (path as NSString).lastPathComponent
        return personalDirectories.contains(last)
    }

    /// True when `path` is inside one of the personal directories.
    public static func isInsidePersonalDirectory(_ path: String) -> Bool {
        let home = userHome.path
        for personal in personalDirectories {
            let personalPath = home + "/" + personal
            if path == personalPath || path.hasPrefix(personalPath + "/") {
                return true
            }
        }
        return false
    }

    /// Classification of the last path component against protected file names
    /// and suffixes. `purpose` lets callers decide how strict the check must be
    /// (e.g. the developer-cache scanner allows `.json` metadata files, the
    /// trash engine does not).
    public static func isProtectedFile(name: String, purpose: FilePurpose) -> Bool {
        if protectedFileNames.contains(name) { return true }
        if name.hasPrefix(".git") { return true }

        let lower = name.lowercased()
        if protectedSuffixes.contains(where: { lower.hasSuffix($0) }) { return true }
        if lower.contains("keychain") || lower.contains("password") { return true }
        if lower.contains("cookies") || lower.contains("session") || lower.contains("history") {
            return true
        }

        switch purpose {
        case .scan:
            return false
        case .explicitDeveloperCache:
            if protectedHiddenFiles.contains(name) { return true }
            return false
        case .cleanup:
            return false
        }
    }

    /// The purpose of a validation decides which classifications apply.
    public enum FilePurpose {
        case scan
        case explicitDeveloperCache
        case cleanup
    }

    // MARK: - Validation

    /// Resolve the canonical path of a candidate without following its final
    /// symlink. Returns nil when the path does not exist. This is the one
    /// place symlink resolution is performed, and it never traverses a link
    /// chain that escapes the containment root.
    public static func canonicalPathResolvingParent(of path: String) -> String? {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let parent = url.deletingLastPathComponent()
        guard let resolvedParent = canonicalRealPath(of: parent.path) else { return nil }
        let name = (path as NSString).lastPathComponent
        return resolvedParent + "/" + name
    }

    /// Fully canonical path (all symlinks resolved) or nil when missing.
    public static func canonicalRealPath(of path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard let cString = path.cString(using: .utf8) else { return nil }
        guard realpath(cString, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    /// Resolve the *target* of a symlink, if `path` is one, without touching
    /// the rest of the chain.
    public static func symlinkTarget(of path: String) -> String? {
        let maxSize = Int(PATH_MAX)
        var buffer = [CChar](repeating: 0, count: maxSize)
        let length = readlink(path, &buffer, maxSize - 1)
        guard length > 0 else { return nil }
        buffer[Int(length)] = 0
        return String(cString: buffer)
    }

    /// Classify a path without resolving symlinks (lstat semantics).
    public static func kind(of path: String) -> PathKind {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return .missing }
        let mode = statBuffer.st_mode
        let type = mode & S_IFMT
        switch type {
        case S_IFREG: return .regularFile
        case S_IFDIR: return .directory
        case S_IFLNK:
            // Determine what the link points at (best effort, non-recursive).
            guard let target = symlinkTarget(of: path) else { return .other }
            let targetURL: URL
            if target.hasPrefix("/") {
                targetURL = URL(fileURLWithPath: target, isDirectory: true)
            } else {
                targetURL = URL(fileURLWithPath: (path as NSString).deletingLastPathComponent)
                    .appendingPathComponent(target)
            }
            var targetStat = stat()
            guard stat(targetURL.path, &targetStat) == 0 else { return .symlinkToFile }
            if (targetStat.st_mode & S_IFMT) == S_IFDIR {
                return .symlinkToDirectory
            }
            return .symlinkToFile
        case S_IFBLK: return .volumeMount
        case S_IFCHR: return .other
        default: return .other
        }
    }

    /// True when `path` is a mount point or resides on a different device than
    /// its expected device id (guards against escaping onto mounted volumes).
    public static func deviceID(of path: String) -> dev_t? {
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0 else { return nil }
        return statBuffer.st_dev
    }

    /// Owns a file? Compares st_uid with the calling user (or the injected
    /// test uid). Missing files are treated as owned by nobody (caller decides).
    public static func uid(of path: String) -> uid_t? {
        var statBuffer = stat()
        guard lstat(path, &statBuffer) == 0 else { return nil }
        return statBuffer.st_uid
    }

    /// True when `path` is owned by the calling user.
    public static func isOwnedByCurrentUser(_ path: String) -> Bool {
        guard let owner = uid(of: path) else { return false }
        return owner == currentUID
    }

    /// True when the path is a macOS application bundle.
    public static func isAppBundle(_ path: String) -> Bool {
        guard (path as NSString).pathExtension.lowercased() == "app" else { return false }
        return kind(of: path) == .directory
    }

    // MARK: - Containment

    /// Whether `path` is `root` or a descendant of it (both standardized).
    public static func isPath(_ path: String, inside root: String) -> Bool {
        let normalizedRoot = root.hasSuffix("/") ? String(root.dropLast()) : root
        let normalizedPath = path.hasSuffix("/") ? String(path.dropLast()) : path
        if normalizedPath == normalizedRoot { return true }
        return normalizedPath.hasPrefix(normalizedRoot + "/")
    }

    /// Whether `path` is a *strict* descendant of `root`.
    public static func isStrictDescendant(of path: String, root: String) -> Bool {
        return isPath(path, inside: root) && path != root
    }

    /// Detect a traversal attempt: a path whose lexical form would escape
    /// `root` (.. components, absolute redirection, etc.).
    public static func hasTraversal(_ path: String, root: String) -> Bool {
        let url = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        let candidate = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let rootComponents = url.pathComponents
        let candidateComponents = candidate.pathComponents
        guard candidateComponents.count >= rootComponents.count else { return true }
        for (index, component) in rootComponents.enumerated() {
            if candidateComponents[index] != component { return true }
        }
        return false
    }

    /// Validate a candidate path against `root`. Applies, in order:
    /// existence, lexical containment, parent-symlink canonicalization,
    /// symlink target containment, user-home containment, protected roots,
    /// ownership and (optionally) mount/device checks.
    public static func validate(
        path: String,
        root: String,
        expectedDevice: dev_t? = nil,
        purpose: FilePurpose = .scan,
        allowSymlink: Bool = false
    ) -> Result<ValidatedPath, PathSafetyError> {
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path

        // 1. Lexical containment (traversal detection).
        guard isPath(candidate, inside: root) else {
            return .failure(.traversalDetected(candidate))
        }

        // 2. Existence (resolving parent symlinks but never the leaf).
        guard let canonicalLeaf = canonicalPathResolvingParent(of: candidate),
              FileManager.default.fileExists(atPath: canonicalLeaf) else {
            return .failure(.missingPath(candidate))
        }
        let canonical = URL(fileURLWithPath: canonicalLeaf).standardizedFileURL.path
        guard isPath(canonical, inside: root) else {
            return .failure(.traversalDetected(canonical))
        }

        // 3. Symlink policy.
        let leafIsSymlink = (kind(of: canonicalLeaf) == .symlinkToFile || kind(of: canonicalLeaf) == .symlinkToDirectory)
        if leafIsSymlink && !allowSymlink {
            return .failure(.suspiciousLink(canonicalLeaf))
        }
        if leafIsSymlink {
            guard let resolved = canonicalRealPath(of: canonicalLeaf),
                  isPath(resolved, inside: root) else {
                return .failure(.suspiciousLink(canonicalLeaf))
            }
        }

        // 4. User-home containment (nothing outside the home, ever).
        guard isInsideUserHome(canonical) else {
            return .failure(.outsideUserHome(canonical))
        }

        // 5. Protected root locations (defense in depth for the home check).
        guard !isProtectedRootLocation(canonical) else {
            return .failure(.protectedLocation(canonical))
        }

        // 6. Ownership: other-user files (including root) are rejected.
        guard let owner = uid(of: canonicalLeaf) else {
            return .failure(.missingPath(canonicalLeaf))
        }
        guard owner == currentUID else {
            return .failure(.ownershipMismatch(uid: owner, expected: currentUID))
        }

        // 7. Device boundary: never cross onto a mounted volume.
        if let expected = expectedDevice, let actual = deviceID(of: canonicalLeaf), actual != expected {
            return .failure(.crossVolumeMount(canonicalLeaf))
        }

        return .success(ValidatedPath(
            candidate: candidate,
            canonical: canonical,
            kind: kind(of: canonicalLeaf),
            isSymlink: leafIsSymlink
        ))
    }

    /// The result of a successful validation.
    public struct ValidatedPath: Equatable {
        public let candidate: String
        public let canonical: String
        public let kind: PathKind
        public let isSymlink: Bool

        public var url: URL { URL(fileURLWithPath: canonical, isDirectory: kind == .directory || kind == .symlinkToDirectory) }
    }
}
