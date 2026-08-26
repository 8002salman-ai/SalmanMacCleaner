//
//  ScanPolicy.swift
//  SalmanMacCleaner
//
//  Maps the four scan modes onto concrete, honest scan roots and rules.
//
//  Root grant model (fixes the "one item scanned" defect):
//  - Home and user-Library roots are always granted (user-owned, sandbox
//    readable) and form the default Deep Scan scope.
//  - Volume roots (startup "/", external drives) are granted only when
//    Full Disk Access is likely available, or the user explicitly opted
//    into the volume; otherwise they are reported as *skipped — not
//    granted* and the coverage report says "Limited".
//  - Security-scoped bookmarked folders are granted roots wherever they
//    live (external drives included).
//  - /Applications is scanned read-only (inventory) only when readable;
//    app bundles themselves are never descended into.
//

import Foundation

public enum ScanRootKind: String, Codable {
    case userHome
    case userLibrary
    case applicationsSystem
    case volumeRoot
    case authorizedFolder
}

/// One granted (or explicitly not-granted) scan root.
public struct ScanRoot: Equatable, Identifiable {
    public var id: String { url.path }
    public var url: URL
    public var kind: ScanRootKind
    /// Whether the scanner may traverse this root.
    public var granted: Bool
    /// Reason shown in the coverage report when not granted.
    public var notGrantedReason: String?
    /// Device group the root may span (system + data volume pair).
    public var expectedDevices: Set<Int32>
    /// Whether entries outside the user home are acceptable (volume roots
    /// and authorized folders).
    public var allowsOutsideHome: Bool
    /// Whether the root itself may sit inside the protected-roots table
    /// (only /Applications).
    public var allowProtectedRoot: Bool
    /// Opportunity roots (e.g. "~/.npm" when the user never used npm) that
    /// simply do not exist are dropped from the requested set instead of
    /// being reported as denied.
    public var optional: Bool

    public init(url: URL,
                kind: ScanRootKind,
                granted: Bool,
                notGrantedReason: String? = nil,
                expectedDevices: Set<Int32> = [],
                allowsOutsideHome: Bool = false,
                allowProtectedRoot: Bool = false,
                optional: Bool = false) {
        self.url = url
        self.kind = kind
        self.granted = granted
        self.notGrantedReason = notGrantedReason
        self.expectedDevices = expectedDevices
        self.allowsOutsideHome = allowsOutsideHome
        self.allowProtectedRoot = allowProtectedRoot
        self.optional = optional
    }

    public static func deviceGroup(for url: URL) -> Set<Int32> {
        var devices: Set<Int32> = []
        if let device = PathSafety.deviceID(of: url.path) {
            devices.insert(Int32(clamping: device))
        }
        return devices
    }
}

public struct ResolvedScanPlan: Equatable {
    public var roots: [ScanRoot]
    public var includeHidden: Bool
    public var includePackageContents: Bool
    public var hashDuplicates: Bool
    public var minFileSize: Int64
    public var minFileAgeDays: Int
    public var collectApps: Bool
    public var collectLeftovers: Bool
    public var collectDuplicates: Bool
    public var collectStorageMap: Bool
    /// Roots whose files classify as SAFE junk (cache/log locations).
    public var libraryRoots: [String]
    /// Roots whose files classify as REVIEW junk (developer caches etc.).
    public var reviewRoots: [String]

    public init(roots: [ScanRoot],
                includeHidden: Bool,
                includePackageContents: Bool,
                hashDuplicates: Bool,
                minFileSize: Int64,
                minFileAgeDays: Int,
                collectApps: Bool,
                collectLeftovers: Bool,
                collectDuplicates: Bool,
                collectStorageMap: Bool,
                libraryRoots: [String],
                reviewRoots: [String]) {
        self.roots = roots
        self.includeHidden = includeHidden
        self.includePackageContents = includePackageContents
        self.hashDuplicates = hashDuplicates
        self.minFileSize = minFileSize
        self.minFileAgeDays = minFileAgeDays
        self.collectApps = collectApps
        self.collectLeftovers = collectLeftovers
        self.collectDuplicates = collectDuplicates
        self.collectStorageMap = collectStorageMap
        self.libraryRoots = libraryRoots
        self.reviewRoots = reviewRoots
    }

    /// Whether any requested root was not granted (limited coverage).
    public var isCoverageLimited: Bool {
        roots.contains { !$0.granted }
    }
}

public enum ScanPolicy {

    /// Deduplicate scan roots: ensure no granted root is a descendant of another
    /// granted root in the same traversal plan to prevent double-counting.
    public static func deduplicateRoots(_ roots: [ScanRoot]) -> [ScanRoot] {
        var result: [ScanRoot] = []
        // Sort by path length ascending so broader roots are evaluated first
        let sorted = roots.sorted { $0.url.path.count < $1.url.path.count }

        for candidate in sorted {
            let candidatePath = candidate.url.standardizedFileURL.path
            // If another already accepted root is granted and contains this candidate, skip candidate
            let alreadyContained = result.contains { existing in
                existing.granted && PathSafety.isPath(candidatePath, inside: existing.url.standardizedFileURL.path)
            }
            if !alreadyContained {
                result.append(candidate)
            }
        }
        return result
    }

    /// Resolve a scan scope into concrete roots and options.
    /// - Parameters:
    ///   - fdaStatus: the probe result from PermissionService.
    ///   - authorizedFolders: security-scoped bookmarked folders.
    public static func resolve(
        scope: ScanScope,
        volumes: [VolumeInfo],
        fdaStatus: FullDiskAccessStatus,
        authorizedFolders: [URL]
    ) -> ResolvedScanPlan {
        let home = PathSafety.userHome

        switch scope.mode {
        case .quick:
            return ResolvedScanPlan(
                roots: deduplicateRoots(quickRoots(home: home)),
                includeHidden: false,
                includePackageContents: false,
                hashDuplicates: false,
                minFileSize: 0,
                minFileAgeDays: 0,
                collectApps: false,
                collectLeftovers: true,
                collectDuplicates: false,
                collectStorageMap: false,
                libraryRoots: quickLibraryRoots(home: home),
                reviewRoots: defaultReviewRoots(home: home)
            )

        case .balanced:
            let combined = quickRoots(home: home) + [homeRoot(home)]
            return ResolvedScanPlan(
                roots: deduplicateRoots(combined),
                includeHidden: false,
                includePackageContents: false,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: true,
                collectLeftovers: true,
                collectDuplicates: true,
                collectStorageMap: false,
                libraryRoots: quickLibraryRoots(home: home),
                reviewRoots: defaultReviewRoots(home: home)
            )

        case .deep:
            var roots: [ScanRoot] = [homeRoot(home)]
            // Volume roots for the selected volumes (startup volume by
            // default). Volume access needs Full Disk Access; without it the
            // root is listed as skipped with an exact reason.
            var selectedVolumes = scope.volumes
            if selectedVolumes.isEmpty, let startup = VolumeDiscoveryService.startupVolume() {
                selectedVolumes = [startup.mountPoint]
            }
            let discoveredByMount = Dictionary(uniqueKeysWithValues: volumes.map { ($0.mountPoint, $0) })
            for mountPoint in selectedVolumes {
                roots.append(volumeRoot(
                    mountPoint: mountPoint,
                    volume: discoveredByMount[mountPoint],
                    home: home,
                    fdaStatus: fdaStatus
                ))
            }
            // /Applications inventory root — read-only, only when readable.
            roots.append(applicationsRoot(fdaStatus: fdaStatus))
            // Security-scoped user authorizations (Desktop, Documents,
            // Downloads, external drives, …).
            for folder in authorizedFolders {
                roots.append(authorizedFolderRoot(folder))
            }
            return ResolvedScanPlan(
                roots: deduplicateRoots(roots),
                includeHidden: true,
                includePackageContents: scope.includePackageContents,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: true,
                collectLeftovers: true,
                collectDuplicates: true,
                collectStorageMap: true,
                libraryRoots: quickLibraryRoots(home: home),
                reviewRoots: defaultReviewRoots(home: home)
            )

        case .custom:
            var roots = scope.explicitRoots.map { authorizedFolderRoot(URL(fileURLWithPath: $0, isDirectory: true)) }
            for folder in authorizedFolders {
                let url = folder.standardizedFileURL
                if !roots.contains(where: { $0.url.path == url.path }) {
                    roots.append(authorizedFolderRoot(url))
                }
            }
            return ResolvedScanPlan(
                roots: deduplicateRoots(roots),
                includeHidden: scope.includeHiddenFiles,
                includePackageContents: scope.includePackageContents,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: false,
                collectLeftovers: false,
                collectDuplicates: scope.hashDuplicates,
                collectStorageMap: true,
                libraryRoots: quickLibraryRoots(home: PathSafety.userHome),
                reviewRoots: defaultReviewRoots(home: PathSafety.userHome)
            )
        }
    }

    // MARK: - Root builders

    /// The user's home: always granted, home-contained.
    public static func homeRoot(_ home: URL) -> ScanRoot {
        ScanRoot(
            url: home,
            kind: .userHome,
            granted: true,
            expectedDevices: ScanRoot.deviceGroup(for: home),
            allowsOutsideHome: false
        )
    }

    /// High-value junk locations covered by Quick Scan. Deliberately
    /// shallow: no broad personal-folder traversal.
    public static func quickRoots(home: URL) -> [ScanRoot] {
        let paths = [
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Logs", isDirectory: true),
            home.appendingPathComponent("Library/Saved Application State", isDirectory: true),
            home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
            home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
            home.appendingPathComponent(".npm", isDirectory: true),
            home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true)
        ]
        return paths.map { url in
            ScanRoot(
                url: url,
                kind: .userLibrary,
                granted: true,
                expectedDevices: ScanRoot.deviceGroup(for: url),
                optional: true
            )
        }
    }

    /// A volume root. Granted only with plausible Full Disk Access or an
    /// explicit volume opt-in; the APFS system + data pair is one device
    /// group so "/" scans reach the data volume.
    public static func volumeRoot(
        mountPoint: String,
        volume: VolumeInfo?,
        home: URL,
        fdaStatus: FullDiskAccessStatus
    ) -> ScanRoot {
        let url = URL(fileURLWithPath: mountPoint, isDirectory: true)
        let fdaAvailable = (fdaStatus == .granted || fdaStatus == .likelyFullAccess)

        let notGrantedReason: String?
        if let volume {
            if !volume.isLocal {
                notGrantedReason = NSLocalizedString("coverage.reason.network_volume", comment: "")
            } else if VolumeDiscoveryService.isTimeMachineVolume(volume) {
                notGrantedReason = NSLocalizedString("coverage.reason.time_machine", comment: "")
            } else if volume.isReadOnly {
                notGrantedReason = NSLocalizedString("coverage.reason.read_only", comment: "")
            } else if !fdaAvailable {
                notGrantedReason = NSLocalizedString("coverage.reason.no_full_disk_access", comment: "")
            } else {
                notGrantedReason = nil
            }
        } else {
            notGrantedReason = NSLocalizedString("coverage.reason.volume_not_discovered", comment: "")
        }

        var devices = ScanRoot.deviceGroup(for: url)
        // APFS: "/" is the sealed system volume; the user's data lives on
        // the data volume. Both devices belong to the same volume group.
        if mountPoint == "/", let dataDevice = PathSafety.deviceID(of: home.path) {
            devices.insert(Int32(clamping: dataDevice))
        }

        return ScanRoot(
            url: url,
            kind: .volumeRoot,
            granted: notGrantedReason == nil,
            notGrantedReason: notGrantedReason,
            expectedDevices: devices,
            allowsOutsideHome: true
        )
    }

    /// /Applications read-only inventory root — only when readable.
    public static func applicationsRoot(fdaStatus: FullDiskAccessStatus) -> ScanRoot {
        let url = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let readable = FileManager.default.isReadableFile(atPath: url.path)
        let notGrantedReason: String?
        if !readable {
            notGrantedReason = NSLocalizedString("coverage.reason.applications_unreadable", comment: "")
        } else if fdaStatus != .granted && fdaStatus != .likelyFullAccess {
            // /Applications is inside a protected root; without FDA the
            // inventory service still discovers names, but full traversal
            // is skipped.
            notGrantedReason = NSLocalizedString("coverage.reason.no_full_disk_access", comment: "")
        } else {
            notGrantedReason = nil
        }
        return ScanRoot(
            url: url,
            kind: .applicationsSystem,
            granted: notGrantedReason == nil,
            notGrantedReason: notGrantedReason,
            expectedDevices: ScanRoot.deviceGroup(for: url),
            allowsOutsideHome: true,
            allowProtectedRoot: true
        )
    }

    /// A security-scoped, user-authorized folder (any volume).
    public static func authorizedFolderRoot(_ url: URL) -> ScanRoot {
        let standardized = url.standardizedFileURL
        return ScanRoot(
            url: standardized,
            kind: .authorizedFolder,
            granted: true,
            expectedDevices: ScanRoot.deviceGroup(for: standardized),
            allowsOutsideHome: true
        )
    }

    // MARK: - Classification root tables

    /// SAFE junk locations (cache/log/saved-state). Files directly under
    /// these roots are eligible for SAFE classification.
    public static func quickLibraryRoots(home: URL) -> [String] {
        [
            home.path + "/Library/Caches",
            home.path + "/Library/Logs",
            home.path + "/Library/Saved Application State",
            home.path + "/Library/Caches/Homebrew",
            home.path + "/Library/Caches/pip",
            home.path + "/Library/Caches/Yarn",
            home.path + "/Library/Caches/pnpm",
            home.path + "/Library/Caches/CocoaPods",
            home.path + "/.npm",
            home.path + "/.cache"
        ]
    }

    /// REVIEW junk locations (developer caches etc.) — never auto-selected.
    public static func defaultReviewRoots(home: URL) -> [String] {
        [
            home.path + "/Library/Developer/Xcode/DerivedData",
            home.path + "/Library/Developer/Xcode/Archives",
            home.path + "/Library/Developer/Xcode/iOS DeviceSupport",
            home.path + "/Library/Developer/CoreSimulator",
            home.path + "/.gradle",
            home.path + "/.m2",
            home.path + "/.cargo",
            home.path + "/Library/org.swift.swiftpm",
            home.path + "/Library/Caches/org.swift.swiftpm"
        ]
    }

    /// Whether a volume may be scanned without additional opt-in.
    public static func volumeNeedsOptIn(_ volume: VolumeInfo) -> Bool {
        volume.requiresOptIn
            || !volume.isLocal
            || !volume.isInternal
            || volume.isReadOnly
            || volume.isRemovable
    }
}
