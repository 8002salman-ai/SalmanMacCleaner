//
//  PermissionService.swift
//  SalmanMacCleaner
//
//  Full Disk Access onboarding and probing. macOS has no direct public
//  authorization-status API, so the probe reads known TCC-protected test
//  locations and reports carefully worded results. The app can never grant
//  itself permission — the user must do it in System Settings.
//

import Foundation
import AppKit
import Combine

public enum FullDiskAccessStatus: String, Equatable, Codable, CaseIterable {
    /// Full Disk Access granted: known TCC-protected locations are readable.
    case granted
    /// User library and standard caches are accessible, but TCC-protected roots are denied.
    case limited
    /// Only specific selected/sandbox folders are accessible; user library is unreadable.
    case folderOnly
    /// Standard user roots and protected locations are denied/unreadable.
    case denied
    /// Probe locations do not exist or results could not be determined.
    case unknown

    // Compatibility aliases
    public static let likelyFullAccess = FullDiskAccessStatus.granted
    public static let limitedAccess = FullDiskAccessStatus.limited
    public static let notDetermined = FullDiskAccessStatus.unknown
    public static let accessDenied = FullDiskAccessStatus.denied

    public var title: String {
        switch self {
        case .granted: return NSLocalizedString("fda.status.granted", comment: "")
        case .limited: return NSLocalizedString("fda.status.limited", comment: "")
        case .folderOnly: return NSLocalizedString("fda.status.folder_only", comment: "")
        case .denied: return NSLocalizedString("fda.status.denied", comment: "")
        case .unknown: return NSLocalizedString("fda.status.unknown", comment: "")
        }
    }

    public var explanation: String {
        switch self {
        case .granted:
            return NSLocalizedString("fda.explanation.granted", comment: "")
        case .limited:
            return NSLocalizedString("fda.explanation.limited", comment: "")
        case .folderOnly:
            return NSLocalizedString("fda.explanation.folder_only", comment: "")
        case .denied:
            return NSLocalizedString("fda.explanation.denied", comment: "")
        case .unknown:
            return NSLocalizedString("fda.explanation.unknown", comment: "")
        }
    }
}

public struct PermissionSnapshot: Equatable {
    public var fullDiskAccess: FullDiskAccessStatus
    public var lastCheck: Date
    public var coverageImpact: String
    public var accessibleRoots: [String]
    public var inaccessibleRoots: [String]
    public var requiresRestart: Bool

    public init(
        fullDiskAccess: FullDiskAccessStatus,
        lastCheck: Date,
        coverageImpact: String,
        accessibleRoots: [String] = [],
        inaccessibleRoots: [String] = [],
        requiresRestart: Bool = false
    ) {
        self.fullDiskAccess = fullDiskAccess
        self.lastCheck = lastCheck
        self.coverageImpact = coverageImpact
        self.accessibleRoots = accessibleRoots
        self.inaccessibleRoots = inaccessibleRoots
        self.requiresRestart = requiresRestart
    }
}

@MainActor
public final class PermissionService: ObservableObject {

    @Published public private(set) var snapshot: PermissionSnapshot
    public static let shared = PermissionService()

    private var activeObserver: Any?

    /// Known TCC-protected candidate locations. Readability of these indicates
    /// Full Disk Access has been granted by the user.
    public static let tccProbeLocations: [String] = [
        "~/Library/Safari",
        "~/Library/Safari/Bookmarks.plist",
        "~/Library/Safari/CloudTabs.db",
        "~/Library/Safari/History.db",
        "~/Library/Messages",
        "~/Library/Messages/chat.db",
        "~/Library/Mail",
        "~/Library/Suggestions",
        "~/Library/PersonalizationPortrait"
    ]

    /// Standard user roots to distinguish Limited from Denied or Folder-only.
    public static let standardUserRoots: [String] = [
        "~",
        "~/Library",
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Application Support"
    ]

    /// Key diagnostic roots tracked in the accessible/inaccessible summary.
    public static let diagnosticRoots: [String] = [
        "~/Library/Safari",
        "~/Library/Messages",
        "~/Library/Mail",
        "~/Library/Caches",
        "~/Library/Logs",
        "~/Library/Application Support",
        "/Applications"
    ]

    public init() {
        self.snapshot = Self.probeSnapshot()

        self.activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recheck()
        }
    }

    deinit {
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// Probe whether a path exists and is readable without modifying anything.
    public static func probePath(_ rawPath: String) -> (exists: Bool, readable: Bool) {
        let path = expandTilde(rawPath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return (false, false)
        }
        if isDir.boolValue {
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return (true, true)
            } catch {
                return (true, false)
            }
        } else {
            if let handle = FileHandle(forReadingAtPath: path) {
                defer { try? handle.close() }
                do {
                    _ = try handle.read(upToCount: 32)
                    return (true, true)
                } catch {
                    return (true, false)
                }
            }
            if FileManager.default.contents(atPath: path) != nil {
                // A non-nil result is a successful read, including an empty
                // file; emptiness is not an access signal.
                return (true, true)
            }
            return (true, false)
        }
    }

    /// Run full non-destructive probe and return fresh snapshot.
    public static func probeSnapshot() -> PermissionSnapshot {
        var accessible: [String] = []
        var inaccessible: [String] = []

        var tccExisted = 0
        var tccReadable = 0

        for rawPath in tccProbeLocations {
            let res = probePath(rawPath)
            if res.exists {
                tccExisted += 1
                if res.readable {
                    tccReadable += 1
                }
            }
        }

        var standardExisted = 0
        var standardReadable = 0

        for rawPath in standardUserRoots {
            let res = probePath(rawPath)
            if res.exists {
                standardExisted += 1
                if res.readable {
                    standardReadable += 1
                }
            }
        }

        for rawPath in diagnosticRoots {
            let res = probePath(rawPath)
            let expanded = expandTilde(rawPath)
            if res.exists {
                if res.readable {
                    if !accessible.contains(expanded) {
                        accessible.append(expanded)
                    }
                } else {
                    if !inaccessible.contains(expanded) {
                        inaccessible.append(expanded)
                    }
                }
            }
        }

        let status: FullDiskAccessStatus
        if tccReadable > 0 {
            // A readable existing TCC-protected probe is the only positive
            // signal available to a sandboxed app; never infer FDA merely
            // from ordinary Library access.
            status = .granted
        } else if tccExisted > 0 {
            if standardReadable == 0 {
                status = .denied
            } else if standardReadable == standardExisted {
                status = .limited
            } else {
                status = .folderOnly
            }
        } else if standardReadable > 0 {
            // No known protected probe exists on this account. The honest
            // answer is unknown, not a fabricated limited/granted state.
            status = .unknown
        } else if standardExisted > 0 {
            status = .denied
        } else {
            status = .unknown
        }

        return PermissionSnapshot(
            fullDiskAccess: status,
            lastCheck: Date(),
            coverageImpact: coverageImpact(for: status),
            accessibleRoots: accessible,
            inaccessibleRoots: inaccessible,
            requiresRestart: false
        )
    }

    /// Run the probe and return FullDiskAccessStatus.
    public static func probeFullDiskAccess() -> FullDiskAccessStatus {
        probeSnapshot().fullDiskAccess
    }

    /// Refresh the published snapshot immediately.
    public func recheck() {
        let fresh = Self.probeSnapshot()
        snapshot = fresh
    }

    public static func coverageImpact(for status: FullDiskAccessStatus) -> String {
        switch status {
        case .granted:
            return NSLocalizedString("fda.impact.full", comment: "")
        case .limited:
            return NSLocalizedString("fda.impact.limited", comment: "")
        case .folderOnly:
            return NSLocalizedString("fda.impact.folder_only", comment: "")
        case .denied:
            return NSLocalizedString("fda.impact.denied", comment: "")
        case .unknown:
            return NSLocalizedString("fda.impact.unknown", comment: "")
        }
    }

    /// Open the Full Disk Access pane in System Settings using the supported URL scheme.
    public func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    public func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    public func openFilesAndFoldersSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }

    /// Relaunch the application when restart is needed after TCC permission changes.
    public func quitAndReopen() {
        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst())
    }
}
