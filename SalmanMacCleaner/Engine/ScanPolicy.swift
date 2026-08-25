//
//  ScanPolicy.swift
//  SalmanMacCleaner
//
//  Maps the four scan modes onto concrete, honest scan roots and rules.
//  Personal folders are never traversed by default; external/network/cloud
//  volumes require explicit opt-in.
//

import Foundation

public struct ResolvedScanPlan: Equatable {
    public var roots: [URL]
    public var includeHidden: Bool
    public var includePackageContents: Bool
    public var hashDuplicates: Bool
    public var minFileSize: Int64
    public var minFileAgeDays: Int
    public var collectApps: Bool
    public var collectLeftovers: Bool
    public var collectDuplicates: Bool
    public var collectStorageMap: Bool

    public init(roots: [URL],
                includeHidden: Bool,
                includePackageContents: Bool,
                hashDuplicates: Bool,
                minFileSize: Int64,
                minFileAgeDays: Int,
                collectApps: Bool,
                collectLeftovers: Bool,
                collectDuplicates: Bool,
                collectStorageMap: Bool) {
        self.roots = roots
        self.includeHidden = includeHidden
        self.includePackageContents = includePackageContents
        self.hashDuplicates = hashDuplicates
        self.minFileSize = minFileSize
        self.minFileAgeDays = minFileAge
        self.collectApps = collectApps
        self.collectLeftovers = collectLeftovers
        self.collectDuplicates = collectDuplicates
        self.collectStorageMap = collectStorageMap
    }
}

public enum ScanPolicy {

    /// Resolve a scan scope into concrete roots and options.
    public static func resolve(scope: ScanScope, volumes: [VolumeInfo]) -> ResolvedScanPlan {
        let home = PathSafety.userHome

        switch scope.mode {
        case .quick:
            return ResolvedScanPlan(
                roots: quickRoots(home: home),
                includeHidden: false,
                includePackageContents: false,
                hashDuplicates: false,
                minFileSize: 0,
                minFileAgeDays: 0,
                collectApps: false,
                collectLeftovers: true,
                collectDuplicates: false,
                collectStorageMap: false
            )

        case .balanced:
            return ResolvedScanPlan(
                roots: quickRoots(home: home) + [home.appendingPathComponent("Library", isDirectory: true)],
                includeHidden: false,
                includePackageContents: false,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: true,
                collectLeftovers: true,
                collectDuplicates: true,
                collectStorageMap: false
            )

        case .deep:
            var roots = scope.volumes.map { URL(fileURLWithPath: $0, isDirectory: true) }
            if roots.isEmpty {
                if let startup = VolumeDiscoveryService.startupVolume() {
                    roots = [URL(fileURLWithPath: startup.mountPoint, isDirectory: true)]
                }
            }
            return ResolvedScanPlan(
                roots: roots,
                includeHidden: true,
                includePackageContents: scope.includePackageContents,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: true,
                collectLeftovers: true,
                collectDuplicates: true,
                collectStorageMap: true
            )

        case .custom:
            let roots = scope.explicitRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
            return ResolvedScanPlan(
                roots: roots,
                includeHidden: scope.includeHiddenFiles,
                includePackageContents: scope.includePackageContents,
                hashDuplicates: scope.hashDuplicates,
                minFileSize: scope.minFileSize,
                minFileAgeDays: scope.minFileAgeDays,
                collectApps: false,
                collectLeftovers: false,
                collectDuplicates: scope.hashDuplicates,
                collectStorageMap: true
            )
        }
    }

    /// High-value junk locations covered by Quick Scan. Deliberately shallow:
    /// no broad personal-folder traversal.
    private static func quickRoots(home: URL) -> [URL] {
        [
            home.appendingPathComponent("Library/Caches", isDirectory: true),
            home.appendingPathComponent("Library/Logs", isDirectory: true),
            home.appendingPathComponent("Library/Saved Application State", isDirectory: true),
            home.appendingPathComponent(".npm", isDirectory: true),
            home.appendingPathComponent("Library/Caches/Homebrew", isDirectory: true),
            home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true)
        ]
    }

    /// Whether a volume may be scanned without additional opt-in.
    public static func volumeNeedsOptIn(_ volume: VolumeInfo) -> Bool {
        volume.requiresOptIn
    }
}
