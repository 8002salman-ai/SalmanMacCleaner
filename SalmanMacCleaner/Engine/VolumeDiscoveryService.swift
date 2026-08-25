//
//  VolumeDiscoveryService.swift
//  SalmanMacCleaner
//
//  Discovers mounted volumes via supported Foundation APIs. External,
//  network, cloud-mounted and Time Machine volumes always require explicit
//  user opt-in before scanning.
//

import Foundation
import Darwin

public enum VolumeDiscoveryService {

    /// Keys prefetched for every mounted volume.
    public static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey, .volumeLocalizedNameKey,
        .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsReadOnlyKey,
        .volumeIsBrowsableKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
        .volumeTotalCapacityKey, .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityForOpportunisticUsageKey,
        .volumeIsRootFileSystemKey, .volumeIsAutomountedKey
    ]

    /// Enumerate all mounted volumes. Network shares are included in the list
    /// (so the user can see them) but marked `requiresOptIn`.
    public static func discoverVolumes() -> [VolumeInfo] {
        guard let mounts = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) else {
            return []
        }

        var volumes: [VolumeInfo] = []
        for mount in mounts {
            guard let values = try? mount.resourceValues(forKeys: Set(resourceKeys)) else { continue }
            let path = mount.standardizedFileURL.path

            let isLocal = values.volumeIsLocal ?? true
            let isInternal = values.volumeIsInternal ?? false
            let isRemovable = values.volumeIsRemovable ?? false
            let isReadOnly = values.volumeIsReadOnly ?? false
            let isRoot = values.volumeIsRootFileSystem ?? false
            let isAutomounted = values.volumeIsAutomounted ?? false
            let fileSystem = fileSystemType(at: path)

            let total = Int64(values.volumeTotalCapacity ?? 0)
            let available = Int64(values.volumeAvailableCapacity ?? 0)
            let important = Int64(values.volumeAvailableCapacityForImportantUsage ?? available)
            let opportunistic = Int64(values.volumeAvailableCapacityForOpportunisticUsage ?? important)
            let purgeable = max(available - opportunistic, 0)
            let used = max(total - available, 0)

            // Network/cloud shares: volumeIsLocal == false. Time Machine
            // destinations and read-only images also require opt-in.
            let requiresOptIn = !isLocal || isReadOnly || (!isInternal && isRemovable) || isAutomounted
            let name = values.volumeName ?? (path == "/" ? NSLocalizedString("volume.startup", comment: "") : mount.lastPathComponent)

            volumes.append(VolumeInfo(
                id: path,
                name: name,
                mountPoint: path,
                fileSystemType: fileSystem,
                isInternal: isInternal,
                isLocal: isLocal,
                isRemovable: isRemovable,
                isReadOnly: isReadOnly,
                isRoot: isRoot,
                totalCapacity: total,
                available: available,
                used: used,
                purgeableEstimate: purgeable,
                requiresOptIn: requiresOptIn
            ))
        }

        // Startup volume first, then by name.
        volumes.sort {
            if $0.isRoot != $1.isRoot { return $0.isRoot }
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return volumes
    }

    /// The default scan root: the startup (data) volume.
    public static func startupVolume() -> VolumeInfo? {
        discoverVolumes().first { $0.isRoot || $0.mountPoint == "/" }
            ?? discoverVolumes().first { $0.isInternal }
    }

    /// File-system type via statfs(2) — no shell, no sudo.
    public static func fileSystemType(at path: String) -> String {
        var buffer = statfs()
        guard statfs(path, &buffer) == 0 else { return "unknown" }
        return withUnsafeBytes(of: &buffer.f_fstypename) { raw in
            let bytes = raw.bindMemory(to: CChar.self)
            return String(cString: bytes.baseAddress!)
        }
    }

    /// Whether a path lives on the Time Machine backup destination.
    public static func isTimeMachineVolume(_ volume: VolumeInfo) -> Bool {
        volume.name.localizedCaseInsensitiveContains("time machine")
            || volume.mountPoint.contains("Backups.backupdb")
    }

    /// The device identifier for a volume root (used for identity checks).
    public static func deviceID(ofMountPoint path: String) -> Int32? {
        var statBuffer = stat()
        guard stat(path, &statBuffer) == 0 else { return nil }
        return Int32(clamping: statBuffer.st_dev)
    }

    /// Human-friendly classification of a volume for the UI.
    public static func classification(_ volume: VolumeInfo) -> String {
        if volume.isRoot { return NSLocalizedString("volume.kind.startup", comment: "") }
        if !volume.isLocal { return NSLocalizedString("volume.kind.network", comment: "") }
        if volume.isReadOnly { return NSLocalizedString("volume.kind.readonly", comment: "") }
        if volume.isRemovable { return NSLocalizedString("volume.kind.external", comment: "") }
        return NSLocalizedString("volume.kind.other", comment: "")
    }
}
