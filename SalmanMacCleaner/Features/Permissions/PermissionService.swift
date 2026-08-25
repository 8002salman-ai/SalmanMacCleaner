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

public enum FullDiskAccessStatus: String, Equatable, Codable {
    /// At least one known protected location was readable.
    case likelyFullAccess
    /// Known protected locations exist but were denied.
    case limitedAccess
    /// No probe location exists on this Mac, or results were ambiguous.
    case notDetermined
    /// The probe itself could not run (unexpected I/O failure).
    case accessDenied

    public var title: String {
        switch self {
        case .likelyFullAccess: return NSLocalizedString("fda.status.likely", comment: "")
        case .limitedAccess: return NSLocalizedString("fda.status.limited", comment: "")
        case .notDetermined: return NSLocalizedString("fda.status.not_determined", comment: "")
        case .accessDenied: return NSLocalizedString("fda.status.denied", comment: "")
        }
    }

    public var explanation: String {
        switch self {
        case .likelyFullAccess:
            return NSLocalizedString("fda.explanation.likely", comment: "")
        case .limitedAccess:
            return NSLocalizedString("fda.explanation.limited", comment: "")
        case .notDetermined:
            return NSLocalizedString("fda.explanation.not_determined", comment: "")
        case .accessDenied:
            return NSLocalizedString("fda.explanation.denied", comment: "")
        }
    }
}

public struct PermissionSnapshot: Equatable {
    public var fullDiskAccess: FullDiskAccessStatus
    public var lastCheck: Date
    public var coverageImpact: String

    public init(fullDiskAccess: FullDiskAccessStatus, lastCheck: Date, coverageImpact: String) {
        self.fullDiskAccess = fullDiskAccess
        self.lastCheck = lastCheck
        self.coverageImpact = coverageImpact
    }
}

@MainActor
public final class PermissionService: ObservableObject {

    @Published public private(set) var snapshot: PermissionSnapshot
    public static let shared = PermissionService()

    /// Known TCC-protected, locally present probe locations. Existence is
    /// checked; readability is the signal. Nothing is modified.
    public static let probeLocations: [String] = [
        "~/Library/Safari/CloudTabs.db",
        "~/Library/Messages/chat.db",
        "~/Library/Mail",
        "~/Library/Safari/History.db"
    ]

    public init() {
        self.snapshot = PermissionSnapshot(
            fullDiskAccess: .notDetermined,
            lastCheck: .distantPast,
            coverageImpact: NSLocalizedString("fda.impact.unknown", comment: "")
        )
    }

    /// Run the probe. Reads at most 32 bytes from any probe location.
    public static func probeFullDiskAccess() -> FullDiskAccessStatus {
        var existed = 0
        var readable = 0

        for rawPath in probeLocations {
            let path = expandTilde(rawPath)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            existed += 1

            guard let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            if let data = try? handle.read(upToCount: 32), !data.isEmpty {
                readable += 1
            }
        }

        if existed == 0 {
            return .notDetermined
        }
        if readable > 0 {
            return .likelyFullAccess
        }
        return .limitedAccess
    }

    /// Refresh the published snapshot.
    public func recheck() {
        let status = Self.probeFullDiskAccess()
        snapshot = PermissionSnapshot(
            fullDiskAccess: status,
            lastCheck: Date(),
            coverageImpact: coverageImpact(for: status)
        )
    }

    public static func coverageImpact(for status: FullDiskAccessStatus) -> String {
        switch status {
        case .likelyFullAccess:
            return NSLocalizedString("fda.impact.full", comment: "")
        case .limitedAccess, .accessDenied:
            return NSLocalizedString("fda.impact.limited", comment: "")
        case .notDetermined:
            return NSLocalizedString("fda.impact.unknown", comment: "")
        }
    }

    /// Open the Full Disk Access pane in System Settings using the supported
    /// URL scheme.
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

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~/") else { return path }
        return NSHomeDirectory() + String(path.dropFirst())
    }
}
