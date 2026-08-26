//
//  AppIdentity.swift
//  SalmanMacCleaner
//
//  Single source of truth for the visible product identity (name + version
//  badge). The bundle/display name and version live in Info.plist via
//  MARKETING_VERSION / CURRENT_PROJECT_VERSION; this type exposes them
//  consistently to the toolbar badge, sidebar header and About screen.
//

import Foundation

public enum AppIdentity {

    /// Visible application name. Must match CFBundleDisplayName / CFBundleName.
    public static let displayName = "8002CleanUp"

    /// Short marketing version (e.g. "1.2.0") from the running bundle.
    public static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    /// Build number (e.g. "8") from the running bundle.
    public static var buildNumber: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
    }

    /// Compact "v1.2.0 (8)" badge used in the toolbar and sidebar header.
    public static var versionBadge: String {
        "v\(shortVersion) (\(buildNumber))"
    }

    /// Tooltip text for the version badge.
    public static var helpText: String {
        "\(displayName) version \(shortVersion) (\(buildNumber))"
    }
}
